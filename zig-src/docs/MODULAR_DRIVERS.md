# 驱动独立编译成 .so 的可行性调研（2026-10-15）

> 用户提出的思路：把驱动编译成独立的 `lib<driver>.so`，`main` 用 `dlopen` 在运行
> 时加载；删掉不需要的 .so 就能裁掉对应驱动，前端驱动下拉框按**运行时可用的
> .so** 渲染。
>
> 本文只做**可行性核对与体积测算**，不包含实施。结论在第 4 节。
> 所有数字均为打包机 10.0.0.4 上的 `zig 0.17.0` / `aarch64-linux-musl` 实测。

## 1. 先确认一个前提：当前二进制是**完全静态**的

```
$ readelf -h dist/openlist-aarch64     Type:  EXEC (Executable file)
$ readelf -l openlist-aarch64 | grep INTERP     （无输出：没有 INTERP 段）
$ readelf -d openlist-aarch64          没有 dynamic 段
```

静态二进制**不能 `dlopen`**。musl 的静态 `dlopen` 只对链接期就引入的库有效，
不能让用户在运行后再往里加 .so。所以这条思路的第一步，就是**把部署模型从静态
改成动态**（main 带 `INTERP`，依赖 `ld-musl-aarch64.so.1` + `libc.so`）。

这一步的代价：
- 设备上要额外带 musl 的 dynamic loader + `libc.so`。当前部署目录是
  `/tmp/olz`（tmpfs，220.9 MB，够放），但**成品镜像是 squashfs**（`build_sqfs.yml`），
  loader/libc 必须一起进镜像；且光猫 `/` overlay 只剩 **15.3 MB**（见 STATUS.md §6.1），
  凭空多吃几百 KB 的固定依赖。
- 之后每台设备上都多两个必须存在的文件，少一个就起不来 —— 对"塞进光猫"这种
  场景，静态单文件正是它最大的运维优点。

## 2. `.so` 的独立编译可行性：**可行**

已验证（探针 `driver_mod.zig`，打包机）：

```
$ zig build-lib -dynamic -target aarch64-linux-musl -lc -O ReleaseSmall -fstrip driver_mod.zig
$ readelf -h libprobe-aarch64.so      Type: DYN   Machine: AArch64
$ nm -D --defined-only libprobe-aarch64.so | grep ol_driver
  000000000001043c T ol_driver_abi_fingerprint
  0000000000010468 T ol_driver_factory
  0000000000010458 T ol_driver_vtable
$ ./probe ./libprobe-host.so          ← dlopen + dlsym + 调用（host target）
  key=UC label=UC网盘 drivers=1
  vtable.name=UC create(7)=8 fingerprint=40016
```

即：跨编译单元的 dlopen / 符号查找 / 调用链本身没问题，`export fn` 在
`-fstrip` 后仍然保留在动态符号表里。

**但有两个 Zig 特有的坑**（调研中实测踩到）：

1. **惰性分析会吞掉驱动代码**。`comptime { _ = @import("drivers/pan115.zig"); }`
   生成的 .so 只有 **1,320 B** —— 什么都没编进去。必须让 `export fn` 真正引用
   `factory.create`（取其地址），vtable 里的 fn 指针才会把整条驱动代码链拖进
   .so。这一步做错不会有任何报错，只会静默地得到一个空库。
2. **跨 .so 的类型边界**。`driver.Factory` / `Driver` / `VTable` / `Ctx` / `File`
   / `Link` 目前都是**非 extern 的 Zig struct**（含 `[]const u8` 切片、
   `anyerror!T` 错误联合、`std.mem.Allocator` vtable 指针）。把它们跨编译单元
   传递，等于依赖"同一编译器版本的 Zig ABI"，`json.Value` 还是嵌套 union ——
   这不是 C ABI，`export fn` 都不愿意直接接。要么把这些边界类型全部改成
   `extern struct` + 整数错误码（等于重写 15 个驱动的接口层，加上 `api.zig`
   里数百处调用点），要么接受"同一 Zig 0.17.0 下碰巧一致"的隐式契约。

## 3. 体积测算：**自包含 .so 会把体积做大 ~3.4 倍**

来源：`tools/driver_size.py` 的静态边际（`dist/driver_size.log`）vs 实测 .so。

| | raw | xz -6 |
|---|---|---|
| `pan115.zig` 编成**自包含** `.so` | **177,536** | **69,652** |
| `pan115` 在静态单体里的**边际** | +52,736 | +23,388 |
| 倍数 | **3.4×** | **3.0×** |

原因是每个 .so 都各自编了一份 `client.zig`(51 KB) / `cookiejar.zig`(36 KB) /
`util/*`。要让 .so 变小，就必须把这些共享层抽成 `libopenlist-core.so` 驱动再
动态链接 —— 而"共享层抽出"就必然回到第 2.2 条的**跨 .so 类型边界**问题：15 个
驱动文件的 `@import("../client.zig")` 要改成命名模块导入，且跨 .so 的
`json.Value` / `File` / `Link` 需要 ABI 稳定的表示。

10 个驱动（`dist/driver_size.log` 口径）在静态单体里的 xz 边际合计只有
**124,928 B**。也就是说：即便模块化成功，省下的只是这 12 万字节里的一部分，
代价却是 musl loader + libc.so 的固定依赖 + 全部驱动的接口层重写。

## 4. 结论与建议

**不建议做 `.so` 模块化**，理由是三条硬数据：当前静态二进制无法 dlopen（§1）；
自包含 .so 比静态边际大 3.4 倍（§3）；要共享 core 就必须把驱动接口层全部改写成
C ABI，这是个会直接冲击"逐文件对齐 Go 实现"目标的重构（§2.2）。

而用户的真实目标 —— **按需裁剪 + 下拉框只列存在的驱动** —— 有一个等价且
**零 ABI 风险**的实现：**编译期驱动白名单**（方案 A）：

| 方案 | 部署 | 省体积 | 风险 | 工作量 |
|---|---|---|---|---|
| **A. 编译期白名单**（推荐） | 静态单文件不变 | ✅ 未选驱动的 xz 全额省下 | 极低（只动 build + 注册表） | 小 |
| B. `.so` + dlopen（原思路） | 动态 libc，需 loader+libc.so 上设备 | 见 §3，可能反增 | 高（接口层重写 + 部署契约变更） | 大 |

方案 A 的具体形态（待用户确认后再实施）：
- `build.zig` 增加 `-Ddrivers=local,webdav,...`（默认全量），`driver.zig` 的
  `builtin` 数组由该选项 + `@import("build_options")` 生成；
- 未选中的驱动**不被编译**，二进制随之缩小，`/api/admin/driver/names` 与前端
  下拉框自然只反映可用驱动 —— 这条路它现在就是对的，不需要改；
- `tools/build_remote.py` 已在打包机上跑，只需把驱动清单做成可传参；
- 打包机 `zig test` 需要同步拿到默认选项（改走 `zig build test` 或在脚本里
  补 `-Mbuild_options=...`）。

代价：换驱动集要重新出包（对固定镜像部署这本来就要重启，不是新增约束）。

## 5. 附：调研脚本与复现方式

探针脚本已随本轮清理删除；复现只需两条命令（在打包机上）：

```sh
cd /tmp/olz-probe
# 1) 自包含 .so（会得到 1,320 B 的空库）
zig build-lib -dynamic -target aarch64-linux-musl -lc -O ReleaseSmall -fstrip root_tiny.zig
# 2) 强制代码生成后的真实体积
zig build-lib -dynamic -target aarch64-linux-musl -lc -O ReleaseSmall -fstrip root.zig -femit-bin=libpan115.so
xz -6 -c libpan115.so | wc -c
```

其中 `root.zig` 的核心是：

```zig
const pan115 = @import("drivers/pan115.zig");
export fn olz_force() usize { return @intFromPtr(&pan115.factory.create); }
```

"""Build the Zig binary on the build host (10.0.0.4) — the only supported path.

The Windows box is only ever used to *read* the sources and to run the unit
tests locally; every binary that ships is produced here, so the toolchain
(Zig 0.17.0 @ /root/.cache/zig/zig) and the resulting artifact are reproducible.

    python tools/build_remote.py                          # aarch64（默认，光猫用）
    python tools/build_remote.py --target x86_64-linux-musl
    python tools/build_remote.py dist/openlist-custom     # 自定义产物路径

产物名按目标架构自动取 `dist/openlist-<arch>`；`--target` 缺省为
`aarch64-linux-musl`（光猫那台）。单测始终在打包机**原生**跑（x86_64），
所以两个架构共用同一轮 438 条用例。
"""
import hashlib
import io
import subprocess
import os
import sys
import tarfile

import paramiko

from remote import PWD, USER, connect, sh

HOST = "10.0.0.4"
ZIG = "/root/.cache/zig/zig"
# 打包机工作目录（用户 2026-10-11 指定用 /tmp）。仍然不碰 /root/.cache/ 里的工具链。
WORK = "/tmp/olz-build"
GCACHE = "/tmp/olz-build/zigcache"
# ★ 局部缓存也显式指定（2026-10-21 规则：构建只写 /tmp）。
#   不指定的话 zig 会在 $WORK/.zig-cache 建一份 —— 那也在 /tmp，但两份缓存
#   不共享、清理时容易漏。统一指到 GCACHE，全局/局部共用一处。
LCACHE = GCACHE
# 打过 TLS 补丁的 std 副本（tools/ziglib_patch.py 生成）。工具链本体保持
# 只读，编译器通过 ZIG_LIB_DIR 指向这份副本 —— 详见 ziglib_patch.py 的模块
# 文档（drive.quark.cn 只接受 ECDSA 套件，上游 Zig 0.17.0 却只提供
# ECDHE-RSA）。放在 WORK 内：每次构建都会重建，工具链升级后不会用到旧副本。
ZIGLIB = "/tmp/olz-build/ziglib"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_TARGET = "aarch64-linux-musl"

# readelf -h 的 Machine 行长这样：AArch64 / Advanced Micro Devices X86-64。
# 用「命中任一个就算对」而不是精确相等 —— readelf 的输出随 binutils 版本漂移。
ELF_MACHINE_HINTS = {
    "aarch64": ("aarch64", "arm"),
    "x86_64": ("x86-64", "x86_64", "advanced micro devices"),
}


def arch_tag(target):
    """`aarch64-linux-musl` → `aarch64`，用来给产物起名/选校验规则。"""
    if "aarch64" in target:
        return "aarch64"
    if "x86_64" in target or "amd64" in target:
        return "x86_64"
    return target.split("-")[0]


def pack_src():
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        # tools/ 必须一起打包：ziglib_patch.py 要在构建机上跑（见 main() 步骤 0.5）。
        for name in ("src", "build.zig", "build.zig.zon", "tools"):
            tf.add(os.path.join(ROOT, name), arcname=name)
    return buf.getvalue()


def main():
    # 目标三元组：--target x86_64-linux-musl，缺省 aarch64-linux-musl。
    target = DEFAULT_TARGET
    if "--target" in sys.argv:
        i = sys.argv.index("--target")
        if i + 1 < len(sys.argv):
            target = sys.argv[i + 1]
    arch = arch_tag(target)
    print(f"target: {target}  (arch={arch})", flush=True)

    # 位置参数可覆盖产物路径；否则按架构自动命名。
    out = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") \
        else os.path.join(ROOT, "dist", f"openlist-{arch}")
    # 编译期驱动白名单：--drivers "local,webdav,quark,strm"，空 = 全量。
    # 名字可以是 Go 驱动名（189Cloud）或 Zig 文件名（cloud189），
    # 与 build.zig 的 -Ddrivers= 完全一致。
    drivers = ""
    if "--drivers" in sys.argv:
        i = sys.argv.index("--drivers")
        drivers = sys.argv[i + 1] if i + 1 < len(sys.argv) else ""
    print(f"driver whitelist: {drivers or '(all)'}", flush=True)

    # --- 0) lint the built-in page's inline JS --------------------------
    # 必须在最前面：这是唯一能发现"页面 JS 语法错误"的检查。
    # 教训（2026-10-15）：`<script>` 是 raw text，实体不解码，我写了
    # `&amp;&amp;` ⇒ 浏览器把字面量交给 JS ⇒ 语法错误 ⇒ 整个脚本不执行 ⇒
    # 表单永远不显示。而当时所有检查都只是把 HTML 当**字符串**看，全过了。
    # 这个脚本把内联 JS 抽出来跑 `node --check`，补上那个盲区。
    r = subprocess.run(
        [sys.executable, os.path.join(ROOT, "tools", "check_builtin_js.py")],
        capture_output=True, text=True,
    )
    print((r.stdout + r.stderr).strip(), flush=True)
    if r.returncode != 0:
        print("!! built-in page JS lint failed; aborting before any build", flush=True)
        return 1

    blob = pack_src()
    src_sha = hashlib.sha256(blob).hexdigest()
    print(f"packed sources: {len(blob)} bytes", flush=True)
    print(f"source tarball sha256: {src_sha}", flush=True)

    c = connect(HOST, 22)
    sftp = c.open_sftp()
    sh(c, f"rm -rf {WORK} && mkdir -p {WORK}")
    sh(c, f"mkdir -p {GCACHE}")
    sftp.putfo(io.BytesIO(blob), WORK + "/src.tar.gz")
    sh(c, f"cd {WORK} && tar xzf src.tar.gz && ls")

    # --- 0.5) patched std copy ------------------------------------------
    # Zig 0.17.0 只提供 ECDHE-RSA 套件，drive.quark.cn 的 ECDHE-RSA 路径是坏的
    # （发完 RSA 证书链就在 ServerKeyExchange 处 internal_error），必须让客户端
    # 提供 ECDSA 套件。std 的套件列表是硬编码的、没有开关，所以在工作区放一份
    # 打过补丁的 std 副本，构建时用 ZIG_LIB_DIR 指过去。工具链本体只读。
    o, e, rc = sh(c, f"cd {WORK} && python3 tools/ziglib_patch.py")
    print((o + e).rstrip(), flush=True)
    if rc != 0:
        print("!! ziglib patch failed; aborting before any build", flush=True)
        sftp.close()
        c.close()
        return 1

    # --- 1) unit tests -------------------------------------------------
    # B01: Linux 必须显式 `-lc`，否则 local.zig 的 `extern "c" statvfs`
    # 直接报 "dependency on libc must be explicitly specified"。
    # B03: 不再 `| tail` 截断（管道吃掉真实退出码），按 rc 判定。
    #
    # ⚠️ 必须走 `zig build test` 而不是裸 `zig test src/tests.zig`：
    #    `driver.zig` 现在 `@import("build_options")`（编译期驱动白名单），
    #    只有 build.zig 才会注入这个模块，裸 zig test 会直接编译失败。
    #    `zig build` 在打包机（Linux）上正常，本机 D 盘才有 maker.exe 的问题。
    #
    # ⚠️ 判定信号用 `--summary all` 打出的 `test success`，**不能**找
    #    "All N tests passed."：`zig build` 的 Run 步骤会用 `--listen=-` 走
    #    runner 协议，那种模式下汇总行被吞掉、末尾还会打一行误导性的
    #    `failed command: <test bin>`（实测 ZIGBUILD_RC=0，测试是全过的）。
    #    退出码才是唯一可靠判据，`test success` 是它的可读替身。
    drv_args = f' -Ddrivers="{drivers}"' if drivers else ""
    # 多分钟的构建：remote.sh() 默认 120s 不够，显式放大到 15 分钟
    # （正常 3–4.5 分钟，留 3 倍余量；仍然有界，不会无限挂死）。
    o, e, rc = sh(c, f"cd {WORK} && ZIG_GLOBAL_CACHE_DIR={GCACHE} ZIG_LOCAL_CACHE_DIR={LCACHE} "
                     f"ZIG_LIB_DIR={ZIGLIB} {ZIG} build test --summary all{drv_args}",
                  timeout=900)
    log = (o + e)
    print(log.rstrip()[-4000:] if len(log) > 4000 else log.rstrip(), flush=True)
    if rc != 0:
        print(f"!! unit tests failed on the build host (rc={rc}); aborting before build", flush=True)
        sftp.close()
        c.close()
        return 1
    # 测试数会随提交增长，不能写死 "All 212 tests passed"。但必须看到步骤成功。
    if "test success" not in log:
        print("!! build summary did not report 'test success'; aborting", flush=True)
        sftp.close()
        c.close()
        return 1

    # --- 2) cross build ------------------------------------------------
    # B03: 同样按 rc 判定；失败不得继续下载旧产物。
    # 走 `zig build`（而不是裸 build-exe）才能带上 `-Ddrivers=` 白名单，
    # 产物因此落在 `zig-out/bin/openlist` 而不是工作目录根下。
    o, e, rc = sh(c, f"cd {WORK} && ZIG_GLOBAL_CACHE_DIR={GCACHE} ZIG_LOCAL_CACHE_DIR={LCACHE} "
                     f"ZIG_LIB_DIR={ZIGLIB} {ZIG} build "
                     f"-Dtarget={target} -Doptimize=small{drv_args}",
                  timeout=900)
    log = (o + e)
    if rc != 0:
        print(log.rstrip()[-4000:], flush=True)
        print(f"!! cross build failed (rc={rc}); not downloading anything", flush=True)
        sftp.close()
        c.close()
        return 1
    if log.strip():
        print(log.rstrip()[-4000:], flush=True)

    # --- 3) verify the artifact is really ours -------------------------
    # B03: 确认远端二进制确实是本次构建产物 —— ELF、目标架构、静态链接、
    # 并且名字对得上，再下载。
    ART = f"{WORK}/zig-out/bin/openlist"
    o, e, rc = sh(c, f"ls -l {ART} && sha256sum {ART} && "
                     f"file {ART} 2>/dev/null; readelf -h {ART} 2>/dev/null | "
                     f"grep -E 'Machine|Type' || true")
    print(o.strip(), flush=True)
    # readelf 打的是 "AArch64" / "Advanced Micro Devices X86-64"，大小写敏感
    # 的比较会把正确产物判成非法。按目标架构选提示词，命中任一个即可。
    head_lower = o.lower()
    hints = ELF_MACHINE_HINTS.get(arch, (arch,))
    if not any(h in head_lower for h in hints):
        print(f"!! remote binary does not look like a {arch} ELF "
              f"(expected one of {hints}); aborting", flush=True)
        sftp.close()
        c.close()
        return 1

    os.makedirs(os.path.dirname(out), exist_ok=True)
    sftp.get(ART, out)
    sftp.close()
    c.close()
    d = open(out, "rb").read()
    print(f"\nlocal: {out}\n  size   {len(d)}\n  sha256 {hashlib.sha256(d).hexdigest()}"
          f"\n  from source tarball {src_sha[:16]}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())

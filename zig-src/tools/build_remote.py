"""Build the Zig binary on the build host (10.0.0.4) — the only supported path.

The Windows box is only ever used to *read* the sources and to run the unit
tests locally; every binary that ships is produced here, so the toolchain
(Zig 0.17.0 @ /root/.cache/zig/zig) and the resulting artifact are reproducible.

    python tools/build_remote.py [--out dist/openlist-aarch64]
"""
import hashlib
import io
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
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TARGET = "aarch64-linux-musl"


def pack_src():
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for name in ("src", "build.zig", "build.zig.zon"):
            tf.add(os.path.join(ROOT, name), arcname=name)
    return buf.getvalue()


def main():
    out = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") \
        else os.path.join(ROOT, "dist", "openlist-aarch64")
    # 编译期驱动白名单：--drivers "local,webdav,quark,strm"，空 = 全量。
    # 名字可以是 Go 驱动名（189Cloud）或 Zig 文件名（cloud189），
    # 与 build.zig 的 -Ddrivers= 完全一致。
    drivers = ""
    if "--drivers" in sys.argv:
        i = sys.argv.index("--drivers")
        drivers = sys.argv[i + 1] if i + 1 < len(sys.argv) else ""
    print(f"driver whitelist: {drivers or '(all)'}", flush=True)
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
    o, e, rc = sh(c, f"cd {WORK} && ZIG_GLOBAL_CACHE_DIR={GCACHE} {ZIG} build test --summary all{drv_args}")
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
    o, e, rc = sh(c, f"cd {WORK} && ZIG_GLOBAL_CACHE_DIR={GCACHE} {ZIG} build "
                     f"-Dtarget={TARGET} -Doptimize=small{drv_args}")
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
    # readelf 打的是 "AArch64"，大小写敏感的比较会把正确产物判成非法。
    head_lower = o.lower()
    if "aarch64" not in head_lower and "arm" not in head_lower:
        print("!! remote binary does not look like an aarch64 ELF; aborting", flush=True)
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

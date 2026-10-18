#!/usr/bin/env python3
"""Prepare a patched copy of the Zig standard library on the build host.

Why this exists
---------------
Zig 0.17.0's `std.crypto.tls.Client` only ever offers **ECDHE-RSA** cipher
suites (`cipher_suites`, lib/std/crypto/tls/Client.zig) and its ServerHello
parser only *accepts* the ECDHE-RSA suites (`else => return
error.TlsIllegalParameter`). No ECDSA suite anywhere.

That breaks drive.quark.cn. Reproduced 2026-10-16 (full evidence in
docs/STATUS.md, §TLS): with an RSA-only suite list the server sends
ServerHello + its RSA certificate chain and then aborts with a **fatal
internal_error (alert 80) at ServerKeyExchange**. The abort happens with
OpenSSL's ClientHello too, so it is a server-side defect of its ECDHE-RSA
path — but it is deterministic and it is the only path Zig can take, because
Zig never offers an ECDSA suite. The very same server completes the handshake
the moment an ECDSA suite (C02B/C02C/CCA9) is on offer, and it even prefers
C02B over C02F when both are listed. Go's crypto/tls offers ECDSA suites by
default, which is why the Go build of this project works on the same device.

Zig's client can do ECDSA end to end — `Certificate.zig` implements
`verify_ecdsa`, the signature-algorithm list already contains
ecdsa_secp256r1_sha256, and `Client.zig` verifies ECDSA-signed
ServerKeyExchange messages (`SchemeEcdsa`) — the suites are simply missing
from the offer list *and* from the two ServerHello switches.

The patch therefore touches four places, all in Client.zig:
  1+2. both comptime branches of the `cipher_suites` offer list,
  3.   the ServerHello cipher-suite switch that sets up the transcript hash,
  4.   the `.tls_1_2` ServerHello switch that advances the handshake state.

Project convention: the toolchain under /root/.cache is used **read-only**
(docs/STATUS.md §5), so we copy `lib/` into the build workspace, patch the
copy, and point the compiler at it with `ZIG_LIB_DIR`.

The script always starts from a pristine copy, so it is idempotent. It fails
loudly if the upstream text no longer matches the anchors (i.e. after a
toolchain upgrade, the patch has to be revisited).

Usage (on the build host):
    python3 tools/ziglib_patch.py [src_lib_dir] [dst_lib_dir]
"""
import os
import shutil
import sys

SRC = "/root/.cache/zig/lib"
DST = "/tmp/olz-build/ziglib"
REL = "std/crypto/tls/Client.zig"

# ---------------------------------------------------------------------------
# Patch 1+2: the offer lists (both comptime branches, hardware AES or not).
# The three ECDSA suites are appended so the relative priority of every
# existing suite is unchanged. Appended rather than prepended on purpose:
# servers are supposed to apply their own preference, but the ones that
# wrongly follow the client's order keep their current selection.
# ---------------------------------------------------------------------------
ECDSA_LINES = """        // openlist-zig patch (tools/ziglib_patch.py): also offer ECDSA
        // suites. Zig 0.17.0 lists only ECDHE-RSA suites here, which breaks
        // servers whose ECDHE-RSA path is defective: drive.quark.cn sends
        // its RSA chain and then aborts with a fatal internal_error at
        // ServerKeyExchange unless an ECDSA suite is offered (Go's
        // crypto/tls offers them; this client can verify them —
        // Certificate.zig verify_ecdsa, Client.zig SchemeEcdsa).
        .ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
        .ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
        .ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
"""

# Anchor 1: tail of the hardware-AES branch. The trailing `\n    })` (no
# semicolon) is what makes this unique — the software-AES branch contains the
# same two suite lines but continues with `.AEGIS_128L_SHA256`.
OLD_HW = """        .CHACHA20_POLY1305_SHA256,
        .ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
    })"""
NEW_HW = """        .CHACHA20_POLY1305_SHA256,
        .ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
""" + ECDSA_LINES + "    })"

# Anchor 2: tail of the software-AES branch (ends with `});`).
OLD_SW = """        .AES_256_GCM_SHA384,
        .ECDHE_RSA_WITH_AES_256_GCM_SHA384,
    });"""
NEW_SW = """        .AES_256_GCM_SHA384,
        .ECDHE_RSA_WITH_AES_256_GCM_SHA384,
""" + ECDSA_LINES + "    });"

# ---------------------------------------------------------------------------
# Patch 3: the ServerHello cipher-suite switch that sets up the transcript
# hash. Without the ECDSA cases the client rejects the server's ECDSA
# selection with error.TlsIllegalParameter before reading anything else.
# (28-space indent, `=> |tag|` continuation.)
# ---------------------------------------------------------------------------
OLD_SH = """                            .ECDHE_RSA_WITH_AES_128_GCM_SHA256,
                            .ECDHE_RSA_WITH_AES_256_GCM_SHA384,
                            .ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
                            => |tag| {"""
NEW_SH = """                            .ECDHE_RSA_WITH_AES_128_GCM_SHA256,
                            .ECDHE_RSA_WITH_AES_256_GCM_SHA384,
                            .ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
                            .ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
                            .ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
                            .ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
                            => |tag| {"""

# ---------------------------------------------------------------------------
# Patch 4: the `.tls_1_2` ServerHello switch that advances the handshake
# state to `.certificate`. Same story: ECDSA selections must be accepted.
# (32-space indent, `=> handshake_state = .certificate` continuation.)
# ---------------------------------------------------------------------------
OLD_T12 = """                                .ECDHE_RSA_WITH_AES_128_GCM_SHA256,
                                .ECDHE_RSA_WITH_AES_256_GCM_SHA384,
                                .ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
                                => handshake_state = .certificate,"""
NEW_T12 = """                                .ECDHE_RSA_WITH_AES_128_GCM_SHA256,
                                .ECDHE_RSA_WITH_AES_256_GCM_SHA384,
                                .ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256,
                                .ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
                                .ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
                                .ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256,
                                => handshake_state = .certificate,"""

PATCHES = [
    ("offer list (hardware-AES branch)", OLD_HW, NEW_HW),
    ("offer list (software-AES branch)", OLD_SW, NEW_SW),
    ("ServerHello cipher switch", OLD_SH, NEW_SH),
    ("ServerHello tls_1_2 state switch", OLD_T12, NEW_T12),
]

SUITES = (
    "ECDHE_ECDSA_WITH_AES_128_GCM_SHA256",
    "ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
    "ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256",
)


def patched_text(text):
    """Apply all patches to the contents of Client.zig."""
    for name, old, new in PATCHES:
        n = text.count(old)
        if n != 1:
            sys.exit(
                f"!! patch anchor '{name}' found {n} times (expected exactly 1).\n"
                f"   Upstream Client.zig changed — revisit tools/ziglib_patch.py.\n"
                f"   First unmatched anchor:\n{old}"
            )
        text = text.replace(old, new)
    # 3 suites x 2 branches in the offer list + 3 suites in each ServerHello
    # switch = 12 references total.
    total = sum(text.count("." + suite) for suite in SUITES)
    if total != 12:
        sys.exit(f"!! sanity check failed: ECDSA suite references = {total}, expected 12")
    return text


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else SRC
    dst = sys.argv[2] if len(sys.argv) > 2 else DST
    if not os.path.isdir(os.path.join(src, "std")):
        sys.exit(f"!! {src} does not look like a Zig lib directory (no std/)")

    # Always start from a pristine copy: cheap on tmpfs, and a stale copy
    # would silently lose the patch after a toolchain upgrade.
    if os.path.exists(dst):
        shutil.rmtree(dst)
    shutil.copytree(src, dst, symlinks=True)

    path = os.path.join(dst, REL)
    with open(path, encoding="utf-8") as f:
        text = f.read()
    text = patched_text(text)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"patched {path}: ECDSA cipher suites added to the offer lists "
          f"(both comptime branches) and to both ServerHello switches")
    return 0


if __name__ == "__main__":
    sys.exit(main())

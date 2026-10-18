//! Direct `std.crypto.tls.Client` handshake probe — gets the detailed error
//! that `std.http.Client` swallows.
//!
//! `std.http.Client.connectTcpOptions` maps *every* TLS failure to
//! `error.TlsInitializationFailed` (see lib/std/http/Client.zig, the
//! `else => return error.TlsInitializationFailed` branch), so a failed
//! driver init says nothing about *why*. This probe performs the exact same
//! handshake the HTTP client performs — same `std.crypto.tls.Client.init`
//! options (`.host = .{ .explicit = ... }`, system CA bundle via
//! `Bundle.rescan`) — but prints the underlying `InitError` name and the TLS
//! alert when there is one.
//!
//! Usage (on the device, aarch64):
//!     ./tls_probe drive.quark.cn 443
//!     ./tls_probe cloud.189.cn 443      # control: known-good on this host
//!
//! Build (on the build host):
//!     zig build-exe tls_probe.zig -O ReleaseSmall \
//!         -target aarch64-linux-musl -femit-bin=tls_probe

const std = @import("std");
const builtin = @import("builtin");

const buf_len = 32 * 1024;

/// The Linux search order copied from `std.crypto.Certificate.Bundle`
/// (rescanLinux). Used only so the per-path diagnostic matches std exactly.
const cert_file_paths = [_][]const u8{
    "/etc/ssl/certs/ca-certificates.crt",
    "/etc/pki/tls/certs/ca-bundle.crt",
    "/etc/ssl/ca-bundle.pem",
    "/etc/pki/tls/cacert.pem",
    "/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem",
    "/etc/ssl/cert.pem",
};
const cert_dir_paths = [_][]const u8{
    "/etc/ssl/certs",
    "/etc/pki/tls/certs",
    "/system/etc/security/cacerts",
};

fn diagnoseBundle(gpa: std.mem.Allocator, io: std.Io, now: std.Io.Timestamp) void {
    std.debug.print("--- per-path CA diagnosis ---\n", .{});
    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(gpa);
    for (cert_file_paths) |p| {
        bundle.addCertsFromFilePathAbsolute(gpa, io, now, p) catch |e| {
            std.debug.print("file {s}: {s}\n", .{ p, @errorName(e) });
            continue;
        };
        std.debug.print("file {s}: ok (bytes={d})\n", .{ p, bundle.bytes.items.len });
        break;
    }
    for (cert_dir_paths) |d| {
        bundle.addCertsFromDirPathAbsolute(gpa, io, now, d) catch |e| {
            std.debug.print("dir  {s}: {s}\n", .{ d, @errorName(e) });
            continue;
        };
        std.debug.print("dir  {s}: ok\n", .{d});
    }
    // Raw libc read of the main bundle: bypasses the whole Io layer, so a
    // failure here is an OS-level problem (permissions, fd limits, ...).
    if (comptime builtin.os.tag != .windows) {
        const fd = std.c.open("/etc/ssl/certs/ca-certificates.crt", .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
        if (fd < 0) {
            std.debug.print("libc open: errno={d}\n", .{std.c._errno().*});
            return;
        }
        defer _ = std.c.close(fd);
        var buf: [4096]u8 = undefined;
        const n = std.c.read(fd, &buf, buf.len);
        if (n < 0) {
            std.debug.print("libc read: errno={d}\n", .{std.c._errno().*});
            return;
        }
        std.debug.print("libc open+read: ok ({d} bytes, starts with \"{s}\")\n", .{ n, buf[0..@min(27, @as(usize, @intCast(n)))] });
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const a = init.arena.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, a);
    _ = args.next(); // argv[0]
    const host_s = args.next() orelse return error.MissingHost;
    const port_s = args.next() orelse return error.MissingPort;
    const port = try std.fmt.parseInt(u16, port_s, 10);
    // Optional third arg: the SNI to send. Lets the probe connect to a local
    // proxy while still presenting the real hostname in the ClientHello.
    const sni_s = args.next() orelse host_s;

    std.debug.print("probe {s}:{d} (sni={s})\n", .{ host_s, port, sni_s });

    // --- system CA bundle, exactly like Client.ensureCaBundle() -----------
    diagnoseBundle(gpa, io, std.Io.Clock.real.now(io));

    var bundle: std.crypto.Certificate.Bundle = .empty;
    defer bundle.deinit(gpa);
    const now = std.Io.Clock.real.now(io);
    bundle.rescan(gpa, io, now) catch |e| {
        std.debug.print("rescan FAILED: {s}\n", .{@errorName(e)});
        return e;
    };
    std.debug.print("bundle bytes={d}\n", .{bundle.bytes.items.len});

    var ca_lock: std.Io.RwLock = .init;

    // --- TCP --------------------------------------------------------------
    const host = try std.Io.net.HostName.init(host_s);
    const stream = try host.connect(io, port, .{ .mode = .stream });
    defer stream.close(io);
    std.debug.print("tcp connected\n", .{});

    var socket_read_buf: [buf_len]u8 = undefined;
    var tls_read_buf: [buf_len]u8 = undefined;
    var tls_write_buf: [buf_len]u8 = undefined;
    var socket_write_buf: [buf_len]u8 = undefined;
    var stream_reader = stream.reader(io, &socket_read_buf);
    var stream_writer = stream.writer(io, &socket_write_buf);

    var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
    io.random(&entropy);

    // --- TLS handshake (same options as std.http.Client) -------------------
    var alert: std.crypto.tls.Alert = .{ .level = .warning, .description = .close_notify };
    var tls_client: std.crypto.tls.Client = undefined;
    tls_client = std.crypto.tls.Client.init(
        &stream_reader.interface,
        &stream_writer.interface,
        .{
            .host = .{ .explicit = sni_s },
            .ca = .{ .bundle = .{ .gpa = gpa, .io = io, .lock = &ca_lock, .bundle = &bundle } },
            .read_buffer = &tls_read_buf,
            .write_buffer = &tls_write_buf,
            .entropy = &entropy,
            .realtime_now = now,
            .allow_truncation_attacks = true,
            .alert = &alert,
        },
    ) catch |e| {
        std.debug.print("HANDSHAKE FAILED: {s}  alert={s}/{s}\n", .{
            @errorName(e), @tagName(alert.level), @tagName(alert.description),
        });
        return e;
    };
    std.debug.print("HANDSHAKE OK version={s}\n", .{@tagName(tls_client.tls_version)});
}

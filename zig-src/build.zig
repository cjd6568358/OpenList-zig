const std = @import("std");

// ---------------------------------------------------------------------------
// 编译期驱动白名单（`-Ddrivers=`，方案 A）
// ---------------------------------------------------------------------------
// 用户 2026-10-15 要求：能按需裁剪驱动，不选的一个字节都不进二进制。
// 这里做"名字 → basename"的翻译与**校验**，`src/driver.zig` 的 `has()` 只认
// basename。两张表必须同步 —— 万一漂移，build.zig 会在编译前就以
// "unknown driver" 失败并列岀全部合法值，不会静默产出缺驱动的二进制。
//
// `key` 是 Go `driver.Config.Name`（也就是写进 config.json `Storage.driver`
// 的字符串），两种拼写都接受，因为 itvsh 的 key 是中文「上海电信智家硬盘」，
// 命令行里打不方便。
const Driver = struct { key: []const u8, file: []const u8 };
const DRIVERS = [_]Driver{
    .{ .key = "Local", .file = "local" },
    .{ .key = "WebDav", .file = "webdav" },
    .{ .key = "上海电信智家硬盘", .file = "itvsh" },
    .{ .key = "AliyundriveOpen", .file = "aliyundrive" },
    .{ .key = "189Cloud", .file = "cloud189" },
    .{ .key = "189CloudPC", .file = "cloud189pc" },
    .{ .key = "123Pan", .file = "pan123" },
    .{ .key = "Quark", .file = "quarkuc" }, // 与 UC 同一个实现
    .{ .key = "UC", .file = "quarkuc" }, // OnlyProxy 变体
    .{ .key = "115 Cloud", .file = "pan115" },
    .{ .key = "WoPan", .file = "wopan" },
    .{ .key = "Strm", .file = "strm" },
};

/// `-Ddrivers=` 的原始串 → 去重后的 basename 串。空 / "all" ⇒ 全量。
/// 未知名字在这里就炸掉，并列岀合法值。
///
/// 写进调用方给的 `out` 缓冲而不是自己分配：build.zig 里能拿到的
/// allocator 是 `b.allocator`，为这个一次性翻译引入生命周期管理不划算。
/// 故意用 `bufPrint` 而非 `std.io.fixedBufferStream` —— 0.17 已无后者。
/// 不去重：重复项对 `driver.zig` 的 `has()` 无害（它按 basename 判断一次）。
fn resolveDrivers(out: []u8, raw: []const u8) []const u8 {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, raw, ", \t\n");
    var any = false;
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "all")) return "all";
        for (DRIVERS) |d| {
            if (std.mem.eql(u8, tok, d.key) or std.mem.eql(u8, tok, d.file)) {
                any = true;
                const s = std.fmt.bufPrint(out[n..], "{s},", .{d.file}) catch
                    @panic("driver whitelist too long (max 512 bytes)");
                n += s.len;
                break;
            }
        } else {
            std.debug.print("unknown driver '{s}'; known drivers (key|file):", .{tok});
            for (DRIVERS) |d| std.debug.print(" {s}|{s}", .{ d.key, d.file });
            std.debug.print("\n", .{});
            std.process.exit(1);
        }
    }
    if (!any) return "all";
    return out[0 .. n - 1]; // 去掉尾逗号
}

pub fn build(b: *std.Build) void {
    // The deployment target is the 光猫: aarch64, musl, fully static.
    //   zig build -Dtarget=aarch64-linux-musl -Doptimize=small
    // The default target is the host, so `zig build test` works on the dev box.
    const target = b.standardTargetOptions(.{});
    // `-Doptimize=` with a `small` *default*: a bare `zig build` must produce
    // the shippable binary, not a fat Debug one. (The idiomatic
    // `standardOptimizeOption(.{ .preferred_optimize_mode = ... })` would
    // instead expose a `-Drelease=true|false` switch, which is a worse fit for
    // a project whose whole point is one specific size-optimised artefact.)
    // The `test` step below pins `.debug` explicitly regardless.
    //
    // Zig 0.17 renamed the optimize modes to lowercase (`debug`/`safe`/`fast`/
    // `small`); `ReleaseSmall` still exists as a deprecated *constant* but is no
    // longer an enum field, so `.ReleaseSmall` does not resolve.
    const optimize = b.option(
        std.lang.Optimize,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .small;

    // 编译期驱动白名单：默认全量（等价于旧行为）。裁剪示例：
    //   zig build -Ddrivers=local,webdav,quark,strm
    // 名字可以是 Go 驱动名（`189Cloud`）或 Zig 文件名（`cloud189`）。
    const drivers_raw = b.option(
        []const u8,
        "drivers",
        "Comma-separated driver whitelist; empty or 'all' = every driver",
    ) orelse "";
    var drv_buf: [512]u8 = undefined;
    const drivers = resolveDrivers(&drv_buf, drivers_raw);

    const opts = b.addOptions();
    opts.addOption([]const u8, "drivers", drivers);
    opts.addOption(bool, "drivers_all", std.mem.eql(u8, drivers, "all"));

    // `-Ddrivers=` 白名单模块。0.17 的 `Module.CreateOptions` 没有 `add_options`
    // 字段，只能在模块创建后用 `addImport` 注入 —— 这也意味着
    // `tools/build_remote.py` 必须走 `zig build test` 而不是裸 `zig test`
    // （裸调用没有 build.zig 参与，`driver.zig` 的 `@import("build_options")`
    // 会直接编译失败）。
    const opts_mod = opts.createModule();

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // Strip in every mode but debug: the 光猫 image has no use for
        // symbols and the squashfs is size-budgeted.
        .strip = optimize != .debug,
        // libc is required for exactly one thing: `statvfs`, used by the
        // `local` driver to report free space (std has no statvfs/statfs
        // wrapper). For the `aarch64-linux-musl` target this links musl
        // statically — the same shape as the Go binary it replaces.
        //
        // 0.17 moved this from `Step.Compile.linkLibC()` to a module field.
        .link_libc = true,
    });
    exe_mod.addImport("build_options", opts_mod);
    const exe = b.addExecutable(.{
        .name = "openlist",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // ---- zig build run -- <args> ----
    //
    // 0.17 removed the `b.args` field. Extra arguments passed after `--` are now
    // spliced in by the build runner itself, but only into Run steps that opt in
    // via `addPassthruArgs()`. So `zig build run -- --config foo.json` reaches
    // the server as `--config foo.json` without build.zig having to see them.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Build and run the server");
    run_step.dependOn(&run_cmd.step);

    // ---- zig build test ----
    // Always debug: the unit tests exist to catch logic errors, and `small`
    // would compile out the very checks that make them useful.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    test_mod.addImport("build_options", opts_mod);
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // ---- zig build size ----
    // Prints the size of the produced binary, so the size budget is a
    // one-command check rather than a manual `ls -l`.
    // 同时打出本次的驱动白名单 —— 裁剪前后对比体积时，先确认裁对了东西。
    const size_cmd_txt = std.fmt.allocPrint(b.allocator,
        "printf 'drivers: {s}\\n' && ls -l zig-out/bin/openlist && (command -v xz >/dev/null && xz -6 -c zig-out/bin/openlist | wc -c || echo 'xz not available')",
        .{drivers},
    ) catch unreachable;
    const size_step = b.step("size", "Report the size of the installed binary");
    const size_cmd = b.addSystemCommand(&.{ "sh", "-c", size_cmd_txt });
    size_cmd.step.dependOn(b.getInstallStep());
    size_step.dependOn(&size_cmd.step);
}

const std = @import("std");

const CrossTarget = struct {
    name: []const u8,
    query: std.Target.Query,
};

const cross_targets = [_]CrossTarget{
    .{ .name = "x86_64-linux-musl", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl } },
    .{ .name = "aarch64-linux-musl", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl } },
    .{ .name = "x86_64-macos", .query = .{ .cpu_arch = .x86_64, .os_tag = .macos } },
    .{ .name = "aarch64-macos", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
    .{ .name = "x86_64-windows", .query = .{ .cpu_arch = .x86_64, .os_tag = .windows } },
    .{ .name = "aarch64-windows", .query = .{ .cpu_arch = .aarch64, .os_tag = .windows } },
};

fn readVersionFromZon(b: *std.Build) ![]const u8 {
    const zon = try std.fs.cwd().readFileAlloc(b.allocator, "build.zig.zon", 64 * 1024);

    const key = ".version";
    const key_idx = std.mem.indexOf(u8, zon, key) orelse return error.VersionKeyNotFound;
    const after_key = zon[key_idx + key.len ..];

    const eq_idx = std.mem.indexOfScalar(u8, after_key, '=') orelse return error.VersionEqualsNotFound;
    const after_eq = after_key[eq_idx + 1 ..];

    const q1 = std.mem.indexOfScalar(u8, after_eq, '"') orelse return error.VersionOpenQuoteNotFound;
    const after_q1 = after_eq[q1 + 1 ..];

    const q2 = std.mem.indexOfScalar(u8, after_q1, '"') orelse return error.VersionCloseQuoteNotFound;
    return after_q1[0..q2];
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Fetch libvaxis dependency
    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    const app_version = readVersionFromZon(b) catch "0.0.0-dev";
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", app_version);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("vaxis", vaxis_dep.module("vaxis"));
    mod.addImport("build_options", build_options.createModule());

    // Main executable
    const exe = b.addExecutable(.{
        .name = "zipet",
        .root_module = mod,
    });
    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run zipet");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("vaxis", vaxis_dep.module("vaxis"));
    test_mod.addImport("build_options", build_options.createModule());

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // ── Cross-compilation: zig build cross ──
    const cross_step = b.step("cross", "Build for all supported platforms (output in zig-out/cross/)");

    for (cross_targets) |ct| {
        const resolved_target = b.resolveTargetQuery(ct.query);

        const cross_vaxis = b.dependency("vaxis", .{
            .target = resolved_target,
            .optimize = .ReleaseSafe,
        });

        const cross_mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = resolved_target,
            .optimize = .ReleaseSafe,
        });
        cross_mod.addImport("vaxis", cross_vaxis.module("vaxis"));
        cross_mod.addImport("build_options", build_options.createModule());

        const cross_exe = b.addExecutable(.{
            .name = b.fmt("zipet-{s}", .{ct.name}),
            .root_module = cross_mod,
        });

        const cross_install = b.addInstallArtifact(cross_exe, .{
            .dest_dir = .{ .override = .{ .custom = "cross" } },
        });
        cross_step.dependOn(&cross_install.step);
    }

    // ── Single cross target: zig build cross-single -Dcross-target=aarch64-linux-musl ──
    const cross_single_step = b.step("cross-single", "Build for a single cross target (use -Dcross-target=<name>)");

    const cross_target_option = b.option([]const u8, "cross-target", "Cross-compilation target (e.g. x86_64-linux-musl, aarch64-macos)");

    if (cross_target_option) |selected_name| {
        for (cross_targets) |ct| {
            if (std.mem.eql(u8, ct.name, selected_name)) {
                const resolved_target = b.resolveTargetQuery(ct.query);

                const single_vaxis = b.dependency("vaxis", .{
                    .target = resolved_target,
                    .optimize = .ReleaseSafe,
                });

                const single_mod = b.createModule(.{
                    .root_source_file = b.path("src/main.zig"),
                    .target = resolved_target,
                    .optimize = .ReleaseSafe,
                });
                single_mod.addImport("vaxis", single_vaxis.module("vaxis"));
                single_mod.addImport("build_options", build_options.createModule());

                const single_exe = b.addExecutable(.{
                    .name = b.fmt("zipet-{s}", .{ct.name}),
                    .root_module = single_mod,
                });

                const single_install = b.addInstallArtifact(single_exe, .{
                    .dest_dir = .{ .override = .{ .custom = "cross" } },
                });
                cross_single_step.dependOn(&single_install.step);
                break;
            }
        }
    }
}

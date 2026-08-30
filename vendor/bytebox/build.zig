const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption(bool, "enable_metering", b.option(bool, "meter", "Enable metering") orelse false);
    options.addOption(bool, "enable_debug_trace", b.option(bool, "debug_trace", "Enable debug tracing") orelse false);
    options.addOption(bool, "enable_debug_trap", b.option(bool, "debug_trap", "Enable debug traps") orelse false);
    options.addOption(bool, "enable_wasi", b.option(bool, "wasi", "Enable WASI") orelse (target.result.os.tag == .wasi));

    const StackVmKind = enum { tailcall, labeled_switch };
    options.addOption(
        StackVmKind,
        "vm_kind",
        b.option(StackVmKind, "vm_kind", "Select the stack VM implementation") orelse .labeled_switch,
    );

    const stable_array = b.dependency("stable_array", .{
        .target = target,
        .optimize = optimize,
    });
    const bytebox = b.addModule("bytebox", .{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    bytebox.addImport("stable-array", stable_array.module("zig-stable-array"));
    bytebox.addOptions("config", options);
}

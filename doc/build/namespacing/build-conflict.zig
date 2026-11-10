const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nasm_dep = b.dependency("nasm", .{
        .target = target,
        .optimize = optimize,
    });
    const binutils_dep = b.dependency("binutils", .{
        .target = target,
        .optimize = optimize,
    });

    // Not shown here: doing something with these dependencies
    _ = nasm_dep;
    _ = binutils_dep;
}

// build=fail

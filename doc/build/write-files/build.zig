const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
        }),
    });

    const version = b.option([]const u8, "version", "application version string") orelse "0.0.0";

    const wf = b.addWriteFiles();
    const app_exe_name = b.fmt("project/{s}", .{exe.out_filename});
    _ = wf.addCopyFile(exe.getEmittedBin(), app_exe_name);
    _ = wf.add("project/version.txt", version);

    const tar = b.addArchive(.{
        .sub_path = "project.tar.gz",
    });
    tar.addDirectory("project/", wf.getDirectory().path(b, "project"));
    const archive_file = tar.generatedFile();

    const install_tar = b.addInstallFileWithDir(archive_file, .prefix, "project.tar.gz");
    b.getInstallStep().dependOn(&install_tar.step);
}

// build=succeed
// additional_option=--summary
// additional_option=all

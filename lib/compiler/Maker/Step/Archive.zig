const Archive = @This();

const std = @import("std");
const Io = std.Io;
const Configuration = std.Build.Configuration;
const Cache = std.Build.Cache;
const assert = std.debug.assert;

const Step = @import("../Step.zig");
const Maker = @import("../../Maker.zig");

pub fn make(
    archive: *Archive,
    step_index: Configuration.Step.Index,
    maker: *Maker,
    progress_node: std.Progress.Node,
) Step.ExtendedMakeError!void {
    _ = archive;

    const gpa = maker.gpa;
    const graph = maker.graph;
    const step = maker.stepByIndex(step_index);
    const io = graph.io;
    const arena = graph.arena; // TODO don't leak into the process arena
    const conf = &maker.scanned_config.configuration;
    const conf_step = step_index.ptr(conf);
    const conf_archive = conf_step.extended.get(conf.extra).archive;

    var tmp_arena_allocator: std.heap.ArenaAllocator = .init(gpa);
    defer tmp_arena_allocator.deinit();
    const tmp_arena = tmp_arena_allocator.allocator();

    var man = graph.cache.obtain();
    defer man.deinit();

    man.hash.add(conf_archive.flags);

    for (conf_archive.entries.slice) |entry| {
        man.hash.addOptional(entry.mtime.get());
        const metadata_only = !entry.flags.mtime;

        switch (entry.flags.tag) {
            .file => {
                const entry_path = entry.path.get().?.slice();
                man.hash.addBytes(entry_path);
                if (entry.bytes) |contents| {
                    assert(!metadata_only);
                    man.hash.addBytes(contents);
                } else if (entry.lazy_path) |lazy_path| {
                    const file_path = try maker.resolveLazyPath(arena, lazy_path, step_index);
                    _ = try man.addInputPath(file_path, .{
                        .handle = .{ .file = null },
                        .metadata_only = metadata_only,
                    });
                } else unreachable;
            },
            .dir => {
                if (entry.lazy_path.get()) |lazy_path| {
                    if (entry.path.get()) |prefix| {
                        man.hash.addBytes(prefix.slice);
                    }
                    const dir_path = try maker.resolveLazyPath(arena, lazy_path, step_index);
                    _ = try man.addInputPath(dir_path, .{
                        .handle = .{ .dir = null },
                        .metadata_only = metadata_only,
                    });
                } else {
                    const entry_path = entry.path.get().?.slice();
                    man.hash.addBytes(entry_path);
                }
            },
            .link => {
                assert(!metadata_only);
                man.hash.addBytes(entry.path.get().?.slice());
                man.hash.addBytes(entry.bytes.get().?.slice());
            },
        }
    }

    const sub_path = conf_archive.sub_path.slice(conf);

    if (try step.cacheHitWatched(maker, &man, progress_node)) {
        const digest = man.hitDigestHex();
        _ = try maker.setGeneratedPath(conf_archive.generated_file, .local_cache, &.{ "o", &digest, sub_path });
        return;
    }

    // Since it's a cache miss, we must walk all the directories and add the discovered files.
    // Then we potentially need to sort. The key is the entry path in the archive, and the value is
    // index into the archive entries list in the configuration.
    const SortableEntry = bitpack struct(u32) {
        index: u31,
        symlink: bool,
    };
    var all_entries: std.array_hash_map.String(SortableEntry) = .empty;
    try all_entries.ensureUnusedCapacity(tmp_arena, conf_archive.entries.slice.len);

    // Add everything to all_entries, recursively walking the lazy directories.
    for (conf_archive.entries.slice, 0..) |entry, i| switch (entry.flags.tag) {
        .file => {
            const entry_path = entry.path.get().?.slice();
            try all_entries.append(tmp_arena, entry_path, .{
                .index = @intCast(i),
                .symlink = false,
            });
        },
        .dir => {
            if (entry.lazy_path.get()) |lazy_path| {
                const metadata_only = !entry.flags.mtime;
                const prefix: []const u8 = if (entry.path.get()) |p| p.slice else "";
                const dir_path = try maker.resolveLazyPath(arena, lazy_path, step_index);

                var dir = dir_path.root_dir.handle.openDir(dir_path.subPathOrDot(), .{
                    .iterate = true,
                    .follow_symlinks = false,
                }) catch |err| switch (err) {
                    error.OutOfMemory, error.Canceled => |e| return e,
                    else => |e| return step.fail(maker, "opening {qf} failed: {t}", .{ dir_path, e }),
                };
                defer dir.close();

                var walker = try dir.walk(gpa);
                defer walker.deinit();

                while (walker.next() catch |err| switch (err) {
                    error.OutOfMemory, error.Canceled => |e| return e,
                    else => |e| return step.fail(maker, "walking {qf} failed: {t}", .{ dir_path, e }),
                }) |dir_entry| {
                    const symlink = switch (dir_entry.kind) {
                        .directory => {
                            var diagnostic: Cache.AddDiscoveredPathDiagnostic = .none;
                            man.addDiscoveredPath(.{
                                .discovered_path = .{
                                    .unresolved = try dir_path.join(tmp_arena, dir_entry.path),
                                },
                                .handle = .{ .dir = null },
                                .metadata_only = metadata_only,
                                .diagnostic = &diagnostic,
                            }) catch |err| switch (err) {
                                else => |e| return e,
                                error.FileSystemFailure => {
                                    return step.fail(maker, "tracking {qf} in cache: {f}", .{diagnostic});
                                },
                            };
                            continue;
                        },
                        .file => false,
                        .sym_link => true,
                        else => return step.fail(maker, "path {qf} of type {t} cannot be stored in {t} archive", .{
                            try dir_path.joinString(tmp_arena, entry.path), entry.kind, conf_archive.format,
                        }),
                    };
                    const entry_path = try std.mem.concat(tmp_arena, u8, &.{ prefix, entry.path });
                    // If necessary, normalize path separators to POSIX-style since the tar format requires that.
                    if (comptime (std.fs.path.sep != std.fs.path.sep_posix)) {
                        std.mem.replaceScalar(u8, entry_path, std.fs.path.sep, std.fs.path.sep_posix);
                    }
                    try all_entries.append(tmp_arena, entry_path, .{
                        .index = @intCast(i),
                        .symlink = symlink,
                    });
                }
            } else {
                const entry_path = entry.path.get().?.slice();
                try all_entries.append(tmp_arena, entry_path, .{
                    .index = @intCast(i),
                    .symlink = false,
                });
            }
        },
        .link => {
            const entry_path = entry.path.get().?.slice();
            try all_entries.append(tmp_arena, entry_path, .{
                .index = @intCast(i),
                .symlink = false,
            });
        },
    };

    const digest = man.missDigestHex();
    const out_path = try maker.setGeneratedPath(conf_archive.generated_file, .local_cache, &.{
        "o", &digest, sub_path,
    });

    if (conf_archive.flags.sort) all_entries.sortUnstable(@as(struct {
        keys: []const []const u8,
        pub fn lessThan(this: @This(), a_index: usize, b_index: usize) bool {
            return std.mem.lessThan(u8, this.keys[a_index], this.keys[b_index]);
        }
    }, .{ .keys = all_entries.keys() }));

    // Finally we can create the archive. This block is for closing the file before writing the
    // cache manifest.
    {
        var file: Io.File = out_path.root_dir.handle.createFile(io, out_path.sub_path, .{}) catch |err| switch (err) {
            error.Canceled => |e| return e,
            error.FileNotFound => f: {
                out_path.root_dir.handle.createDirPath(io, Io.Dir.path.dirname(out_path.sub_path).?) catch |inner| switch (inner) {
                    error.Canceled => |e| return e,
                    else => |e| return step.fail(maker, "failed to create {f}: {t}", .{ out_path, e }),
                };
                break :f out_path.root_dir.handle.createFile(io, out_path.sub_path, .{}) catch |inner| switch (inner) {
                    error.Canceled => |e| return e,
                    else => |e| return step.fail(maker, "failed to create {f}: {t}", .{ out_path, e }),
                };
            },
            else => |e| return step.fail(maker, "failed to create {f}: {t}", .{ out_path, e }),
        };
        defer file.close(io);

        var file_write_buffer: [4096]u8 = undefined;
        var file_writer = file.writer(io, &file_write_buffer);

        // TODO check for if compression is enabled
        var compress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
        var compress = std.compress.flate.Compress.init(&file_writer.interface, &compress_buffer, .gzip, .level_9) catch |err| switch (err) {
            error.WriteFailed => switch (file_writer.err.?) {
                error.Canceled => |e| return e,
                error.WriteFailed => return step.fail(maker, "writing to {f} failed: {t}", .{
                    out_path, file_writer.err.?,
                }),
            },
        };

        var file_read_buffer: [4096]u8 = undefined;
        var archiver: std.tar.Writer = .{
            .underlying_writer = &compress.writer,
        };

        for (all_entries.keys(), all_entries.values()) |entry_path, entry_lookup| {
            const entry = conf_archive.entries.slice[entry_lookup.index];
            switch (entry.tag) {
                .file => {
                    if (entry.bytes) |contents| {
                        archiver.writeFileBytes(entry_path, contents, .{
                            .mtime = entry.mtime.get() orelse 0,
                        }) catch |err| switch (err) {
                            error.WriteFailed => return file_writer.err.?, // TODO
                            //else => |e| @panic("TODO"),
                        };
                    } else if (entry.lazy_path) |lazy_path| {
                        const file_path = try maker.resolveLazyPath(arena, lazy_path, step_index);

                        var input_file = try file_path.root_dir.handle.openFile(io, file_path.sub_path, .{});
                        defer input_file.close(io);

                        const mtime: u64 = entry.mtime.get() orelse m: {
                            const stat = input_file.stat(io) catch |err| switch (err) {
                                error.Canceled => |e| return e,
                                else => |e| return step.fail("failed to stat {f}: {t}", .{ file_path, e }),
                            };
                            break :m @intCast(stat.mtime.toSeconds());
                        };

                        var file_reader: Io.File.Reader = .init(input_file, io, &file_read_buffer);
                        archiver.writeFile(entry_path, &file_reader, mtime) catch |err| switch (err) {
                            error.ReadFailed => return file_reader.err.?, // TODO
                            error.WriteFailed => return file_writer.err.?, // TODO
                            else => |e| return e,
                        };
                    } else unreachable;
                },
                .dir => {
                    if (entry.lazy_path) |lazy_path| {
                        // This is the path to the base directory and the entry_path is the
                        // sub_path.

                    } else {
                        try archiver.writeDir(entry_path, .{ .mtime = mtime });
                    }
                },
                .link => @panic("TODO"),
            }
        }

        compress.finish() catch |err| switch (err) {
            error.WriteFailed => switch (file_writer.err.?) {
                error.Canceled => |e| return e,
                error.WriteFailed => |other| return step.fail(maker, "writing to {f} failed: {t}", .{ out_path, other }),
            },
        };

        file_writer.flush() catch |err| switch (err) {
            error.Canceled => |e| return e,
            error.WriteFailed => |e| return step.fail(maker, "writing to {f} failed: {t}", .{ out_path, e }),
        };
    }

    try step.finalizeManifestAndWatch(maker, &man);
}

//! Pack one or more files into a tarball or zipfile with various format and compression options.
const Archive = @This();

const std = @import("std");
const Step = std.Build.Step;
const Configuration = std.Build.Configuration;
const LazyPath = std.Build.LazyPath;
const assert = std.debug.assert;

step: Step,
generated_file: Configuration.GeneratedFileIndex,
sub_path: Configuration.String,
format: Configuration.Step.Archive.Format,
// TODO account for this in the add* methods
prefix: []const u8,
entries: std.ArrayList(Entry),

pub const base_tag: Step.Tag = .archive;

pub const Entry = struct {
    flags: Configuration.Step.Archive.Entry.Flags,
    path: Configuration.OptionalString = .none,
    lazy_path: ?LazyPath = null,
    bytes: ?Configuration.Bytes = null,
    mode: ?u32,
    mtime: ?u64,
    link_name: Configuration.OptionalString = .none,
};

pub const Options = struct {
    /// Directory components and basename of the output file within the cache.
    sub_path: []const u8,
    format: Configuration.Step.Archive.Format = .infer,
    /// Directory components that will be prepended to all entries.
    prefix: []const u8 = "",
    /// Determines whether the archive's entries will be sorted bytewise by entry name, ascending.
    sort: bool = true,
};

pub fn create(owner: *std.Build, options: Options) *Archive {
    const graph = owner.graph;
    const wc = &graph.wip_configuration;
    const arena = graph.arena;
    const a = graph.create(Archive);
    a.* = .{
        .step = .init(.{
            .tag = base_tag,
            .name = arena.print("tar {s}", .{options.sub_path}) catch @panic("OOM"),
            .owner = owner,
        }),
        .generated_file = graph.addGeneratedFile(&a.step),
        .sub_path = wc.addString(options.sub_path) catch @panic("OOM"),
        .format = options.format,
        .prefix = options.prefix,
    };
    return a;
}

pub const EntryOptions = struct {
    /// File system permission mode.
    mode: Mode = .default,
    /// File system modification time. The file format expects number of seconds since POSIX epoch.
    /// Zero is a common choice to make generated archives more reproducible. Null indicates to
    /// match the file being copied into the archive.
    mtime: ?u64 = 0,

    pub const Mode = union(enum) {
        /// For example 0o755 for directories, 0o666 for files.
        default,
        /// Choose the same value based on the file system of the copied file.
        copied,
        specified: u32,
    };
};

/// Inserts the string `entry_path` into the archive as a directory.
///
/// null mode and mtime are treated the same as zero.
pub fn addDirectoryEntry(a: *Archive, entry_path: []const u8, options: EntryOptions) void {
    assert(options.mode != .copied); // No file being copied into the archive.
    assert(options.mtime != null); // No file being copied into the archive.
    const graph = a.step.owner.graph;
    const wc = &graph.wip_configuration;
    a.entries.append(graph.arena, .{
        .flags = .{
            .tag = .dir,
            .path = true,
            .lazy_path = false,
            .bytes = false,
            .mode = options.mode == .specified,
            .mode_copied = false,
            .mtime = true,
        },
        .path = wc.addString(entry_path) catch @panic("OOM"),
        .mode = switch (options.mode) {
            .specified => |n| n,
            else => null,
        },
        .mtime = options.mtime,
    }) catch @panic("OOM");
}

/// Adds all the files from `lazy_dir`, recursively, into the archive, prefixed by `prefix`, which
/// may be empty.
///
/// null mode and mtime indicate to match the values from the file system when copying into the
/// archive.
///
/// If `prefix` does not include a trailing slash, no trailing slash will be added.
pub fn addDirectory(a: *Archive, prefix: []const u8, lazy_dir: LazyPath, options: EntryOptions) void {
    const graph = a.step.owner.graph;
    const wc = &graph.wip_configuration;
    a.entries.append(graph.arena, .{
        .flags = .{
            .tag = .dir,
            .path = prefix.len != 0,
            .lazy_path = true,
            .bytes = false,
            .mode = options.mode == .specified,
            .mode_copied = options.mode == .copied,
            .mtime = options.mtime != null,
        },
        .path = if (prefix.len == 0) null else wc.addString(prefix) catch @panic("OOM"),
        .lazy_path = lazy_dir,
        .mode = switch (options.mode) {
            .specified => |n| n,
            else => null,
        },
        .mtime = options.mtime,
    }) catch @panic("OOM");
}

/// Adds the file contents of `lazy_path` to the archive, ignoring the file system name and using
/// `entry_path` for the name inside the archive.
pub fn addFile(a: *Archive, entry_path: []const u8, lazy_path: LazyPath, options: EntryOptions) void {
    const graph = a.step.owner.graph;
    const wc = &graph.wip_configuration;
    a.entries.append(graph.arena, .{
        .flags = .{
            .tag = .file,
            .path = true,
            .lazy_path = true,
            .bytes = false,
            .mode = options.mode == .specified,
            .mode_copied = options.mode == .copied,
            .mtime = options.mtime != null,
        },
        .path = wc.addString(entry_path) catch @panic("OOM"),
        .lazy_path = lazy_path,
        .mode = switch (options.mode) {
            .specified => |n| n,
            else => null,
        },
        .mtime = options.mtime,
    }) catch @panic("OOM");
}

/// Adds the provided contents to the archive as a file named `entry_path` inside the archive.
pub fn addFileContents(
    a: *Archive,
    entry_path: []const u8,
    contents: []const u8,
    options: EntryOptions,
) void {
    assert(options.mode != .copied); // No file being copied into the archive.
    assert(options.mtime != null); // No file being copied into the archive.
    const graph = a.step.owner.graph;
    const wc = &graph.wip_configuration;
    a.entries.append(graph.arena, .{
        .flags = .{
            .tag = .file,
            .path = true,
            .lazy_path = false,
            .bytes = true,
            .mode = options.mode == .specified,
            .mode_copied = options.mode == .copied,
            .mtime = true,
        },
        .path = wc.addString(entry_path) catch @panic("OOM"),
        .bytes = wc.addBytes(contents) catch @panic("OOM"),
        .mode = switch (options.mode) {
            .specified => |n| n,
            else => null,
        },
        .mtime = options.mtime,
    }) catch @panic("OOM");
}

/// Adds the provided contents to the archive as a file named `entry_path` inside the archive.
pub fn addLink(a: *Archive, entry_path: []const u8, link_contents: []const u8, options: EntryOptions) void {
    assert(options.mode != .copied); // No file being copied into the archive.
    assert(options.mtime != null); // No file being copied into the archive.
    const graph = a.step.owner.graph;
    const wc = &graph.wip_configuration;
    a.entries.append(graph.arena, .{
        .flags = .{
            .tag = .link,
            .path = true,
            .lazy_path = false,
            .bytes = true,
            .mode = options.mode == .specified,
            .mode_copied = false,
            .mtime = true,
        },
        .path = wc.addString(entry_path) catch @panic("OOM"),
        .bytes = wc.addBytes(link_contents) catch @panic("OOM"),
        .mode = switch (options.mode) {
            .specified => |n| n,
            else => null,
        },
        .mtime = options.mtime,
    }) catch @panic("OOM");
}

/// Returns the main artifact of this `Step` which is the generated archive file.
pub fn generatedFile(a: *Archive) LazyPath {
    return .{ .generated = .{ .index = a.generated_file } };
}

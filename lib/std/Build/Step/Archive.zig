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
prefix: []const u8,
sort: bool,
entries: std.ArrayList(Entry),

pub const base_tag: Step.Tag = .archive;

pub const Entry = struct {
    flags: Configuration.Step.Archive.Entry.Flags,
    path: Configuration.OptionalString = .none,
    lazy_path: ?LazyPath = null,
    bytes: ?Configuration.Bytes = null,
    mtime: ?u64,
};

pub const Options = struct {
    /// Directory components and basename of the output file within the cache.
    sub_path: []const u8,
    /// `null` indicates to infer from `sub_path`.
    format: ?Configuration.Step.Archive.Format = null,
    /// Directory components that will be prepended to all entries. This is a string that is
    /// prepended naively, without being interpreted as a path.
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
        .format = options.format orelse f: {
            if (std.mem.endsWith(u8, options.sub_path, ".tar")) break :f .tar;
            if (std.mem.endsWith(u8, options.sub_path, ".tar.gz")) break :f .tar_gz;
            if (std.mem.endsWith(u8, options.sub_path, ".tar.xz")) break :f .tar_xz;
            if (std.mem.endsWith(u8, options.sub_path, ".tar.zstd")) break :f .tar_zstd;
            if (std.mem.endsWith(u8, options.sub_path, ".zip")) break :f .zip;
            std.debug.panic("unable to infer archive format from extension of file name {q}", .{options.sub_path});
        },
        .prefix = options.prefix,
        .sort = options.sort,
        .entries = .empty,
    };
    return a;
}

pub const EntryOptions = struct {
    /// File system modification time. The file format expects number of seconds since POSIX epoch.
    /// Zero is a common choice to make generated archives more reproducible. Null indicates to
    /// match the file being copied into the archive.
    mtime: ?u64 = 0,
    /// When true, file entries that have a shebang, an ELF header, or a Mach-O executable header
    /// will receive an executable bit. Otherwise, all files will be set to the default file
    /// permission mode.
    detect_executables: bool = true,

    fn assert(eo: *const EntryOptions) void {
        if (eo.mtime) |mtime| _ = std.tar.Writer.Header.Mtime.init(mtime) catch unreachable; // Invalid mtime.
    }
};

/// Inserts the string `entry_path` into the archive as a directory.
///
/// mtime is asserted to be non-null.
pub fn addDirectoryEntry(a: *Archive, entry_path: []const u8, options: EntryOptions) void {
    assert(options.mtime != null); // No file being copied into the archive.
    options.assert();
    const graph = a.step.owner.graph;
    const wc = &graph.wip_configuration;
    a.entries.append(graph.arena, .{
        .flags = .{
            .tag = .dir,
            .path = true,
            .lazy_path = false,
            .bytes = false,
            .mtime = true,
            .detect_executables = options.detect_executables,
        },
        .path = addStringPrefixed(wc, a.prefix, entry_path),
        .mtime = options.mtime,
    }) catch @panic("OOM");
}

/// Adds all the files from `lazy_dir`, recursively, into the archive, prefixed by `prefix`, which
/// may be empty.
///
/// If `prefix` does not include a trailing slash, no trailing slash will be added.
pub fn addDirectory(a: *Archive, prefix: []const u8, lazy_dir: LazyPath, options: EntryOptions) void {
    options.assert();
    const graph = a.step.owner.graph;
    const wc = &graph.wip_configuration;
    const path: Configuration.OptionalString = if (prefix.len == 0 and a.prefix.len == 0)
        .none
    else
        .init(addStringPrefixed(wc, a.prefix, prefix));

    a.entries.append(graph.arena, .{
        .flags = .{
            .tag = .dir,
            .path = path != .none,
            .lazy_path = true,
            .bytes = false,
            .mtime = options.mtime != null,
            .detect_executables = options.detect_executables,
        },
        .path = path,
        .lazy_path = lazy_dir,
        .mtime = options.mtime,
    }) catch @panic("OOM");

    lazy_dir.addStepDependencies(&a.step);
}

/// Adds the file contents of `lazy_path` to the archive, ignoring the file system name and using
/// `entry_path` for the name inside the archive.
pub fn addFile(a: *Archive, entry_path: []const u8, lazy_path: LazyPath, options: EntryOptions) void {
    options.assert();
    const graph = a.step.owner.graph;
    const wc = &graph.wip_configuration;
    a.entries.append(graph.arena, .{
        .flags = .{
            .tag = .file,
            .path = true,
            .lazy_path = true,
            .bytes = false,
            .mtime = options.mtime != null,
            .detect_executables = options.detect_executables,
        },
        .path = addStringPrefixed(wc, a.prefix, entry_path),
        .lazy_path = lazy_path,
        .mtime = options.mtime,
    }) catch @panic("OOM");

    lazy_path.addStepDependencies(&a.step);
}

/// Adds the provided contents to the archive as a file named `entry_path` inside the archive.
pub fn addFileContents(
    a: *Archive,
    entry_path: []const u8,
    contents: []const u8,
    options: EntryOptions,
) void {
    assert(options.mtime != null); // No file being copied into the archive.
    options.assert();
    const graph = a.step.owner.graph;
    const wc = &graph.wip_configuration;
    a.entries.append(graph.arena, .{
        .flags = .{
            .tag = .file,
            .path = true,
            .lazy_path = false,
            .bytes = true,
            .mtime = true,
            .detect_executables = options.detect_executables,
        },
        .path = addStringPrefixed(wc, a.prefix, entry_path),
        .bytes = wc.addBytes(contents) catch @panic("OOM"),
        .mtime = options.mtime,
    }) catch @panic("OOM");
}

/// Adds the provided contents to the archive as a file named `entry_path` inside the archive.
pub fn addLink(a: *Archive, entry_path: []const u8, link_contents: []const u8, options: EntryOptions) void {
    assert(options.mtime != null); // No file being copied into the archive.
    options.assert();
    const graph = a.step.owner.graph;
    const wc = &graph.wip_configuration;
    a.entries.append(graph.arena, .{
        .flags = .{
            .tag = .link,
            .path = true,
            .lazy_path = false,
            .bytes = true,
            .mtime = true,
            .detect_executables = options.detect_executables,
        },
        .path = addStringPrefixed(wc, a.prefix, entry_path),
        .bytes = wc.addBytes(link_contents) catch @panic("OOM"),
        .mtime = options.mtime,
    }) catch @panic("OOM");
}

/// Returns the main artifact of this `Step` which is the generated archive file.
pub fn generatedFile(a: *Archive) LazyPath {
    return .{ .generated = .{ .index = a.generated_file } };
}

fn addStringPrefixed(wc: *Configuration.Wip, prefix: []const u8, string: []const u8) Configuration.String {
    if (prefix.len == 0) return wc.addString(string) catch @panic("OOM");
    const gpa = wc.gpa;
    const concatted = std.mem.concat(gpa, u8, &.{ prefix, string }) catch @panic("OOM");
    defer gpa.free(concatted);
    return wc.addString(concatted) catch @panic("OOM");
}

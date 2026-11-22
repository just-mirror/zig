const Writer = @This();

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const testing = std.testing;

const block_size = @sizeOf(Header);

underlying_writer: *Io.Writer,
/// All file paths will be prefixed with this string in the output.
///
/// Path separators are assumed to be '/'.
prefix: []const u8 = "",

pub const WriteDirOptions = struct {
    /// File system permission mode.
    mode: Header.Mode = .default_dir,
    /// File system modification time. The file format expects number of seconds since POSIX epoch.
    /// Zero is a common choice to make generated tarballs more reproducible.
    mtime: Header.Mtime = .zero,
};

pub fn writeDir(
    writer: *Writer,
    /// The file format uses '/' for path separators. '\\' is allowed in paths, however it is not
    /// considered a path separator, and may cause the archive to be inaccessible on some operating
    /// systems.
    ///
    /// Relative to `prefix`.
    entry_path: []const u8,
    options: WriteDirOptions,
) Io.Writer.Error!void {
    const w = writer.underlying_writer;
    var header: Header = .{
        .typeflag = .directory,
        .mode = options.mode,
        .mtime = options.mtime,
        .size = @splat('0'),
        .checksum = undefined,
    };
    try setPath(w, writer.prefix, &header, entry_path);
    try header.write(w);
}

pub const WriteFileError = Io.Writer.FileAllError || Io.File.Reader.SizeError;

pub const WriteFileOptions = struct {
    /// File system permission mode.
    mode: Header.Mode = .default_file,
    /// File system modification time. The file format expects number of seconds since POSIX epoch.
    /// Zero is a common choice to make generated tarballs more reproducible.
    mtime: Header.Mtime = .zero,
};

pub fn writeFile(
    writer: *Writer,
    /// The file format uses '/' for path separators. '\\' is allowed in paths, however it is not
    /// considered a path separator, and may cause the archive to be inaccessible on some operating
    /// systems.
    ///
    /// Relative to `prefix`.
    entry_path: []const u8,
    file_reader: *Io.File.Reader,
    options: WriteFileOptions,
) WriteFileError!void {
    const w = writer.underlying_writer;
    const size = try file_reader.getSize();
    var header: Header = .{
        .typeflag = .file,
        .mode = options.mode,
        .mtime = options.mtime,
        .size = .initSize(size),
        .checksum = undefined,
    };
    try setPath(w, writer.prefix, &header, entry_path);
    try header.write(w);
    _ = try w.sendFileAll(file_reader, .unlimited);
    try writePadding64(w, size);
}

pub const WriteFileStreamError = Io.Reader.StreamError;

/// Writes content to the archive from `reader`. Reads exactly `size` bytes from `reader`, or
/// returns `error.EndOfStream`.
pub fn writeFileStream(
    writer: *Writer,
    /// The file format uses '/' for path separators. '\\' is allowed in paths, however it is not
    /// considered a path separator, and may cause the archive to be inaccessible on some operating
    /// systems.
    ///
    /// Relative to `prefix`.
    entry_path: []const u8,
    size: u64,
    reader: *Io.Reader,
    options: WriteFileOptions,
) WriteFileStreamError!void {
    const w = writer.underlying_writer;
    var header: Header = .{
        .typeflag = .file,
        .mode = options.mode,
        .mtime = options.mtime,
        .size = .initSize(size),
        .checksum = undefined,
    };
    try setPath(w, writer.prefix, &header, entry_path);
    try header.write(w);
    try reader.streamExact64(w, size);
    try writePadding64(w, size);
}

/// Writes file using bytes buffer `content` for size and file content.
pub fn writeFileBytes(
    writer: *Writer,
    /// The file format uses '/' for path separators. '\\' is allowed in paths, however it is not
    /// considered a path separator, and may cause the archive to be inaccessible on some operating
    /// systems.
    ///
    /// Relative to `prefix`.
    entry_path: []const u8,
    content: []const u8,
    options: WriteFileOptions,
) Io.Writer.Error!void {
    const w = writer.underlying_writer;
    var header: Header = .{
        .typeflag = .file,
        .mode = options.mode,
        .mtime = options.mtime,
        .size = .initSize(content.len),
        .checksum = undefined,
    };
    try setPath(w, writer.prefix, &header, entry_path);
    try header.write(w);
    try w.writeAll(content);
    try writePadding(w, content.len);
}

pub const WriteLinkOptions = struct {
    /// File system permission mode.
    mode: Header.Mode = .default_link,
    /// File system modification time. The file format expects number of seconds since POSIX epoch.
    /// Zero is a common choice to make generated tarballs more reproducible.
    mtime: Header.Mtime = .zero,
};

pub fn writeLink(
    writer: *Writer,
    /// The file format uses '/' for path separators. '\\' is allowed in paths, however it is not
    /// considered a path separator, and may cause the archive to be inaccessible on some operating
    /// systems.
    ///
    /// Relative to `prefix`.
    entry_path: []const u8,
    /// The contents of the link entry. Presumably a path that this link points to.
    link_name: []const u8,
    options: WriteLinkOptions,
) Io.Writer.Error!void {
    const w = writer.underlying_writer;
    var header: Header = .{
        .typeflag = .symbolic_link,
        .mode = options.mode,
        .mtime = options.mtime,
        .size = @splat('0'),
        .checksum = undefined,
    };
    try setPath(w, writer.prefix, &header, entry_path);
    header.setLinkname(link_name) catch |err| switch (err) {
        error.NameTooLong => try writeExtendedHeader(w, .gnu_long_link, &.{link_name}),
    };
    try header.write(w);
}

/// Sets the path field of `header`. If it does not fit (in name+prefix; 100+155 bytes) writes it in gnu
/// extended header.
fn setPath(w: *Io.Writer, prefix: []const u8, header: *Header, sub_path: []const u8) Io.Writer.Error!void {
    header.setPath(prefix, sub_path) catch |err| switch (err) {
        error.NameTooLong => {
            // write extended header
            const buffers: []const []const u8 = if (prefix.len == 0)
                &.{sub_path}
            else
                &.{ prefix, "/", sub_path };
            try w.writeExtendedHeader(w, .gnu_long_name, buffers);
        },
    };
}

/// Writes gnu_long_name or gnu_long_link.
fn writeExtendedHeader(w: *Io.Writer, type_flag: Header.TypeFlag, buffers: []const []const u8) Io.Writer.Error!void {
    var len: usize = 0;
    for (buffers) |buf| len += buf.len;
    var header: Header = .{
        .typeflag = type_flag,
        .size = .initSize(len),
        .mode = .zero,
        .mtime = .zero,
        .checksum = undefined,
    };
    try header.write(w);
    for (buffers) |buf| try w.writeAll(buf);
    try writePadding(w, len);
}

fn writePadding(w: *Io.Writer, bytes: usize) Io.Writer.Error!void {
    return writePaddingPos(w, bytes % block_size);
}

fn writePadding64(w: *Io.Writer, bytes: u64) Io.Writer.Error!void {
    return writePaddingPos(w, @intCast(bytes % block_size));
}

fn writePaddingPos(w: *Io.Writer, pos: usize) Io.Writer.Error!void {
    if (pos == 0) return;
    try w.splatByteAll(0, block_size - pos);
}

/// According to the specification, tar should finish with two zero blocks, but "reasonable system
/// must not assume that such a block exists when reading an archive". Therefore, the Zig standard
/// library recommends to not call this function.
pub fn finishPedantically(w: *Writer) Io.Writer.Error!void {
    try w.underlying_writer.splatByteAll(0, block_size * 2);
}

/// A struct that is exactly 512 bytes and matches tar file format. This is intended to be used for
/// outputting tar files; for parsing there is `std.tar.Header`.
///
/// The name, linkname, magic, uname, and gname are null-terminated character strings. All other
/// fields are zero-filled octal numbers in ASCII. Each numeric field of width w contains w minus 1
/// digits, and a null. Reference: https://www.gnu.org/software/tar/manual/html_node/Standard.html
pub const Header = extern struct {
    name: [100]u8 = @splat(0),
    mode: Mode,
    uid: [7:0]u8 = @splat(0),
    gid: [7:0]u8 = @splat(0),
    size: [11:0]u8,
    mtime: Mtime,
    /// Set by calling `updateChecksum` after setting all other fields.
    checksum: [7:0]u8,
    typeflag: TypeFlag,
    linkname: [100]u8 = @splat(0),
    magic: [6]u8 = .{ 'u', 's', 't', 'a', 'r', 0 },
    version: [2]u8 = .{ '0', '0' },
    uname: [32]u8 = @splat(0),
    gname: [32]u8 = @splat(0),
    devmajor: [7:0]u8 = @splat(0),
    devminor: [7:0]u8 = @splat(0),
    prefix: [155]u8 = @splat(0),
    pad: [12]u8 = @splat(0),

    pub const TypeFlag = enum(u8) {
        regular = '0',
        symbolic_link = '2',
        directory = '5',
        gnu_long_name = 'L',
        gnu_long_link = 'K',
    };

    pub const Mode = extern struct {
        bytes: [7:0]u8,

        pub const default_file: Mode = .{ .bytes = .{ '0', '0', '0', '0', '6', '6', '4' } };
        pub const default_dir: Mode = .{ .bytes = .{ '0', '0', '0', '0', '7', '7', '5' } };
        pub const default_link: Mode = .{ .bytes = .{ '0', '0', '0', '0', '7', '7', '7' } };
        pub const zero: Mode = .{ .bytes = .{ '0', '0', '0', '0', '0', '0', '0' } };

        pub fn init(integer: u32) error{OctalOverflow}!Mode {
            var result: Mode = .{ .bytes = @splat('0') };
            try octal(&result.bytes, integer);
            return result;
        }
    };

    pub const Mtime = extern struct {
        bytes: [11:0]u8,

        /// Keeps generated tarballs reproducible.
        pub const zero: Mtime = .{ .bytes = @splat('0') };

        /// The file format expects number of seconds since POSIX epoch.
        pub fn init(integer: u64) error{OctalOverflow}!Mtime {
            var result: Mtime = .{ .bytes = @splat('0') };
            try octal(&result.bytes, integer);
            return result;
        }

        pub fn fromTimestamp(timestamp: Io.Timestamp) error{OctalOverflow}!Mtime {
            return init(std.math.cast(u64, timestamp.toSeconds()) orelse return error.OctalOverflow);
        }
    };

    pub fn initSize(size: u64) [11:0]u8 {
        var result: [11:0]u8 = @splat('0');
        octal(&result, size) catch |err| switch (err) {
            error.OctalOverflow => @panic("TODO implement POSIX.1-2001 format aka pax to avoid this limitation"),
        };
        return result;
    }

    fn octal(buf: []u8, value: u64) error{OctalOverflow}!void {
        var remainder: u64 = value;
        var pos: usize = buf.len;
        while (remainder > 0 and pos > 0) {
            pos -= 1;
            const c: u8 = @as(u8, @intCast(remainder % 8)) + '0';
            buf[pos] = c;
            remainder /= 8;
            if (pos == 0 and remainder > 0) return error.OctalOverflow;
        }
    }

    pub fn updateChecksum(header: *Header) void {
        header.checksum = @splat(' ');
        var checksum: usize = ' ';
        for (@as([]const u8, @ptrCast(header))) |byte| checksum += byte;
        octal(&header.checksum, checksum) catch |err| switch (err) {
            error.OctalOverflow => unreachable, // Even if all bytes set, not possible.
        };
    }

    pub fn write(h: *Header, writer: *Io.Writer) Io.Writer.Error!void {
        h.updateChecksum();
        try writer.writeAll(@ptrCast(h));
    }

    pub fn setLinkname(w: *Header, link: []const u8) error{NameTooLong}!void {
        if (link.len > w.linkname.len) return error.NameTooLong;
        @memcpy(w.linkname[0..link.len], link);
    }

    pub fn setPath(w: *Header, prefix: []const u8, sub_path: []const u8) error{NameTooLong}!void {
        const max_prefix = w.prefix.len;
        const max_name = w.name.len;
        const sep = std.fs.path.sep_posix;

        if (prefix.len + sub_path.len > max_name + max_prefix or prefix.len > max_prefix)
            return error.NameTooLong;

        // both fit into name
        if (prefix.len > 0 and prefix.len + sub_path.len < max_name) {
            @memcpy(w.name[0..prefix.len], prefix);
            w.name[prefix.len] = sep;
            @memcpy(w.name[prefix.len + 1 ..][0..sub_path.len], sub_path);
            return;
        }

        // sub_path fits into name
        // there is no prefix or prefix fits into prefix
        if (sub_path.len <= max_name) {
            @memcpy(w.name[0..sub_path.len], sub_path);
            @memcpy(w.prefix[0..prefix.len], prefix);
            return;
        }

        if (prefix.len > 0) {
            @memcpy(w.prefix[0..prefix.len], prefix);
            w.prefix[prefix.len] = sep;
        }
        const prefix_pos = if (prefix.len > 0) prefix.len + 1 else 0;

        // add as much to prefix as you can, must split at /
        const prefix_remaining = max_prefix - prefix_pos;
        if (std.mem.findLast(u8, sub_path[0..@min(prefix_remaining, sub_path.len)], &.{'/'})) |sep_pos| {
            @memcpy(w.prefix[prefix_pos..][0..sep_pos], sub_path[0..sep_pos]);
            if ((sub_path.len - sep_pos - 1) > max_name) return error.NameTooLong;
            @memcpy(w.name[0..][0 .. sub_path.len - sep_pos - 1], sub_path[sep_pos + 1 ..]);
            return;
        }

        return error.NameTooLong;
    }

    comptime {
        assert(@sizeOf(Header) == 512);
    }

    test "setPath" {
        const cases = [_]struct {
            in: []const []const u8,
            out: []const []const u8,
        }{
            .{
                .in = &.{ "", "123456789" },
                .out = &.{ "", "123456789" },
            },
            // can fit into name
            .{
                .in = &.{ "prefix", "sub_path" },
                .out = &.{ "", "prefix/sub_path" },
            },
            // no more both fits into name
            .{
                .in = &.{ "prefix", repeatString(8, "0123456789/") ++ "basename" },
                .out = &.{ "prefix", repeatString(8, "0123456789/") ++ "basename" },
            },
            // put as much as you can into prefix the rest goes into name
            .{
                .in = &.{ "prefix", repeatString(10, "0123456789/") ++ "basename" },
                .out = &.{ "prefix/" ++ repeatString(9, "0123456789/") ++ "0123456789", "basename" },
            },

            .{
                .in = &.{ "prefix", repeatString(15, "0123456789/") ++ "basename" },
                .out = &.{ "prefix/" ++ repeatString(12, "0123456789/") ++ "0123456789", "0123456789/0123456789/basename" },
            },
            .{
                .in = &.{ "prefix", repeatString(21, "0123456789/") ++ "basename" },
                .out = &.{ "prefix/" ++ repeatString(12, "0123456789/") ++ "0123456789", repeatString(8, "0123456789/") ++ "basename" },
            },
            .{
                .in = &.{ "", repeatString(10, "012345678/") ++ "foo" },
                .out = &.{ repeatString(9, "012345678/") ++ "012345678", "foo" },
            },
        };

        for (cases) |case| {
            var header = Header.init(.regular);
            try header.setPath(case.in[0], case.in[1]);
            try testing.expectEqualStrings(case.out[0], std.mem.sliceTo(&header.prefix, 0));
            try testing.expectEqualStrings(case.out[1], std.mem.sliceTo(&header.name, 0));
        }

        const error_cases = [_]struct {
            in: []const []const u8,
        }{
            // basename can't fit into name (106 characters)
            .{ .in = &.{ "zig", "test/cases/compile_errors/regression_test_2980_base_type_u32_is_not_type_checked_properly_when_assigning_a_value_within_a_struct.zig" } },
            // cant fit into 255 + sep
            .{ .in = &.{ "prefix", repeatString(22, "0123456789/") ++ "basename" } },
            // can fit but sub_path can't be split (there is no separator)
            .{ .in = &.{ "prefix", repeatString(10, "0123456789") ++ "a" } },
            .{ .in = &.{ "prefix", repeatString(14, "0123456789") ++ "basename" } },
        };

        for (error_cases) |case| {
            var header = Header.init(.regular);
            try testing.expectError(
                error.NameTooLong,
                header.setPath(case.in[0], case.in[1]),
            );
        }
    }
};

test {
    _ = Header;
}

test "write files" {
    const files = [_]struct {
        path: []const u8,
        content: []const u8,
    }{
        .{ .path = "foo", .content = "bar" },
        .{ .path = repeatString(10, "a12345678/") ++ "foo", .content = repeatString(511, "a") },
        .{ .path = repeatString(24, "b12345678/") ++ "foo", .content = repeatString(512, "b") },
        .{ .path = repeatString(25, "c12345678/") ++ "foo", .content = repeatString(513, "c") },
        .{ .path = repeatString(51, "d12345678/") ++ "foo", .content = repeatString(1025, "d") },
        .{ .path = repeatString(11, "e123456789"), .content = "e" },
    };

    var file_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_name_buffer: [std.fs.max_path_bytes]u8 = undefined;

    // with root
    {
        const root = "root";

        var output: Io.Writer.Allocating = .init(testing.allocator);
        var w: Writer = .{ .underlying_writer = &output.writer };
        defer output.deinit();
        try w.setRoot(root);
        for (files) |file|
            try w.writeFileBytes(file.path, file.content, .{});

        var input: Io.Reader = .fixed(output.written());
        var it: std.tar.Iterator = .init(&input, .{
            .file_name_buffer = &file_name_buffer,
            .link_name_buffer = &link_name_buffer,
        });

        // first entry is directory with prefix
        {
            const actual = (try it.next()).?;
            try testing.expectEqualStrings(root, actual.name);
            try testing.expectEqual(std.tar.FileKind.directory, actual.kind);
        }

        var i: usize = 0;
        while (try it.next()) |actual| {
            defer i += 1;
            const expected = files[i];
            try testing.expectEqualStrings(root, actual.name[0..root.len]);
            try testing.expectEqual('/', actual.name[root.len..][0]);
            try testing.expectEqualStrings(expected.path, actual.name[root.len + 1 ..]);

            var content: Io.Writer.Allocating = .init(testing.allocator);
            defer content.deinit();
            try it.streamRemaining(actual, &content.writer);
            try testing.expectEqualSlices(u8, expected.content, content.written());
        }
    }
    // without root
    {
        var output: Io.Writer.Allocating = .init(testing.allocator);
        var w: Writer = .{ .underlying_writer = &output.writer };
        defer output.deinit();
        for (files) |file| {
            var content: Io.Reader = .fixed(file.content);
            try w.writeFileStream(file.path, file.content.len, &content, .{});
        }

        var input: Io.Reader = .fixed(output.written());
        var it: std.tar.Iterator = .init(&input, .{
            .file_name_buffer = &file_name_buffer,
            .link_name_buffer = &link_name_buffer,
        });

        var i: usize = 0;
        while (try it.next()) |actual| {
            defer i += 1;
            const expected = files[i];
            try testing.expectEqualStrings(expected.path, actual.name);

            var content: Io.Writer.Allocating = .init(testing.allocator);
            defer content.deinit();
            try it.streamRemaining(actual, &content.writer);
            try testing.expectEqualSlices(u8, expected.content, content.written());
        }
        try w.finishPedantically();
    }
}

/// Marked `inline` to avoid unnecessary binary float, since arguments are always comptime-known.
/// TODO Delete this as it's used only for tests
inline fn repeatString(comptime n: usize, comptime str: []const u8) []const u8 {
    const buf: [n][str.len]u8 = @splat(str[0..str.len].*);
    return @ptrCast(&buf);
}

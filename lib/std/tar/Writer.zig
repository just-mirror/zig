const Writer = @This();

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const testing = std.testing;

const block_size = @sizeOf(Header);

/// Options for writing file/dir/link. If left empty 0o664 is used for
/// file mode and current time for mtime.
pub const Options = struct {
    /// File system permission mode.
    mode: ?u32 = null,
    /// File system modification time. The file format expects number of seconds since POSIX epoch.
    /// Zero is a common choice to make generated tarballs more reproducible.
    mtime: u64 = 0,
};

underlying_writer: *Io.Writer,

/// All file paths will be prefixed with this string in the output.
///
/// Assumes '/' is used for any path separators.
prefix: []const u8 = "",

const Error = error{
    WriteFailed,
    OctalOverflow,
    NameTooLong,
};

/// Assumes `sub_path` uses `/` for path separators.
pub fn writeDir(writer: *Writer, sub_path: []const u8, options: Options) Error!void {
    return writeHeader(writer.underlying_writer, .directory, .dir, writer.prefix, sub_path, "", 0, options);
}

pub const WriteFileError = Io.Writer.FileError || Error || Io.File.Reader.SizeError;

pub fn writeFileTimestamp(
    w: *Writer,
    /// Assumed to use `/` for any path separators.
    sub_path: []const u8,
    file_reader: *Io.File.Reader,
    mtime: Io.Timestamp,
) WriteFileError!void {
    return writeFile(w, sub_path, file_reader, @intCast(mtime.toSeconds()));
}

pub fn writeFile(
    writer: *Writer,
    /// Assumed to use `/` for any path separators.
    sub_path: []const u8,
    file_reader: *Io.File.Reader,
    /// The file format expects number of seconds since POSIX epoch. Zero is a common choice to make
    /// generated tarballs more reproducible.
    mtime: u64,
) WriteFileError!void {
    const w = writer.underlying_writer;
    const size = try file_reader.getSize();

    var header: Header = .{ .mode = .file };
    try setPath(w, writer.prefix, &header, sub_path);
    try header.setSize(size);
    try header.setMtime(mtime);
    try header.updateChecksum();

    try w.writeAll(@ptrCast((&header)[0..1]));
    _ = try w.sendFileAll(file_reader, .unlimited);
    try writePadding64(w, size);
}

pub const WriteFileStreamError = Error || Io.Reader.StreamError;

/// Writes file reading file content from `reader`. Reads exactly `size` bytes
/// from `reader`, or returns `error.EndOfStream`.
pub fn writeFileStream(
    writer: *Writer,
    /// Assumed to use `/` for any path separators.
    sub_path: []const u8,
    size: u64,
    reader: *Io.Reader,
    options: Options,
) WriteFileStreamError!void {
    const w = writer.underlying_writer;
    try writeHeader(w, .regular, .file, w.prefix, sub_path, "", size, options);
    try reader.streamExact64(w, size);
    try writePadding64(w, size);
}

/// Writes file using bytes buffer `content` for size and file content.
pub fn writeFileBytes(
    writer: *Writer,
    /// Assumed to use `/` for all path separators.
    sub_path: []const u8,
    content: []const u8,
    options: Options,
) Error!void {
    const w = writer.underlying_writer;
    try writeHeader(w, .regular, .file, writer.prefix, sub_path, "", content.len, options);
    try w.writeAll(content);
    try writePadding(w, content.len);
}

pub fn writeLink(writer: *Writer, sub_path: []const u8, link_name: []const u8, options: Options) Error!void {
    try writeHeader(writer.underlying_writer, .symbolic_link, .sym_link, writer.prefix, sub_path, link_name, 0, options);
}

fn writeHeader(
    w: *Io.Writer,
    typeflag: Header.TypeFlag,
    default_mode: Header.Mode,
    prefix: []const u8,
    sub_path: []const u8,
    link_name: []const u8,
    size: u64,
    options: Options,
) Error!void {
    var header: Header = .{
        .typeflag = typeflag,
        .mode = if (options.mode) |mode| try .init(mode) else default_mode,
    };
    try setPath(w, prefix, &header, sub_path);
    try header.setSize(size);
    try header.setMtime(options.mtime);
    if (typeflag == .symbolic_link) header.setLinkname(link_name) catch |err| switch (err) {
        error.NameTooLong => try writeExtendedHeader(w, .gnu_long_link, &.{link_name}),
        else => |e| return e,
    };
    try header.write(w);
}

/// Sets the path field of `header`. If it does not fit (in name+prefix; 100+155 bytes) writes it in gnu
/// extended header.
fn setPath(w: *Io.Writer, prefix: []const u8, header: *Header, sub_path: []const u8) Error!void {
    header.setPath(prefix, sub_path) catch |err| switch (err) {
        error.NameTooLong => {
            // write extended header
            const buffers: []const []const u8 = if (prefix.len == 0)
                &.{sub_path}
            else
                &.{ prefix, "/", sub_path };
            try w.writeExtendedHeader(w, .gnu_long_name, buffers);
        },
        else => |e| return e,
    };
}

/// Writes gnu_long_name or gnu_long_link.
fn writeExtendedHeader(w: *Io.Writer, file_type: Header.TypeFlag, buffers: []const []const u8) Error!void {
    var len: usize = 0;
    for (buffers) |buf| len += buf.len;
    var header: Header = .init(file_type);
    try header.setSize(len);
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

/// According to the specification, tar should finish with two zero blocks, but
/// "reasonable system must not assume that such a block exists when reading an
/// archive". Therefore, the Zig standard library recommends to not call this
/// function.
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
    size: [11:0]u8 = @splat('0'),
    mtime: [11:0]u8 = @splat('0'),
    checksum: [7:0]u8 = @splat(' '),
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

        pub const file: Mode = .{ .bytes = .{ '0', '0', '0', '0', '6', '6', '4' } };
        pub const dir: Mode = .{ .bytes = .{ '0', '0', '0', '0', '7', '7', '5' } };
        pub const sym_link: Mode = .{ .bytes = .{ '0', '0', '0', '0', '7', '7', '7' } };
        pub const other: Mode = .{ .bytes = .{ '0', '0', '0', '0', '0', '0', '0' } };

        pub fn init(integer: u32) error{OctalOverflow}!Mode {
            var result: Mode = .{ .bytes = @splat('0') };
            try octal(&result.bytes, integer);
            return result;
        }
    };

    pub fn setSize(w: *Header, size: u64) error{OctalOverflow}!void {
        try octal(&w.size, size);
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

    // Integer number of seconds since January 1, 1970, 00:00 Coordinated Universal Time.
    pub fn setMtime(w: *Header, mtime: u64) error{OctalOverflow}!void {
        try octal(&w.mtime, mtime);
    }

    pub fn updateChecksum(w: *Header) !void {
        var checksum: usize = ' '; // other 7 w.checksum bytes are initialized to ' '
        for (std.mem.asBytes(w)) |val|
            checksum += val;
        try octal(&w.checksum, checksum);
    }

    pub fn write(h: *Header, bw: *Io.Writer) error{ OctalOverflow, WriteFailed }!void {
        try h.updateChecksum();
        try bw.writeAll(std.mem.asBytes(h));
    }

    pub fn setLinkname(w: *Header, link: []const u8) !void {
        if (link.len > w.linkname.len) return error.NameTooLong;
        @memcpy(w.linkname[0..link.len], link);
    }

    pub fn setPath(w: *Header, prefix: []const u8, sub_path: []const u8) !void {
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
inline fn repeatString(comptime n: usize, comptime str: []const u8) []const u8 {
    const buf: [n][str.len]u8 = @splat(str[0..str.len].*);
    return @ptrCast(&buf);
}

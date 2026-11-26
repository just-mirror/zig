const tar = @import("../tar.zig");

const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const Case = struct {
    const File = struct {
        name: []const u8,
        size: u64 = 0,
        mode: u32 = 0,
        link_name: []const u8 = &[0]u8{},
        kind: tar.FileKind = .file,
        truncated: bool = false, // when there is no file body, just header, useful for huge files
    };

    data: []const u8, // testdata file content
    files: []const File = &[_]@This().File{}, // expected files to found in archive
    chksums: []const []const u8 = &[_][]const u8{}, // chksums of each file content
    err: ?anyerror = null, // parsing should fail with this error
};

const gnu_case: Case = .{
    .data = @embedFile("testdata/gnu.tar"),
    .files = &[_]Case.File{
        .{
            .name = "small.txt",
            .size = 5,
            .mode = 0o640,
        },
        .{
            .name = "small2.txt",
            .size = 11,
            .mode = 0o640,
        },
    },
    .chksums = &[_][]const u8{
        "e38b27eaccb4391bdec553a7f3ae6b2f",
        "c65bd2e50a56a2138bf1716f2fd56fe9",
    },
};

const gnu_multi_headers_case: Case = .{
    .data = @embedFile("testdata/gnu-multi-hdrs.tar"),
    .files = &[_]Case.File{
        .{
            .name = "GNU2/GNU2/long-path-name",
            .link_name = "GNU4/GNU4/long-linkpath-name",
            .kind = .sym_link,
        },
    },
};

const trailing_slash_case: Case = .{
    .data = @embedFile("testdata/trailing-slash.tar"),
    .files = &[_]Case.File{
        .{
            .name = @ptrCast(&@as([30][10]u8, @splat("123456789/".*))),
            .kind = .directory,
        },
    },
};

const writer_big_long_case: Case = .{
    // Size in gnu extended format, and name in pax attribute.
    .data = @embedFile("testdata/writer-big-long.tar"),
    .files = &[_]Case.File{
        .{
            .name = name: {
                const buf: [15][9]u8 = @splat("longname/".*);
                const dir: []const u8 = @ptrCast(&buf);
                break :name dir ++ "16gig.txt";
            },
            .size = 16 * 1024 * 1024 * 1024,
            .mode = 0o644,
            .truncated = true,
        },
    },
};

const fuzz1_case: Case = .{
    .data = @embedFile("testdata/fuzz1.tar"),
    .err = error.TarInsufficientBuffer,
};

test "run test cases" {
    try testCase(gnu_case);
    try testCase(.{
        .data = @embedFile("testdata/sparse-formats.tar"),
        .err = error.TarUnsupportedHeader,
    });
    try testCase(.{
        .data = @embedFile("testdata/star.tar"),
        .files = &[_]Case.File{
            .{
                .name = "small.txt",
                .size = 5,
                .mode = 0o640,
            },
            .{
                .name = "small2.txt",
                .size = 11,
                .mode = 0o640,
            },
        },
        .chksums = &[_][]const u8{
            "e38b27eaccb4391bdec553a7f3ae6b2f",
            "c65bd2e50a56a2138bf1716f2fd56fe9",
        },
    });
    try testCase(.{
        .data = @embedFile("testdata/v7.tar"),
        .files = &[_]Case.File{
            .{
                .name = "small.txt",
                .size = 5,
                .mode = 0o444,
            },
            .{
                .name = "small2.txt",
                .size = 11,
                .mode = 0o444,
            },
        },
        .chksums = &[_][]const u8{
            "e38b27eaccb4391bdec553a7f3ae6b2f",
            "c65bd2e50a56a2138bf1716f2fd56fe9",
        },
    });
    try testCase(.{
        .data = @embedFile("testdata/pax.tar"),
        .files = &[_]Case.File{
            .{
                .name = "a/123456789101112131415161718192021222324252627282930313233343536373839404142434445464748495051525354555657585960616263646566676869707172737475767778798081828384858687888990919293949596979899100",
                .size = 7,
                .mode = 0o664,
            },
            .{
                .name = "a/b",
                .size = 0,
                .kind = .sym_link,
                .mode = 0o777,
                .link_name = "123456789101112131415161718192021222324252627282930313233343536373839404142434445464748495051525354555657585960616263646566676869707172737475767778798081828384858687888990919293949596979899100",
            },
        },
        .chksums = &[_][]const u8{
            "3c382e8f5b6631aa2db52643912ffd4a",
        },
    });
    try testCase(.{
        // pax attribute don't end with \n
        .data = @embedFile("testdata/pax-bad-hdr-file.tar"),
        .err = error.PaxInvalidAttributeEnd,
    });
    try testCase(.{
        // size is in pax attribute
        .data = @embedFile("testdata/pax-pos-size-file.tar"),
        .files = &[_]Case.File{
            .{
                .name = "foo",
                .size = 999,
                .kind = .file,
                .mode = 0o640,
            },
        },
        .chksums = &[_][]const u8{
            "0afb597b283fe61b5d4879669a350556",
        },
    });
    try testCase(.{
        // has pax records which we are not interested in
        .data = @embedFile("testdata/pax-records.tar"),
        .files = &[_]Case.File{
            .{
                .name = "file",
            },
        },
    });
    try testCase(.{
        // has global records which we are ignoring
        .data = @embedFile("testdata/pax-global-records.tar"),
        .files = &[_]Case.File{
            .{
                .name = "file1",
            },
            .{
                .name = "file2",
            },
            .{
                .name = "file3",
            },
            .{
                .name = "file4",
            },
        },
    });
    try testCase(.{
        .data = @embedFile("testdata/nil-uid.tar"),
        .files = &[_]Case.File{
            .{
                .name = "P1050238.JPG.log",
                .size = 14,
                .kind = .file,
                .mode = 0o664,
            },
        },
        .chksums = &[_][]const u8{
            "08d504674115e77a67244beac19668f5",
        },
    });
    try testCase(.{
        // has xattrs and pax records which we are ignoring
        .data = @embedFile("testdata/xattrs.tar"),
        .files = &[_]Case.File{
            .{
                .name = "small.txt",
                .size = 5,
                .kind = .file,
                .mode = 0o644,
            },
            .{
                .name = "small2.txt",
                .size = 11,
                .kind = .file,
                .mode = 0o644,
            },
        },
        .chksums = &[_][]const u8{
            "e38b27eaccb4391bdec553a7f3ae6b2f",
            "c65bd2e50a56a2138bf1716f2fd56fe9",
        },
    });
    try testCase(gnu_multi_headers_case);
    try testCase(.{
        // has gnu type D (directory) and S (sparse) blocks
        .data = @embedFile("testdata/gnu-incremental.tar"),
        .err = error.TarUnsupportedHeader,
    });
    try testCase(.{
        // should use values only from last pax header
        .data = @embedFile("testdata/pax-multi-hdrs.tar"),
        .files = &[_]Case.File{
            .{
                .name = "bar",
                .link_name = "PAX4/PAX4/long-linkpath-name",
                .kind = .sym_link,
            },
        },
    });
    try testCase(.{
        .data = @embedFile("testdata/gnu-long-nul.tar"),
        .files = &[_]Case.File{
            .{
                .name = "0123456789",
                .mode = 0o644,
            },
        },
    });
    try testCase(.{
        .data = @embedFile("testdata/gnu-utf8.tar"),
        .files = &[_]Case.File{
            .{
                .name = "☺☻☹☺☻☹☺☻☹☺☻☹☺☻☹☺☻☹☺☻☹☺☻☹☺☻☹☺☻☹☺☻☹☺☻☹☺☻☹☺☻☹☺☻☹☺☻☹☺☻☹☺☻☹",
                .mode = 0o644,
            },
        },
    });
    try testCase(.{
        .data = @embedFile("testdata/gnu-not-utf8.tar"),
        .files = &[_]Case.File{
            .{
                .name = "hi\x80\x81\x82\x83bye",
                .mode = 0o644,
            },
        },
    });
    try testCase(.{
        // null in pax key
        .data = @embedFile("testdata/pax-nul-xattrs.tar"),
        .err = error.PaxNullInKeyword,
    });
    try testCase(.{
        .data = @embedFile("testdata/pax-nul-path.tar"),
        .err = error.PaxNullInValue,
    });
    try testCase(.{
        .data = @embedFile("testdata/neg-size.tar"),
        .err = error.TarHeader,
    });
    try testCase(.{
        .data = @embedFile("testdata/issue10968.tar"),
        .err = error.TarHeader,
    });
    try testCase(.{
        .data = @embedFile("testdata/issue11169.tar"),
        .err = error.TarHeader,
    });
    try testCase(.{
        .data = @embedFile("testdata/issue12435.tar"),
        .err = error.TarHeaderChksum,
    });
    try testCase(.{
        // has magic with space at end instead of null
        .data = @embedFile("testdata/invalid-go17.tar"),
        .files = &[_]Case.File{
            .{
                .name = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/foo",
            },
        },
    });
    try testCase(.{
        .data = @embedFile("testdata/ustar-file-devs.tar"),
        .files = &[_]Case.File{
            .{
                .name = "file",
                .mode = 0o644,
            },
        },
    });
    try testCase(trailing_slash_case);
    try testCase(.{
        // Has size in gnu extended format. To represent size bigger than 8 GB.
        .data = @embedFile("testdata/writer-big.tar"),
        .files = &[_]Case.File{
            .{
                .name = "tmp/16gig.txt",
                .size = 16 * 1024 * 1024 * 1024,
                .truncated = true,
                .mode = 0o640,
            },
        },
    });
    try testCase(writer_big_long_case);
    try testCase(fuzz1_case);
    try testCase(.{
        .data = @embedFile("testdata/fuzz2.tar"),
        .err = error.PaxSizeAttrOverflow,
    });
}

fn testCase(case: Case) !void {
    var file_name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_name_buffer: [std.fs.max_path_bytes]u8 = undefined;

    var br: std.Io.Reader = .fixed(case.data);
    var it: tar.Iterator = .init(&br, .{
        .file_name_buffer = &file_name_buffer,
        .link_name_buffer = &link_name_buffer,
    });
    var i: usize = 0;
    while (it.next() catch |err| {
        if (case.err) |e| {
            try testing.expectEqual(e, err);
            return;
        } else {
            return err;
        }
    }) |actual| : (i += 1) {
        const expected = case.files[i];
        try testing.expectEqualStrings(expected.name, actual.name);
        try testing.expectEqual(expected.size, actual.size);
        try testing.expectEqual(expected.kind, actual.kind);
        try testing.expectEqual(expected.mode, actual.mode);
        try testing.expectEqualStrings(expected.link_name, actual.link_name);

        if (case.chksums.len > i) {
            var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer aw.deinit();
            try it.streamRemaining(actual, &aw.writer);
            const chksum = std.fmt.bytesToHex(std.crypto.hash.Md5.hashResult(aw.written()), .lower);
            try testing.expectEqualStrings(case.chksums[i], &chksum);
        } else {
            if (expected.truncated) {
                it.unread_file_bytes = 0;
            }
        }
    }
    try testing.expectEqual(case.files.len, i);
}

test "pax/gnu long names with small buffer" {
    try testLongNameCase(gnu_multi_headers_case);
    try testLongNameCase(trailing_slash_case);
    try testLongNameCase(.{
        .data = @embedFile("testdata/fuzz1.tar"),
        .err = error.TarInsufficientBuffer,
    });
}

fn testLongNameCase(case: Case) !void {
    // should fail with insufficient buffer error

    var min_file_name_buffer: [256]u8 = undefined;
    var min_link_name_buffer: [100]u8 = undefined;

    var br: std.Io.Reader = .fixed(case.data);
    var iter: tar.Iterator = .init(&br, .{
        .file_name_buffer = &min_file_name_buffer,
        .link_name_buffer = &min_link_name_buffer,
    });

    var iter_err: ?anyerror = null;
    while (iter.next() catch |err| brk: {
        iter_err = err;
        break :brk null;
    }) |_| {}

    try testing.expect(iter_err != null);
    try testing.expectEqual(error.TarInsufficientBuffer, iter_err.?);
}

test "insufficient buffer in Header name filed" {
    var min_file_name_buffer: [9]u8 = undefined;
    var min_link_name_buffer: [100]u8 = undefined;

    var br: std.Io.Reader = .fixed(gnu_case.data);
    var iter: tar.Iterator = .init(&br, .{
        .file_name_buffer = &min_file_name_buffer,
        .link_name_buffer = &min_link_name_buffer,
    });

    var iter_err: ?anyerror = null;
    while (iter.next() catch |err| brk: {
        iter_err = err;
        break :brk null;
    }) |_| {}

    try testing.expect(iter_err != null);
    try testing.expectEqual(error.TarInsufficientBuffer, iter_err.?);
}

test "should not overwrite existing file" {
    const io = testing.io;
    // Starting from this folder structure:
    // $ tree root
    //    root
    //    ├── a
    //    │   └── b
    //    │       └── c
    //    │           └── file.txt
    //    └── d
    //        └── b
    //            └── c
    //                └── file.txt
    //
    // Packed with command:
    // $ cd root; tar cf overwrite_file.tar *
    // Resulting tar has following structure:
    // $ tar tvf overwrite_file.tar
    //  size path
    //  0    a/
    //  0    a/b/
    //  0    a/b/c/
    //  2    a/b/c/file.txt
    //  0    d/
    //  0    d/b/
    //  0    d/b/c/
    //  2    d/b/c/file.txt
    //
    // Note that there is no root folder in archive.
    //
    // With strip_components = 1 resulting unpacked folder was:
    //  root
    //     └── b
    //         └── c
    //             └── file.txt
    //
    // a/b/c/file.txt is overwritten with d/b/c/file.txt !!!
    // This ensures that file is not overwritten.
    //
    const data = @embedFile("testdata/overwrite_file.tar");
    var r: std.Io.Reader = .fixed(data);

    // Unpack with strip_components = 1 should fail
    var root = std.testing.tmpDir(.{});
    defer root.cleanup();
    try testing.expectError(
        error.CreateFilePathFailed,
        tar.extract(io, root.dir, &r, .{ .mode_mode = .ignore, .strip_components = 1 }),
    );

    // Unpack with strip_components = 0 should pass
    r = .fixed(data);
    var root2 = std.testing.tmpDir(.{});
    defer root2.cleanup();
    try tar.extract(io, root2.dir, &r, .{ .mode_mode = .ignore, .strip_components = 0 });
}

test "case sensitivity" {
    const io = testing.io;
    // Mimicking issue #18089, this tar contains, same file name in two case
    // sensitive name version. Should fail on case insensitive file systems.
    //
    // $ tar tvf 18089.tar
    //     18089/
    //     18089/alacritty/
    //     18089/alacritty/darkermatrix.yml
    //     18089/alacritty/Darkermatrix.yml
    //
    const data = @embedFile("testdata/18089.tar");
    var r: std.Io.Reader = .fixed(data);

    var root = std.testing.tmpDir(.{});
    defer root.cleanup();

    tar.extract(io, root.dir, &r, .{ .mode_mode = .ignore, .strip_components = 1 }) catch |err| {
        // on case insensitive fs we fail on overwrite existing file
        try testing.expectEqual(error.CreateFilePathFailed, err);
        return;
    };

    // on case sensitive os both files are created
    try testing.expect((try root.dir.statFile(io, "alacritty/darkermatrix.yml", .{})).kind == .file);
    try testing.expect((try root.dir.statFile(io, "alacritty/Darkermatrix.yml", .{})).kind == .file);
}

test "header parse size" {
    const cases = [_]struct {
        in: []const u8,
        want: u64 = 0,
        err: ?anyerror = null,
    }{
        // Test base-256 (binary) encoded values.
        .{ .in = "", .want = 0 },
        .{ .in = "\x80", .want = 0 },
        .{ .in = "\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01", .want = 1 },
        .{ .in = "\x80\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x02", .want = 0x0102 },
        .{ .in = "\x80\x00\x00\x00\x01\x02\x03\x04\x05\x06\x07\x08", .want = 0x0102030405060708 },
        .{ .in = "\x80\x00\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09", .err = error.TarNumericValueTooBig },
        .{ .in = "\x80\x00\x00\x00\x07\x76\xa2\x22\xeb\x8a\x72\x61", .want = 537795476381659745 },
        .{ .in = "\x80\x80\x80\x00\x01\x02\x03\x04\x05\x06\x07\x08", .err = error.TarNumericValueTooBig },

        // // Test base-8 (octal) encoded values.
        .{ .in = "00000000227\x00", .want = 0o227 },
        .{ .in = "  000000227\x00", .want = 0o227 },
        .{ .in = "00000000228\x00", .err = error.TarHeader },
        .{ .in = "11111111111\x00", .want = 0o11111111111 },
    };

    for (cases) |case| {
        var bytes: [tar.Header.SIZE]u8 = @splat(0);
        @memcpy(bytes[124 .. 124 + case.in.len], case.in);
        var header: tar.Header = .{ .bytes = &bytes };
        if (case.err) |err| {
            try testing.expectError(err, header.size());
        } else {
            try testing.expectEqual(case.want, try header.size());
        }
    }
}

test "header parse mode" {
    const cases = [_]struct {
        in: []const u8,
        want: u64 = 0,
        err: ?anyerror = null,
    }{
        .{ .in = "0000644\x00", .want = 0o644 },
        .{ .in = "0000777\x00", .want = 0o777 },
        .{ .in = "7777777\x00", .want = 0o7777777 },
        .{ .in = "7777778\x00", .err = error.TarHeader },
        .{ .in = "77777777", .want = 0o77777777 },
        .{ .in = "777777777777", .want = 0o77777777 },
    };
    for (cases) |case| {
        var bytes: [tar.Header.SIZE]u8 = @splat(0);
        @memcpy(bytes[100 .. 100 + case.in.len], case.in);
        var header: tar.Header = .{ .bytes = &bytes };
        if (case.err) |err| {
            try testing.expectError(err, header.mode());
        } else {
            try testing.expectEqual(case.want, try header.mode());
        }
    }
}

test "extract root_dir" {
    const io = testing.io;
    // TODO don't embed test artifacts, construct this with writer API
    const data = @embedFile("testdata/example.tar");
    var reader: Io.Reader = .fixed(data);

    var arena_allocator = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    // with strip_components = 1
    {
        var tmp = testing.tmpDir(.{ .follow_symlinks = false });
        defer tmp.cleanup();
        var diagnostics: tar.Diagnostics = .{ .arena = arena };

        try tar.extractDiagnostics(io, tmp.dir, &reader, &diagnostics, .{
            .strip_components = 1,
        });

        // there is no root_dir
        try testing.expectEqual(0, diagnostics.root_dir.len);
        try testing.expectEqual(5, diagnostics.entries);
    }

    // with strip_components = 0
    {
        reader = .fixed(data);
        var tmp = testing.tmpDir(.{ .follow_symlinks = false });
        defer tmp.cleanup();
        var diagnostics: tar.Diagnostics = .{ .arena = arena };

        try tar.extractDiagnostics(io, tmp.dir, &reader, &diagnostics, .{
            .strip_components = 0,
        });

        // root_dir found
        try testing.expectEqualStrings("example", diagnostics.root_dir);
        try testing.expectEqual(6, diagnostics.entries);
    }
}

test "findRoot with single file archive" {
    const io = testing.io;
    // TODO don't embed test artifacts, construct this with writer API
    const data = @embedFile("testdata/22752.tar");
    var reader: Io.Reader = .fixed(data);

    var arena_allocator = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var diagnostics: tar.Diagnostics = .{ .arena = arena };
    try tar.extractDiagnostics(io, tmp.dir, &reader, &diagnostics, .{});

    try testing.expectEqualStrings("", diagnostics.root_dir);
}

test "findRoot without explicit root dir" {
    const io = testing.io;
    // TODO don't embed test artifacts, construct this with writer API
    const data = @embedFile("testdata/19820.tar");
    var reader: Io.Reader = .fixed(data);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena_allocator = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var diagnostics: tar.Diagnostics = .{ .arena = arena };
    try tar.extractDiagnostics(io, tmp.dir, &reader, &diagnostics, .{});

    try testing.expectEqualStrings("root", diagnostics.root_dir);
}

test "extract strip_components" {
    const io = testing.io;
    // TODO don't embed test artifacts, construct this with writer API
    const data = @embedFile("testdata/example.tar");
    var reader: Io.Reader = .fixed(data);

    var arena_allocator = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var tmp = testing.tmpDir(.{ .follow_symlinks = false });
    defer tmp.cleanup();

    var diagnostics: tar.Diagnostics = .{ .arena = arena };

    try tar.extractDiagnostics(io, tmp.dir, &reader, &diagnostics, .{
        .strip_components = 3,
    });

    try testing.expectEqual(2, diagnostics.errors.items.len);
    try testing.expectEqualStrings("example/b/symlink", diagnostics.errors.items[0].components_outside_stripped_prefix.file_name);
    try testing.expectEqualStrings("example/a/file", diagnostics.errors.items[1].components_outside_stripped_prefix.file_name);
}

test "executable bit" {
    if (!Io.File.Permissions.has_executable_bit) return error.SkipZigTest;

    const io = testing.io;
    const S = std.posix.S;
    // TODO don't embed test artifacts, construct this with writer API
    const data = @embedFile("testdata/example.tar");

    for ([_]tar.ExtractOptions.ModeMode{ .ignore, .executable_bit_only }) |opt| {
        var reader: Io.Reader = .fixed(data);

        var tmp = testing.tmpDir(.{ .follow_symlinks = false });
        defer tmp.cleanup();

        tar.extract(io, tmp.dir, &reader, .{
            .strip_components = 1,
            .exclude_empty_directories = true,
            .mode_mode = opt,
        }) catch |err| switch (err) {
            // Skip on platform which don't support symlinks
            error.UnableToCreateSymLink => return error.SkipZigTest,
            else => |e| return e,
        };

        const fs = try tmp.dir.statFile(io, "a/file", .{});
        try testing.expect(fs.kind == .file);

        const mode = fs.permissions.toMode();

        if (opt == .executable_bit_only) {
            // Executable bit is set for user, group and others
            try testing.expect(mode & S.IXUSR > 0);
            try testing.expect(mode & S.IXGRP > 0);
            try testing.expect(mode & S.IXOTH > 0);
        }
        if (opt == .ignore) {
            try testing.expect(mode & S.IXUSR == 0);
            try testing.expect(mode & S.IXGRP == 0);
            try testing.expect(mode & S.IXOTH == 0);
        }
    }
}

test "extract prevents symlinks from allowing file system access outside the root dir, absolute" {
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var tar_buffer: [5000]u8 = undefined;
    const tar_input_bytes = t: {
        var fixed_writer: Io.Writer = .fixed(&tar_buffer);

        var writer: tar.Writer = .{
            .underlying_writer = &fixed_writer,
        };
        try writer.writeLink("a", "/", .{});
        try writer.writeFileBytes("a/b.txt", "contents", .{});
        break :t fixed_writer.buffered();
    };

    var fixed_reader: Io.Reader = .fixed(tar_input_bytes);
    try testing.expectError(error.TarLinkTargetOutsideStrippedPrefix, tar.extract(io, tmp.dir, &fixed_reader, .{}));
}

test "extract prevents symlinks from allowing file system access outside the root dir, relative" {
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var tar_buffer: [5000]u8 = undefined;
    const tar_input_bytes = t: {
        var fixed_writer: Io.Writer = .fixed(&tar_buffer);

        var writer: tar.Writer = .{
            .underlying_writer = &fixed_writer,
        };
        try writer.writeLink("a", "../", .{});
        try writer.writeFileBytes("a/b.txt", "contents", .{});
        break :t fixed_writer.buffered();
    };

    var fixed_reader: Io.Reader = .fixed(tar_input_bytes);
    try testing.expectError(error.TarLinkTargetOutsideStrippedPrefix, tar.extract(io, tmp.dir, &fixed_reader, .{}));
}

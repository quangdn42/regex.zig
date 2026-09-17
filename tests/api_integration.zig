//! Smoke tests for public `Regex` API integration during development.
//! These are small end-to-end checks across parser, compiler, and engine layers.
test "basic end-to-end" {
    {
        var re = try Regex.compile(gpa, "a(b|c|)\\d", .{});
        defer re.deinit();
        try expect(re.match("ab0"));
        try expect(re.match("ac1"));
        try expect(re.match("a1"));
        try expect(!re.match("aadd"));

        try expectEqual(Match{ .start = 2, .end = 5 }, re.find("xyac12").?);
        try expectEqual(Match{ .start = 2, .end = 4 }, re.find("mna1x").?);
        try expectEqual(null, re.find("aadd"));
    }
    {
        var re = try Regex.compile(gpa, "a\\D", .{});
        defer re.deinit();
        try expect(re.match("aa"));
        try expect(!re.match("a1"));
    }
    {
        var re = try Regex.compile(gpa, "a{2,4}?", .{});
        defer re.deinit();
        try expectEqual(Match{ .start = 0, .end = 2 }, re.find("aaaa").?);
    }
    {
        var re = try Regex.compile(gpa, "^r\\D$", .{});
        defer re.deinit();
        try expect(re.match("re"));
        try expect(!re.match("aarebb"));
    }
    {
        var re = try Regex.compile(gpa, "word\\b", .{});
        defer re.deinit();
        try expect(re.match("sword"));
        try expect(!re.match("swordfish"));
    }
}

test "captures" {
    var re = try Regex.compile(gpa, "(ab)(d)?", .{});
    defer re.deinit();

    try expectEqual(3, re.captureCount());

    const maybe_caps = re.findCaptures("zabx");
    try expect(maybe_caps != null);

    const caps = maybe_caps.?;
    const ab_match: ?Match = .{ .start = 1, .end = 3 };
    try expectEqual(3, caps.len());
    try expectEqual(ab_match, caps.get(0));
    try expectEqual(ab_match, caps.get(1));
    try expectEqual(null, caps.get(2));

    // Preserve capture data
    var buf: [3]?Match = @splat(null);
    const copied = caps.copy(&buf);

    _ = re.find("no match here");

    try expectEqual(3, copied.len);
    try expectEqual(Match{ .start = 1, .end = 3 }, copied[0].?);
    try expectEqual(Match{ .start = 1, .end = 3 }, copied[1].?);
    try expectEqual(null, copied[2]);
}

test "captures keep fallback match after higher-priority branch dies" {
    var re = try Regex.compile(gpa, "(?:abc(?:p|q)z|(a))", .{});
    defer re.deinit();

    // The fallback `(a)` is found before the higher-priority `abc(?:p|q)z`
    // branch dies later at `y`; its slots must remain usable until search returns.
    const caps = re.findCaptures("abcpy") orelse return error.TestUnexpectedResult;
    try expectEqual(2, caps.len());
    try expectEqual(Match{ .start = 0, .end = 1 }, caps.get(0).?);
    try expectEqual(Match{ .start = 0, .end = 1 }, caps.get(1).?);
}

test "find*In with search window" {
    var re = try Regex.compile(gpa, "(ab)", .{});
    defer re.deinit();

    const yes = Regex.Input.init("zabx", .{ .start = 1, .end = 3, .anchored = true });
    try expect(re.matchIn(yes));
    try expectEqual(Match{ .start = 1, .end = 3 }, re.findIn(yes).?);

    const caps = re.findCapturesIn(yes).?;
    try expectEqual(Match{ .start = 1, .end = 3 }, caps.get(0).?);
    try expectEqual(Match{ .start = 1, .end = 3 }, caps.get(1).?);

    const no = Regex.Input.init("zabx", .{ .start = 0, .end = 2, .anchored = true });
    try expect(!re.matchIn(no));
    try expectEqual(null, re.findIn(no));
    try expectEqual(null, re.findCapturesIn(no));
}

test "findAll iterator" {
    {
        var re = try Regex.compile(gpa, "a", .{});
        defer re.deinit();

        var iter = re.findAll("aba");
        try expectEqual(Match{ .start = 0, .end = 1 }, iter.next().?);
        try expectEqual(Match{ .start = 2, .end = 3 }, iter.next().?);
        try expectEqual(null, iter.next());
    }
    {
        var re = try Regex.compile(gpa, "(?<key>\\w+)=(?<val>\\w+)", .{});
        defer re.deinit();

        const haystack = "a=1 b=2";
        var iter = re.findAllCaptures(haystack);

        const caps = iter.next().?;
        try expectEqualStrings("a", caps.name("key").?.bytes(haystack));
        try expectEqualStrings("1", caps.name("val").?.bytes(haystack));
        try expect(iter.next() != null);
        try expectEqual(null, iter.next());
    }
}

test "replace writes the first match and expands captures" {
    var re = try Regex.compile(gpa, "(?<word>[A-Za-z]+)(?:-(\\d+))?", .{});
    defer re.deinit();

    const cases = [_]struct {
        haystack: []const u8,
        replacement: []const u8,
        expected: []const u8,
    }{
        .{
            .haystack = "abc-42!",
            .replacement = "[$0][$1][$2][${word}]",
            .expected = "[abc-42][abc][42][abc]!",
        },
        .{
            .haystack = "abc-42!",
            .replacement = "${2}:$word",
            .expected = "42:abc!",
        },
        // Group 2 exists but did not participate, so it expands to empty.
        .{ .haystack = "abc!", .replacement = "<$2>", .expected = "<>!" },
        .{ .haystack = "abc!", .replacement = "", .expected = "!" },
        .{ .haystack = "!!abc-42?", .replacement = "X", .expected = "!!X?" },
        // Both words match, but only the first is replaced.
        .{ .haystack = "abc def", .replacement = "X", .expected = "X def" },
    };

    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    for (cases) |tc| {
        output.clearRetainingCapacity();
        try expect(try re.replace(&output.writer, tc.haystack, tc.replacement));
        try expectEqualStrings(tc.expected, output.written());
    }

    output.clearRetainingCapacity();
    try output.writer.writeAll("unchanged");
    try expect(!try re.replace(&output.writer, "123", "X"));
    try expectEqualStrings("unchanged", output.written());
}

test "replace handles capture reference edge cases" {
    var re = try Regex.compile(gpa, "h(ell)o", .{});
    defer re.deinit();

    const cases = [_]struct {
        replacement: []const u8,
        expected: []const u8,
    }{
        .{ .replacement = "$", .expected = "$" },
        .{ .replacement = "$$", .expected = "$" },
        .{ .replacement = "$$1", .expected = "$1" },
        .{ .replacement = "$$$", .expected = "$$" },
        .{ .replacement = "$$-", .expected = "$-" },
        .{ .replacement = "$0", .expected = "hello" },
        .{ .replacement = "$1", .expected = "ell" },
        .{ .replacement = "${1}", .expected = "ell" },
        .{ .replacement = "${01}", .expected = "" },
        .{ .replacement = "${1}x", .expected = "ellx" },
        .{ .replacement = "$1x", .expected = "" },
        .{ .replacement = "$2", .expected = "" },
        .{ .replacement = "$name", .expected = "" },
        .{ .replacement = "${name}", .expected = "" },
        .{ .replacement = "${}", .expected = "" },
        .{ .replacement = "$-", .expected = "$-" },
        .{ .replacement = "$}", .expected = "$}" },
        .{ .replacement = "${oops", .expected = "${oops" },
        .{ .replacement = "$\xC3\xA9", .expected = "$\xC3\xA9" },
        .{ .replacement = "a$1b", .expected = "a" },
        .{ .replacement = "a${1}b", .expected = "aellb" },
        .{ .replacement = "x$", .expected = "x$" },
    };

    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    for (cases) |tc| {
        output.clearRetainingCapacity();
        try expect(try re.replace(&output.writer, "hello", tc.replacement));
        try expectEqualStrings(tc.expected, output.written());
    }
}

test "replace expands multiple references and only the first match" {
    var re = try Regex.compile(gpa, "(\\w+) (\\d+)", .{});
    defer re.deinit();

    const cases = [_]struct {
        haystack: []const u8,
        replacement: []const u8,
        expected: []const u8,
    }{
        .{ .haystack = "July 17", .replacement = "${2}-${1}", .expected = "17-July" },
        // The second haystack position also matches but is left untouched.
        .{ .haystack = "July 17, 2026", .replacement = "$1", .expected = "July, 2026" },
    };

    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    for (cases) |tc| {
        output.clearRetainingCapacity();
        try expect(try re.replace(&output.writer, tc.haystack, tc.replacement));
        try expectEqualStrings(tc.expected, output.written());
    }
}

test "replace classifies numeric and named capture references" {
    var re = try Regex.compile(
        gpa,
        "(a)(?<1>b)(?<1_2>c)(?<01>d)(?<1x>e)(?<65536>f)",
        .{},
    );
    defer re.deinit();

    const cases = [_]struct {
        replacement: []const u8,
        expected: []const u8,
    }{
        .{ .replacement = "$1", .expected = "a" },
        .{ .replacement = "${1}", .expected = "a" },
        .{ .replacement = "$2", .expected = "b" },
        .{ .replacement = "$1_2", .expected = "c" },
        .{ .replacement = "${1_2}", .expected = "c" },
        .{ .replacement = "$01", .expected = "d" },
        .{ .replacement = "${01}", .expected = "d" },
        .{ .replacement = "$1x", .expected = "e" },
        .{ .replacement = "${1x}", .expected = "e" },
        .{ .replacement = "$65536", .expected = "" },
        .{ .replacement = "${65536}", .expected = "" },
    };

    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    for (cases) |tc| {
        output.clearRetainingCapacity();
        try expect(try re.replace(&output.writer, "abcdef", tc.replacement));
        try expectEqualStrings(tc.expected, output.written());
    }
}

test "replaceAlloc returns an owned first replacement" {
    var re = try Regex.compile(gpa, "(?<word>[A-Za-z]+)(?:-(\\d+))?", .{});
    defer re.deinit();

    const cases = [_]struct {
        haystack: []const u8,
        replacement: []const u8,
        expected: []const u8,
    }{
        .{ .haystack = "abc-42!", .replacement = "$2-$1", .expected = "42-abc!" },
        .{ .haystack = "abc!", .replacement = "X", .expected = "X!" },
    };

    for (cases) |tc| {
        const actual = try re.replaceAlloc(gpa, tc.haystack, tc.replacement) orelse
            return error.TestUnexpectedResult;
        defer gpa.free(actual);
        try expectEqualStrings(tc.expected, actual);
    }

    try expect(try re.replaceAlloc(gpa, "123", "X") == null);
}

test "replaceWith literal does not expand capture references" {
    var re = try Regex.compile(gpa, "(abc)", .{});
    defer re.deinit();

    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    const replacer: Regex.Replacer = .{ .literal = "<$1>" };
    try expect(try re.replaceWith(&output.writer, "!abc?abc", replacer));
    try expectEqualStrings("!<$1>?abc", output.written());

    output.clearRetainingCapacity();
    try output.writer.writeAll("unchanged");
    try expect(!try re.replaceWith(&output.writer, "123", .{ .literal = "X" }));
    try expectEqualStrings("unchanged", output.written());
}

test "replaceAll expands captures for every match" {
    var re = try Regex.compile(gpa, "(?<key>\\w+)=(?<value>\\w+)", .{});
    defer re.deinit();

    const cases = [_]struct {
        replacement: []const u8,
        expected: []const u8,
    }{
        .{ .replacement = "$value:$key", .expected = "1:a 2:b" },
        .{ .replacement = "<$0>", .expected = "<a=1> <b=2>" },
        .{ .replacement = "$$", .expected = "$ $" },
        .{ .replacement = "X", .expected = "X X" },
    };

    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    for (cases) |tc| {
        output.clearRetainingCapacity();
        try expect(try re.replaceAll(&output.writer, "a=1 b=2", tc.replacement));
        try expectEqualStrings(tc.expected, output.written());
    }

    const allocated = try re.replaceAllAlloc(gpa, "a=1 b=2", "$value:$key") orelse
        return error.TestUnexpectedResult;
    defer gpa.free(allocated);
    try expectEqualStrings("1:a 2:b", allocated);

    output.clearRetainingCapacity();
    try output.writer.writeAll("unchanged");
    try expect(!try re.replaceAll(&output.writer, "no assignments", "X"));
    try expectEqualStrings("unchanged", output.written());
    try expect(try re.replaceAllAlloc(gpa, "no assignments", "X") == null);

    var empty = try Regex.compile(gpa, "", .{});
    defer empty.deinit();
    output.clearRetainingCapacity();
    try expect(try empty.replaceAll(&output.writer, "ab", "<$0>"));
    try expectEqualStrings("<>a<>b<>", output.written());
}

test "replaceAllWith literal writes every literal replacement" {
    var re = try Regex.compile(gpa, "[ ,]+", .{});
    defer re.deinit();

    const cases = [_]struct {
        haystack: []const u8,
        replacement: []const u8,
        expected: []const u8,
    }{
        .{ .haystack = "a, b  c", .replacement = "|", .expected = "a|b|c" },
        .{ .haystack = ",a,", .replacement = "_", .expected = "_a_" },
        .{ .haystack = "a, b", .replacement = "", .expected = "ab" },
        .{ .haystack = "a, b  c", .replacement = "$1", .expected = "a$1b$1c" },
    };

    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    for (cases) |tc| {
        output.clearRetainingCapacity();
        try expect(try re.replaceAllWith(
            &output.writer,
            tc.haystack,
            .{ .literal = tc.replacement },
        ));
        try expectEqualStrings(tc.expected, output.written());
    }

    output.clearRetainingCapacity();
    try output.writer.writeAll("unchanged");
    try expect(!try re.replaceAllWith(&output.writer, "abc", .{ .literal = "X" }));
    try expectEqualStrings("unchanged", output.written());

    var empty = try Regex.compile(gpa, "", .{});
    defer empty.deinit();
    output.clearRetainingCapacity();
    try expect(try empty.replaceAllWith(&output.writer, "ab", .{ .literal = "-" }));
    try expectEqualStrings("-a-b-", output.written());
}

test "split iterator" {
    const cases = [_]struct {
        pattern: []const u8,
        haystack: []const u8,
        expected: []const []const u8,
    }{
        .{
            .pattern = "[ \\t]+",
            .haystack = "a b \t  c\td    e",
            .expected = &.{ "a", "b", "c", "d", "e" },
        },
        .{
            .pattern = "X",
            .haystack = "",
            .expected = &.{""},
        },
        .{
            .pattern = "X",
            .haystack = "abc",
            .expected = &.{"abc"},
        },
        .{
            .pattern = "X",
            .haystack = "lionXXtigerXleopard",
            .expected = &.{ "lion", "", "tiger", "leopard" },
        },
        .{
            .pattern = "0",
            .haystack = "010",
            .expected = &.{ "", "1", "" },
        },
        .{
            .pattern = "",
            .haystack = "zig",
            .expected = &.{ "", "z", "i", "g", "" },
        },
        .{
            .pattern = "",
            .haystack = "",
            .expected = &.{ "", "" },
        },
        .{
            .pattern = "",
            .haystack = "\xE2\x98\x83",
            .expected = &.{ "", "\xE2", "\x98", "\x83", "" },
        },
    };

    for (cases) |tc| {
        try expectSplit(tc.pattern, tc.haystack, tc.expected);
    }
}

test "splitN iterator" {
    const cases = [_]struct {
        pattern: []const u8,
        haystack: []const u8,
        limit: usize,
        expected: []const []const u8,
    }{
        .{
            .pattern = ",",
            .haystack = "a,b,c",
            .limit = 0,
            .expected = &[_][]const u8{},
        },
        .{
            .pattern = ",",
            .haystack = "a,b,c",
            .limit = 1,
            .expected = &.{"a,b,c"},
        },
        .{
            .pattern = ",",
            .haystack = "a,b,c",
            .limit = 2,
            .expected = &.{ "a", "b,c" },
        },
        .{
            .pattern = ",",
            .haystack = "a,b,c",
            .limit = 3,
            .expected = &.{ "a", "b", "c" },
        },
        .{
            .pattern = ",",
            .haystack = "a,b,c",
            .limit = 8,
            .expected = &.{ "a", "b", "c" },
        },
        .{
            .pattern = "X",
            .haystack = "abc",
            .limit = 3,
            .expected = &.{"abc"},
        },
        .{
            .pattern = "X",
            .haystack = "lionXXtigerXleopard",
            .limit = 3,
            .expected = &.{ "lion", "", "tigerXleopard" },
        },
        .{
            .pattern = "",
            .haystack = "zig",
            .limit = 3,
            .expected = &.{ "", "z", "ig" },
        },
        .{
            .pattern = "",
            .haystack = "",
            .limit = 2,
            .expected = &.{ "", "" },
        },
    };

    for (cases) |tc| {
        try expectSplitN(tc.pattern, tc.haystack, tc.limit, tc.expected);
    }
}

test "splitIn restricts output to the input window" {
    var re = try Regex.compile(gpa, ",", .{});
    defer re.deinit();

    const haystack = "xx,a,b,yy";
    const input: Regex.Input = .init(haystack, .{ .start = 2, .end = 7 });
    var iter = re.splitIn(input);
    const expected = [_]Span{
        .{ .start = 2, .end = 2 },
        .{ .start = 3, .end = 4 },
        .{ .start = 5, .end = 6 },
        .{ .start = 7, .end = 7 },
    };

    for (expected) |span| {
        try expectEqual(span, iter.next().?);
    }
    try expectEqual(null, iter.next());

    var bytes = re.splitIn(input);
    for ([_][]const u8{ "", "a", "b", "" }) |part| {
        try expectEqualStrings(part, bytes.nextBytes().?);
    }
    try expectEqual(null, bytes.nextBytes());

    var empty = re.splitIn(.init(haystack, .{ .start = 3, .end = 3 }));
    try expectEqual(Span{ .start = 3, .end = 3 }, empty.next().?);
    try expectEqual(null, empty.next());

    var anchored = re.splitIn(.init(haystack, .{
        .start = 2,
        .end = 7,
        .anchored = true,
    }));
    try expectEqual(Span{ .start = 2, .end = 2 }, anchored.next().?);
    try expectEqual(Span{ .start = 3, .end = 7 }, anchored.next().?);
    try expectEqual(null, anchored.next());
}

test "splitNIn limits spans within the input window" {
    var re = try Regex.compile(gpa, ",", .{});
    defer re.deinit();

    const haystack = "xx,a,b,yy";
    const input: Regex.Input = .init(haystack, .{ .start = 2, .end = 7 });
    var iter: Regex.SplitNIterator = re.splitNIn(input, 2);
    try expectEqual(Span{ .start = 2, .end = 2 }, iter.next().?);
    try expectEqual(Span{ .start = 3, .end = 7 }, iter.next().?);
    try expectEqual(null, iter.next());
    try expectEqual(null, iter.next());

    var bytes = re.splitNIn(input, 2);
    try expectEqualStrings("", bytes.nextBytes().?);
    try expectEqualStrings("a,b,", bytes.nextBytes().?);
    try expectEqual(null, bytes.nextBytes());

    var anchored = re.splitNIn(.init(haystack, .{
        .start = 2,
        .end = 7,
        .anchored = true,
    }), 3);
    try expectEqual(Span{ .start = 2, .end = 2 }, anchored.next().?);
    try expectEqual(Span{ .start = 3, .end = 7 }, anchored.next().?);
    try expectEqual(null, anchored.next());
}

test "named capture metadata and lookup" {
    var re = try Regex.compile(gpa, "(?<a>.(?<b>.))(.)(?:.)(?<c>.)", .{});
    defer re.deinit();

    const index_cases = [_]struct {
        name: []const u8,
        expected: ?usize,
    }{
        .{ .name = "a", .expected = 1 },
        .{ .name = "b", .expected = 2 },
        .{ .name = "c", .expected = 4 },
        .{ .name = "missing", .expected = null },
    };
    for (index_cases) |tc| {
        try expectEqual(tc.expected, re.captureIndex(tc.name));
    }

    var names = re.captureNames();
    const expected_names = [_]?[]const u8{ null, "a", "b", null, "c" };
    for (expected_names) |expected_name| {
        const actual_name = names.next() orelse return error.TestUnexpectedResult;
        if (expected_name) |name| {
            try expect(actual_name != null);
            try expectEqualStrings(name, actual_name.?);
        } else {
            try expect(actual_name == null);
        }
    }
    try expectEqual(null, names.next());

    const haystack = "abXYZ";
    const caps = re.findCaptures(haystack).?;
    const capture_cases = [_]struct {
        name: []const u8,
        span: Match,
        text: []const u8,
    }{
        .{ .name = "a", .span = .{ .start = 0, .end = 2 }, .text = "ab" },
        .{ .name = "b", .span = .{ .start = 1, .end = 2 }, .text = "b" },
        .{ .name = "c", .span = .{ .start = 4, .end = 5 }, .text = "Z" },
    };
    for (capture_cases) |tc| {
        const actual = caps.name(tc.name) orelse return error.TestUnexpectedResult;
        try expectEqual(tc.span, actual);
        try expectEqualStrings(tc.text, actual.bytes(haystack));
    }
    try expectEqual(null, caps.name("missing"));
}

test "named captures can be absent in a match" {
    var re = try Regex.compile(
        gpa,
        "(?<letters>[A-Za-z]+)(?:(?<digits>\\d+)|(?<punct>[!?]+))",
        .{},
    );
    defer re.deinit();

    const cases = [_]struct {
        haystack: []const u8,
        full: []const u8,
        letters: []const u8,
        digits: ?[]const u8,
        punct: ?[]const u8,
    }{
        .{
            .haystack = "abc123",
            .full = "abc123",
            .letters = "abc",
            .digits = "123",
            .punct = null,
        },
        .{
            .haystack = "abc!!",
            .full = "abc!!",
            .letters = "abc",
            .digits = null,
            .punct = "!!",
        },
    };

    for (cases) |tc| {
        const caps = re.findCaptures(tc.haystack).?;
        try expectEqualStrings(tc.full, caps.get(0).?.bytes(tc.haystack));
        try expectEqualStrings(tc.letters, caps.name("letters").?.bytes(tc.haystack));

        if (tc.digits) |digits| {
            try expectEqualStrings(digits, caps.name("digits").?.bytes(tc.haystack));
        } else {
            try expectEqual(null, caps.name("digits"));
        }

        if (tc.punct) |punct| {
            try expectEqualStrings(punct, caps.name("punct").?.bytes(tc.haystack));
        } else {
            try expectEqual(null, caps.name("punct"));
        }
    }
}

test "duplicate named captures" {
    const pattern = "(?<x>a)(?P<x>b)";

    var diag: Diagnostics = undefined;
    try expectError(error.Parse, Regex.compile(gpa, pattern, .{
        .diag = &diag,
    }));

    switch (diag) {
        .parse => |parse_diag| {
            try expectEqual(.group_name_duplicated, parse_diag.err);
            try expectEqual(Span{ .start = 11, .end = 12 }, parse_diag.span);
            try expectEqual(Span{ .start = 3, .end = 4 }, parse_diag.aux_span);
            try expect(parse_diag.span.isValidFor(pattern.len));
        },
        .compile => return error.TestUnexpectedResult,
    }
}

test "non capturing groups" {
    {
        var re = try Regex.compile(gpa, "(?i)Re", .{});
        defer re.deinit();
        try expect(re.match("rE"));
        try expect(re.match("re"));
    }
    {
        var re = try Regex.compile(gpa, "(?i:Re)", .{});
        defer re.deinit();
        try expect(re.match("rE"));
        try expect(re.match("re"));
    }
    {
        var re = try Regex.compile(gpa, "(?i)(?-i:Re)", .{});
        defer re.deinit();
        try expect(!re.match("rE"));
        try expect(!re.match("re"));
    }
    {
        var re = try Regex.compile(gpa, "(?m:^re$)", .{});
        defer re.deinit();
        try expect(re.match("ab\nre\ncd"));
        try expect(re.match("re"));
    }
    {
        var re = try Regex.compile(gpa, "(?sm:^re.l)", .{});
        defer re.deinit();
        try expect(re.match("ab\nre\nld"));
        try expect(re.match("real"));
    }
    {
        var re = try Regex.compile(gpa, "(?U:^re+)", .{});
        defer re.deinit();
        try expectEqual(Match{ .start = 0, .end = 2 }, re.find("reeee"));
    }
}

test "syntax options" {
    {
        var re = try Regex.compile(gpa, "^ab$", .{
            .syntax = .{ .multi_line = true },
        });
        defer re.deinit();
        try expectEqual(Match{ .start = 3, .end = 5 }, re.find("zz\nab\nyy").?);
    }
    {
        var re = try Regex.compile(gpa, "a+", .{
            .syntax = .{ .swap_greed = true },
        });
        defer re.deinit();
        try expectEqual(Match{ .start = 0, .end = 1 }, re.find("aa").?);
    }
}

test "assertions" {
    {
        var re = try Regex.compile(gpa, "foo\\b", .{});
        defer re.deinit();
        try expect(re.match("foo"));
        try expect(!re.match("foobar"));
    }
    {
        var re = try Regex.compile(gpa, "\\B\\W", .{});
        defer re.deinit();
        try expect(re.match("!a"));
        try expect(!re.match("a!"));
    }
    {
        var re = try Regex.compile(gpa, "\\Aab", .{});
        defer re.deinit();
        try expect(re.match("ab"));
        try expect(!re.match("zab"));
        try expectEqual(Match{ .start = 0, .end = 2 }, re.find("ab").?);
        try expectEqual(null, re.find("zab"));
    }
    {
        var re = try Regex.compile(gpa, "ab\\z", .{});
        defer re.deinit();
        try expect(re.match("zab"));
        try expect(!re.match("abz"));
        try expectEqual(Match{ .start = 1, .end = 3 }, re.find("zab").?);
        try expectEqual(null, re.find("abz"));
    }
    {
        var re = try Regex.compile(gpa, "\\Aab\\z", .{});
        defer re.deinit();
        try expect(re.match("ab"));
        try expect(!re.match("zab"));
        try expect(!re.match("abz"));
    }
}

test "dot matches new line option" {
    {
        var re = try Regex.compile(gpa, ".", .{});
        defer re.deinit();
        try expect(re.match("a"));
        try expect(!re.match("\n"));
    }
    {
        var re = try Regex.compile(gpa, ".", .{ .syntax = .{ .dot_matches_new_line = true } });
        defer re.deinit();
        try expect(re.match("a"));
        try expect(re.match("\n"));
    }
    {
        var re = try Regex.compile(gpa, "a.b", .{});
        defer re.deinit();
        try expect(!re.match("a\nb"));
    }
    {
        var re = try Regex.compile(gpa, "a.b", .{ .syntax = .{ .dot_matches_new_line = true } });
        defer re.deinit();
        try expect(re.match("a\nb"));
    }
}

test "byte-first unicode scalar compilation" {
    {
        var re = try Regex.compile(gpa, "α", .{});
        defer re.deinit();
        try expect(re.match("α"));
        try expect(!re.match("a"));
        try expectEqual(Match{ .start = 0, .end = 2 }, re.find("α").?);
    }
    {
        var re = try Regex.compile(gpa, ".", .{});
        defer re.deinit();
        try expectEqual(Match{ .start = 0, .end = 1 }, re.find("α").?);
    }
    {
        var re = try Regex.compile(gpa, "(?u).", .{});
        defer re.deinit();
        try expectEqual(Match{ .start = 0, .end = 2 }, re.find("α").?);
        try expect(!re.match(&[_]u8{0xFF}));
    }
    {
        var re = try Regex.compile(gpa, "(?u)[α-ω]", .{});
        defer re.deinit();
        try expect(re.match("β"));
        try expect(!re.match("A"));
    }
    try expectCompileDiag("[α-ω]", .unicode_in_byte_mode);
    try expectCompileDiag("\\x{03B1}", .unicode_in_byte_mode);
    try expectCompileDiag("[\\x{03B1}]", .unicode_in_byte_mode);
    {
        var re = try Regex.compile(gpa, "(?u)\\x{03B1}", .{});
        defer re.deinit();
        try expect(re.match("α"));
    }
    {
        var re = try Regex.compile(gpa, "\\A\\xCE\\z", .{});
        defer re.deinit();
        try expect(re.match(&[_]u8{0xCE}));
        try expect(!re.match("α"));
    }
    {
        var re = try Regex.compile(gpa, "(?u)\\A\\xCE\\z", .{});
        defer re.deinit();
        try expect(re.match("Î"));
        try expect(!re.match(&[_]u8{0xCE}));
    }
}

test "ignore case option" {
    {
        var re = try Regex.compile(gpa, "\\Aabc\\z", .{});
        defer re.deinit();
        try expect(!re.match("ABC"));
    }
    {
        var re = try Regex.compile(gpa, "\\Aabc\\z", .{ .syntax = .{ .case_insensitive = true } });
        defer re.deinit();
        try expect(re.match("ABC"));
    }
    {
        var re = try Regex.compile(gpa, "\\A[a-z]+\\z", .{});
        defer re.deinit();
        try expect(!re.match("AB"));
    }
    {
        var re = try Regex.compile(
            gpa,
            "\\A[a-z]+\\z",
            .{ .syntax = .{ .case_insensitive = true } },
        );
        defer re.deinit();
        try expect(re.match("AB"));
    }
    {
        var re = try Regex.compile(
            gpa,
            "\\A[0-Z]\\z",
            .{ .syntax = .{ .case_insensitive = true } },
        );
        defer re.deinit();
        try expect(re.match("a"));
    }
    {
        var re = try Regex.compile(gpa, "\\A[[:^lower:]]+\\z", .{});
        defer re.deinit();
        try expect(re.match("AZ"));
    }
    {
        var re = try Regex.compile(
            gpa,
            "\\A[[:^lower:]]+\\z",
            .{ .syntax = .{ .case_insensitive = true } },
        );
        defer re.deinit();
        try expect(!re.match("AZ"));
    }
    {
        var re = try Regex.compile(
            gpa,
            "\\A\\w+\\z",
            .{ .syntax = .{ .case_insensitive = true } },
        );
        defer re.deinit();
        try expect(re.match("aZ_0"));
    }
    {
        var re = try Regex.compile(
            gpa,
            "\\A\\W+\\z",
            .{ .syntax = .{ .case_insensitive = true } },
        );
        defer re.deinit();
        try expect(re.match("!@"));
        try expect(!re.match("AZ"));
    }
    {
        var re = try Regex.compile(gpa, "\\A[[:lower:]]+\\z", .{});
        defer re.deinit();
        try expect(!re.match("AB"));
    }
    {
        var re = try Regex.compile(
            gpa,
            "\\A[[:lower:]]+\\z",
            .{ .syntax = .{ .case_insensitive = true } },
        );
        defer re.deinit();
        try expect(re.match("AB"));
    }
    {
        var re = try Regex.compile(gpa, "\\A[[:upper:]]+\\z", .{});
        defer re.deinit();
        try expect(!re.match("ab"));
    }
    {
        var re = try Regex.compile(gpa, "(?iu)\\A[[:upper:]]+\\z", .{});
        defer re.deinit();
        try expect(re.match("ab"));
        try expect(re.match("K"));
    }
}

test "unicode simple case folding" {
    {
        var re = try Regex.compile(gpa, "(?iu)\\Ak\\z", .{});
        defer re.deinit();
        try expect(re.match("k"));
        try expect(re.match("K"));
        try expect(re.match("K"));
    }
    {
        var re = try Regex.compile(gpa, "(?i)\\Ak\\z", .{});
        defer re.deinit();
        try expect(re.match("K"));
        try expect(!re.match("K"));
    }
    {
        var re = try Regex.compile(gpa, "(?i)\\AK\\z", .{});
        defer re.deinit();
        try expect(re.match("K"));
        try expect(!re.match("K"));
    }
    {
        var re = try Regex.compile(gpa, "(?iu)\\AΣ\\z", .{});
        defer re.deinit();
        try expect(re.match("Σ"));
        try expect(re.match("σ"));
        try expect(re.match("ς"));
    }
    {
        var re = try Regex.compile(gpa, "(?iu)\\A꟎\\z", .{});
        defer re.deinit();
        try expect(re.match("꟎"));
        try expect(re.match("꟏"));
    }
    {
        var re = try Regex.compile(gpa, "(?iu)\\A[^k]\\z", .{});
        defer re.deinit();
        try expect(!re.match("k"));
        try expect(!re.match("K"));
        try expect(!re.match("K"));
        try expect(re.match("x"));
    }
}

test "basic empty matches" {
    {
        var re = try Regex.compile(gpa, "|a", .{});
        defer re.deinit();
        const found = re.find("abc");
        try expect(found != null);
        try expectEqual(Match{ .start = 0, .end = 0 }, found.?);
    }
    {
        var re = try Regex.compile(gpa, "a|", .{});
        defer re.deinit();
        const found = re.find("abc");
        try expect(found != null);
        try expectEqual(Match{ .start = 0, .end = 1 }, found.?);
    }
    {
        var re = try Regex.compile(gpa, "b|", .{});
        defer re.deinit();
        const found = re.find("abc");
        try expect(found != null);
        try expectEqual(Match{ .start = 0, .end = 0 }, found.?);
    }
}

test "character class with perl items" {
    {
        var re = try Regex.compile(gpa, "[\\D]", .{});
        defer re.deinit();
        try expect(re.match("a"));
        try expect(!re.match("5"));
    }
    {
        var re = try Regex.compile(gpa, "[^\\D]", .{});
        defer re.deinit();
        try expect(re.match("5"));
        try expect(!re.match("a"));
    }
    {
        var re = try Regex.compile(gpa, "[\\d\\D]", .{});
        defer re.deinit();
        try expect(re.match("5"));
        try expect(re.match("a"));
    }
    {
        var re = try Regex.compile(gpa, "[^\\d\\D]", .{});
        defer re.deinit();
        try expect(!re.match("5"));
        try expect(!re.match("a"));
    }
}

test "diag parse err" {
    const pattern = "[z-a]";

    var diag: Diagnostics = undefined;
    try expectError(error.Parse, Regex.compile(gpa, pattern, .{
        .diag = &diag,
    }));

    switch (diag) {
        .parse => |parse_diag| {
            try expectEqual(.class_range_invalid, parse_diag.err);
            try expectEqual(Span{ .start = 3, .end = 4 }, parse_diag.span);
            try expectEqual(Span{ .start = 1, .end = 2 }, parse_diag.aux_span.?);
            try expect(parse_diag.span.isValidFor(pattern.len));
            try expect(parse_diag.aux_span.?.isValidFor(pattern.len));
        },
        .compile => return error.TestUnexpectedResult,
    }
}

test "parse err no diag" {
    try expectError(error.Parse, Regex.compile(gpa, "[z-a]", .{}));
}

test "diag repeat limit" {
    const pattern = "a{4}";

    var diag: Diagnostics = undefined;
    try expectError(error.Parse, Regex.compile(gpa, pattern, .{
        .limits = .{ .max_repeat = 3 },
        .diag = &diag,
    }));

    switch (diag) {
        .parse => |parse_diag| {
            try expectEqual(.repeat_size_invalid, parse_diag.err);
            try expectEqual(Span{ .start = 2, .end = 3 }, parse_diag.span);
            try expectEqual(null, parse_diag.aux_span);
            try expect(parse_diag.span.isValidFor(pattern.len));
        },
        .compile => return error.TestUnexpectedResult,
    }
}

test "max_states limit" {
    const pattern = "ab";
    // The limit is inclusive: exactly 5 states is allowed.
    {
        var re = try Regex.compile(gpa, pattern, .{
            .limits = .{ .max_states = 5 },
        });
        defer re.deinit();
        try expect(re.match(pattern));
    }
    // Over limit with diag reporting
    {
        var diag: Diagnostics = undefined;
        try expectError(error.Compile, Regex.compile(gpa, pattern, .{
            .limits = .{ .max_states = 4 },
            .diag = &diag,
        }));

        switch (diag) {
            .compile => |compile_diag| switch (compile_diag) {
                .too_many_states => |state_limit| {
                    try expectEqual(4, state_limit.limit);
                    try expectEqual(5, state_limit.count);
                },
                else => return error.TestUnexpectedResult,
            },
            .parse => return error.TestUnexpectedResult,
        }
    }
    // Over limit without diag reporting
    {
        try expectError(error.Compile, Regex.compile(gpa, pattern, .{
            .limits = .{ .max_states = 4 },
        }));
    }
    // Limits larger than the compiler's intrinsic state-id range are rejected.
    {
        var diag: Diagnostics = undefined;
        try expectError(error.Compile, Regex.compile(gpa, pattern, .{
            .limits = .{ .max_states = std.math.maxInt(usize) },
            .diag = &diag,
        }));

        switch (diag) {
            .compile => |compile_diag| switch (compile_diag) {
                .invalid_state_limit => |invalid_limit| {
                    try expectEqual(std.math.maxInt(usize), invalid_limit);
                },
                else => return error.TestUnexpectedResult,
            },
            .parse => return error.TestUnexpectedResult,
        }
    }
}

fn expectCompileDiag(pattern: []const u8, expected: Diagnostics.Compile) !void {
    var diag: Diagnostics = undefined;
    try expectError(error.Compile, Regex.compile(gpa, pattern, .{ .diag = &diag }));

    switch (diag) {
        .compile => |compile_diag| try expectEqual(expected, compile_diag),
        .parse => return error.TestUnexpectedResult,
    }
}

fn expectSplit(
    pattern: []const u8,
    haystack: []const u8,
    expected: []const []const u8,
) !void {
    var re = try Regex.compile(gpa, pattern, .{});
    defer re.deinit();

    var iter = re.split(haystack);
    for (expected) |part| {
        const actual = iter.nextBytes() orelse return error.TestUnexpectedResult;
        try expectEqualStrings(part, actual);
    }
    try expectEqual(null, iter.next());
    try expectEqual(null, iter.next());
}

fn expectSplitN(
    pattern: []const u8,
    haystack: []const u8,
    limit: usize,
    expected: []const []const u8,
) !void {
    var re = try Regex.compile(gpa, pattern, .{});
    defer re.deinit();

    var iter: Regex.SplitNIterator = re.splitN(haystack, limit);
    for (expected) |part| {
        const actual = iter.nextBytes() orelse return error.TestUnexpectedResult;
        try expectEqualStrings(part, actual);
    }
    try expectEqual(null, iter.next());
    try expectEqual(null, iter.next());
}

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const expectError = testing.expectError;
const gpa = testing.allocator;

const export_test = @import("export_test");
const Regex = export_test.Regex;
const Match = Regex.Match;
const Diagnostics = export_test.Diagnostics;
const Span = export_test.Span;

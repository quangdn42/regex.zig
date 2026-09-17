const Ast = @import("../Ast.zig");
const ranges = @import("ranges.zig");
const ByteRange = ranges.ByteRange;

pub fn getPerlRanges(kind: Ast.Class.Perl.Kind) []const ByteRange {
    return switch (kind) {
        .digit => classRanges(.{
            .{ '0', '9' },
        }),
        .word => classRanges(.{
            .{ '0', '9' },
            .{ 'A', 'Z' },
            .{ '_', '_' },
            .{ 'a', 'z' },
        }),
        .space => classRanges(.{
            .{ '\t', '\r' },
            .{ ' ', ' ' },
        }),
    };
}

pub fn getPosixRanges(kind: Ast.Class.Ascii.Kind) []const ByteRange {
    return switch (kind) {
        .alnum => classRanges(.{
            .{ '0', '9' },
            .{ 'A', 'Z' },
            .{ 'a', 'z' },
        }),
        .alpha => classRanges(.{
            .{ 'A', 'Z' },
            .{ 'a', 'z' },
        }),
        .ascii => classRanges(.{
            .{ 0x00, 0x7F },
        }),
        .blank => classRanges(.{
            .{ '\t', '\t' },
            .{ ' ', ' ' },
        }),
        .cntrl => classRanges(.{
            .{ 0x00, 0x1F },
            .{ 0x7F, 0x7F },
        }),
        .digit => classRanges(.{
            .{ '0', '9' },
        }),
        .graph => classRanges(.{
            .{ '!', '~' },
        }),
        .lower => classRanges(.{
            .{ 'a', 'z' },
        }),
        .print => classRanges(.{
            .{ ' ', '~' },
        }),
        .punct => classRanges(.{
            .{ '!', '/' },
            .{ ':', '@' },
            .{ '[', '`' },
            .{ '{', '~' },
        }),
        .space => classRanges(.{
            .{ '\t', '\r' },
            .{ ' ', ' ' },
        }),
        .upper => classRanges(.{
            .{ 'A', 'Z' },
        }),
        .word => classRanges(.{
            .{ '0', '9' },
            .{ 'A', 'Z' },
            .{ '_', '_' },
            .{ 'a', 'z' },
        }),
        .xdigit => classRanges(.{
            .{ '0', '9' },
            .{ 'A', 'F' },
            .{ 'a', 'f' },
        }),
    };
}

fn classRanges(comptime tuples: anytype) []const ByteRange {
    const tuples_info = @typeInfo(@TypeOf(tuples));
    comptime {
        if (tuples_info != .@"struct" or !tuples_info.@"struct".is_tuple) {
            @compileError("classRanges expects a tuple of byte range tuples");
        }
    }

    return comptime blk: {
        var result: [tuples_info.@"struct".field_names.len]ByteRange = undefined;
        for (tuples, &result) |pair, *range| {
            const pair_info = @typeInfo(@TypeOf(pair));
            if (pair_info != .@"struct" or !pair_info.@"struct".is_tuple or pair_info.@"struct".field_names.len != 2) {
                @compileError("classRanges entries must be 2-tuples");
            }
            range.* = .init(pair[0], pair[1]);
        }
        const final = result;
        break :blk &final;
    };
}

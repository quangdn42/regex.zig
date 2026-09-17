const std = @import("std");
const testing = std.testing;
const expect = testing.expect;

pub fn isWordByte(c: u8) bool {
    const set: [256]bool = comptime b: {
        var out: [256]bool = @splat(false);
        for ('0'..'9' + 1) |i| out[i] = true;
        for ('A'..'Z' + 1) |i| out[i] = true;
        for ('a'..'z' + 1) |i| out[i] = true;
        out['_'] = true;
        break :b out;
    };
    return set[c];
}

test "word byte" {
    try expect(isWordByte('z'));
    try expect(isWordByte('_'));
    try expect(!isWordByte(' '));
}

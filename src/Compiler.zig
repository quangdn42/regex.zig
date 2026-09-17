//! The Compiler compiles parsed Ast into a Thompson-style NFA: a linked collection of State
//! structures. This follows the algorithm presented in http://swtch.com/~rsc/regexp/

const Compiler = @This();

states: ArrayList(State) = .empty,
transitions: ArrayList(Transition) = .empty,
branches: ArrayList(StateId) = .empty,
arena: std.heap.ArenaAllocator,

byte_cls: ranges_mod.ByteClassBuilder = .empty,
scalar_cls: ranges_mod.ScalarClassBuilder = .empty,
tmp_arena: std.heap.ArenaAllocator,

/// See `Program.matcher_count`.
matcher_count: u32 = 0,

/// Mutable syntax flags during parsing
flags: SyntaxFlags,
/// Hard limit on state count
max_states: usize,
/// Diagnostics
diag: ?*Diagnostics,

const Error = error{Compile} || Allocator.Error;

/// Resources allocated are owned by Program after compilation is done, and caller is expected
/// to call Program.deinit() to free them.
pub fn compile(gpa: Allocator, pattern: []const u8, options: TopLevelOptions) !*Program {
    var parser: Parser = .init(gpa, pattern, .{
        .max_repeat = options.limits.max_repeat,
        .diag = options.diag,
    });
    var ast = try parser.parse();
    defer ast.deinit();
    var compiler: Compiler = .{
        .arena = .init(gpa),
        .tmp_arena = .init(gpa),
        .flags = options.syntax,
        .max_states = try getMaxState(options.limits.max_states, options.diag),
        .diag = options.diag,
    };
    errdefer compiler.arena.deinit();
    defer compiler.tmp_arena.deinit();
    return compiler.compileAst(&ast);
}

/// Compile a parsed AST into a Program. Compilation moves capture metadata out of `ast`
/// into Program.
fn compileAst(c: *Compiler, ast: *Ast) Error!*Program {
    const a = c.arena.allocator();

    // PatchList uses state id 0 as the dangling sentinel, so the start capture for
    // the whole match at id 0 must stay outside normal Frag patching.
    const start_capture = try c.emitState(.{ .capture = .{ .slot = 0, .out = 0 } });
    assert(start_capture == 0);

    var frag = try c.compileNode(ast, ast.root());
    assert(frag.id != 0);
    c.states.items[start_capture].capture.out = frag.id;
    frag = c.cat(frag, try c.cap(1));
    _ = c.cat(frag, try c.state(.match));

    if (builtin.mode == .debug) {
        assert(c.matcher_count == countMatcherStates(c.states.items));
    }

    const prog = try a.create(Program);
    prog.* = .{
        .states = try c.states.toOwnedSlice(a),
        .transitions = try c.transitions.toOwnedSlice(a),
        .branches = try c.branches.toOwnedSlice(a),
        // Important that we move capture_info **after** fallible actions above, so it
        // can be cleaned up by `ast.deinit` in the fail path.
        .capture_info = ast.capture_info.move(),
        .matcher_count = c.matcher_count,
        .arena = c.arena,
    };
    return prog;
}

fn compileNode(c: *Compiler, ast: *const Ast, node_index: Ast.Node.Index) Error!Frag {
    const a = c.arena.allocator();
    const cls_a = c.tmp_arena.allocator();
    const node = ast.nodes[node_index];
    switch (node) {
        .literal => |lit| {
            if (c.flags.unicode) {
                const cp = lit.char();
                if (!c.flags.case_insensitive)
                    return c.compileUtf8Sequence(.fromCodePoint(cp));

                c.scalar_cls.clear();
                try c.scalar_cls.appendRange(cls_a, .init(cp, cp), true);
                return c.compileScalarClass(c.scalar_cls.slice());
            } else {
                const byte = lit.byte() orelse switch (lit) {
                    .verbatim => |cp| return c.compileUtf8Sequence(.fromCodePoint(cp)),
                    .hex => |hex| switch (hex) {
                        .x_brace => return c.err(.unicode_in_byte_mode),
                        .x => unreachable,
                    },
                    .escaped, .c_style => unreachable,
                };
                if (!c.flags.case_insensitive) return c.byteRange(.init(byte, byte));

                c.byte_cls.clear();
                try c.byte_cls.appendRange(cls_a, .init(byte, byte), true);
                return c.compileByteClass(c.byte_cls.slice());
            }
        },
        .dot => {
            if (c.flags.unicode) {
                c.scalar_cls.clear();
                try c.scalar_cls.appendDotClass(cls_a, c.flags.dot_matches_new_line);
                return c.compileScalarClass(c.scalar_cls.slice());
            } else {
                c.byte_cls.clear();
                try c.byte_cls.appendDotClass(cls_a, c.flags.dot_matches_new_line);
                return c.compileByteClass(c.byte_cls.slice());
            }
        },
        .class_perl => |cls| {
            if (c.flags.unicode) {
                c.scalar_cls.clear();
                try c.scalar_cls.appendPerlClass(cls_a, cls, c.flags.case_insensitive);
                return c.compileScalarClass(c.scalar_cls.slice());
            } else {
                c.byte_cls.clear();
                try c.byte_cls.appendPerlClass(cls_a, cls, c.flags.case_insensitive);
                return c.compileByteClass(c.byte_cls.slice());
            }
        },
        .class => |cls| {
            if (c.flags.unicode) {
                c.scalar_cls.clear();
                for (ast.classItems(cls)) |item| {
                    try c.appendScalarClassItem(cls_a, item);
                }
                if (cls.negated) try c.scalar_cls.negate(cls_a);
                return c.compileScalarClass(c.scalar_cls.slice());
            } else {
                c.byte_cls.clear();
                for (ast.classItems(cls)) |item| {
                    try c.appendByteClassItem(cls_a, item);
                }
                if (cls.negated) try c.byte_cls.negate(cls_a);
                return c.compileByteClass(c.byte_cls.slice());
            }
        },
        .group => |gr| {
            const capture_index = switch (gr.kind) {
                .numbered => |index| index,
                .named => |named_capture| named_capture.index,
                .non_capturing => |flags| {
                    const before: SyntaxFlags = c.flags;
                    defer c.flags = before;
                    c.applySyntaxFlags(flags);
                    return c.compileNode(ast, gr.node);
                },
            };
            const before: SyntaxFlags = c.flags;
            defer c.flags = before;
            const slot_2k = @as(u32, capture_index) * 2;
            const frag = c.cat(try c.cap(slot_2k), try c.compileNode(ast, gr.node));
            return c.cat(frag, try c.cap(slot_2k + 1));
        },
        .set_flags => |flags| {
            c.applySyntaxFlags(flags);
            return c.empty();
        },
        .concat => |c_node| {
            if (c_node.len == 0) {
                // Occurs in empty alternation branch
                return c.empty();
            }
            const concat = ast.indexSlice(c_node.start, c_node.len);
            var frag = try c.compileNode(ast, concat[0]);
            for (concat[1..]) |index| {
                frag = c.cat(frag, try c.compileNode(ast, index));
            }
            return frag;
        },
        .alternation => |a_node| {
            const alt = ast.indexSlice(a_node.start, a_node.len);
            switch (alt.len) {
                0 => return c.empty(),
                1 => return c.compileNode(ast, alt[0]),
                2 => return c.alt2(
                    try c.compileNode(ast, alt[0]),
                    try c.compileNode(ast, alt[1]),
                ),
                else => {
                    const start = c.branches.items.len;
                    try c.branches.ensureTotalCapacity(a, start + alt.len);

                    var frag = try c.state(.{
                        .alt = .{ .start = @intCast(start), .len = @intCast(alt.len) },
                    });
                    for (alt) |index| {
                        const branch = try c.compileNode(ast, index);
                        c.branches.appendAssumeCapacity(branch.id);
                        frag.outs = frag.outs.append(c, branch.outs);
                        frag.nullable = frag.nullable or branch.nullable;
                    }
                    return frag;
                },
            }
        },
        .repetition => |rep| {
            const Kind = Ast.Repetition.Kind;
            const lazy = rep.lazy_suffix != c.flags.swap_greed;
            rep_kind: switch (rep.kind) {
                .zero_or_one => {
                    return c.quest(try c.compileNode(ast, rep.node), lazy);
                },
                .zero_or_more => {
                    return c.star(try c.compileNode(ast, rep.node), lazy);
                },
                .one_or_more => {
                    return c.plus(try c.compileNode(ast, rep.node), lazy);
                },
                .exactly => |min| {
                    return c.compileNTimes(ast, rep.node, min);
                },
                .at_least => |min| {
                    switch (min) {
                        0 => continue :rep_kind Kind.zero_or_more,
                        1 => continue :rep_kind Kind.one_or_more,
                        else => return c.cat(
                            try c.compileNTimes(ast, rep.node, min - 1),
                            try c.plus(try c.compileNode(ast, rep.node), lazy),
                        ),
                    }
                },
                .between => |b| {
                    assert(b.min <= b.max); // Handled in parse phase
                    if (b.max == 0) return c.empty();
                    if (b.max == 1 and b.min == 0) continue :rep_kind Kind.zero_or_one;
                    if (b.max == b.min) continue :rep_kind .{ .exactly = b.min };

                    // Lower x{n,m} as a required prefix plus a nested optional
                    // suffix, e.g. x{2,5} => xx(x(x(x)?)?)?. A flat chain like
                    // xx x? x? x? would admit many equivalent epsilon paths for
                    // the same repetition count. The nested form preserves the
                    // same language while doing less VM work.
                    //
                    // Reference:
                    // https://github.com/golang/go/blob/master/src/regexp/syntax/simplify.go
                    var suffix = try c.quest(try c.compileNode(ast, rep.node), lazy);
                    for (b.min..b.max - 1) |_| {
                        suffix = try c.quest(
                            c.cat(try c.compileNode(ast, rep.node), suffix),
                            lazy,
                        );
                    }
                    if (b.min == 0) return suffix;
                    return c.cat(try c.compileNTimes(ast, rep.node, b.min), suffix);
                },
            }
        },
        .assertion => |asrt| {
            return c.state(.{ .assert = .{
                .pred = switch (asrt) {
                    .start_line_or_text => if (c.flags.multi_line) .start_line else .start_text,
                    .end_line_or_text => if (c.flags.multi_line) .end_line else .end_text,
                    .start_text => .start_text,
                    .end_text => .end_text,
                    .word_boundary => .word_boundary,
                    .not_word_boundary => .not_word_boundary,
                },
                .out = 0,
            } });
        },
    }
}

fn err(c: *Compiler, compile_diag: Diagnostics.Compile) error{Compile} {
    if (c.diag) |diagnostics| {
        diagnostics.* = .{ .compile = compile_diag };
    }
    return error.Compile;
}

fn checkStateLimit(c: *Compiler) error{Compile}!void {
    const limit = c.max_states;
    if (c.states.items.len < limit) return;
    return c.err(.{ .too_many_states = .{
        .limit = limit,
        .count = c.states.items.len + 1,
    } });
}

fn getMaxState(configured: ?usize, diag: ?*Diagnostics) error{Compile}!usize {
    const max = PatchList.Ptr.max;
    const limit = configured orelse return max;
    if (limit <= max) return limit;
    if (diag) |d| {
        d.* = .{ .compile = .{ .invalid_state_limit = limit } };
    }
    return error.Compile;
}

fn emitState(c: *Compiler, s: State) !StateId {
    try c.checkStateLimit();
    const id: StateId = @intCast(c.states.items.len);
    try c.states.append(c.arena.allocator(), s);
    switch (s) {
        .byte_range, .sparse, .fail, .match => c.matcher_count += 1,
        .empty, .capture, .assert, .alt, .alt2 => {},
    }
    return id;
}

fn state(c: *Compiler, s: State) !Frag {
    const id = try c.emitState(s);
    return .{
        .id = id,
        .outs = switch (s) {
            .byte_range, .empty, .capture, .assert => .fromStateOut(id),
            .sparse, .fail, .match, .alt, .alt2 => .empty,
        },
        // .alt and .alt2 are typically emitted before their branch fragments are
        // known, so callers overwrite their nullable value once children are
        // attached.
        .nullable = switch (s) {
            .byte_range, .sparse, .alt, .alt2, .fail => false,
            .empty, .capture, .assert, .match => true,
        },
    };
}

fn cap(c: *Compiler, slot: u32) !Frag {
    return c.state(.{ .capture = .{ .slot = slot, .out = 0 } });
}

fn cat(c: *Compiler, lhs: Frag, rhs: Frag) Frag {
    if (lhs.id == 0 or rhs.id == 0) return .zero;
    lhs.outs.patch(c, rhs.id);
    return .{
        .id = lhs.id,
        .outs = rhs.outs,
        .nullable = lhs.nullable and rhs.nullable,
    };
}

fn alt2(c: *Compiler, lhs: Frag, rhs: Frag) !Frag {
    if (lhs.id == 0) return rhs;
    if (rhs.id == 0) return lhs;

    var frag = try c.state(.{ .alt2 = .{ .left = lhs.id, .right = rhs.id } });
    frag.outs = lhs.outs.append(c, rhs.outs);
    frag.nullable = lhs.nullable or rhs.nullable;
    return frag;
}

fn quest(c: *Compiler, f1: Frag, lazy: bool) !Frag {
    var frag = try c.state(.{ .alt2 = .{ .left = 0, .right = 0 } });
    const alt = &c.states.items[frag.id].alt2;
    if (lazy) {
        alt.right = f1.id;
        frag.outs = .fromAlt2Left(frag.id);
    } else {
        alt.left = f1.id;
        frag.outs = .fromAlt2Right(frag.id);
    }
    frag.outs = frag.outs.append(c, f1.outs);
    frag.nullable = true;
    return frag;
}

/// Returns the fragment for the main loop of a plus or star. When `lazy` =
/// false, creates the following shape:
/// ```
/// f1  -> alt2: left  -> f1
///              right -> next (dangling)
/// ```
/// When `lazy` = true, `left` and `right` are reversed.
fn loop(c: *Compiler, f1: Frag, lazy: bool) !Frag {
    var frag = try c.state(.{ .alt2 = .{ .left = 0, .right = 0 } });
    const alt = &c.states.items[frag.id].alt2;
    if (lazy) {
        alt.right = f1.id;
        frag.outs = .fromAlt2Left(frag.id);
    } else {
        alt.left = f1.id;
        frag.outs = .fromAlt2Right(frag.id);
    }
    f1.outs.patch(c, frag.id);
    frag.nullable = true;
    return frag;
}

fn plus(c: *Compiler, f1: Frag, lazy: bool) !Frag {
    const loop_frag = try c.loop(f1, lazy);
    return .{
        .id = f1.id,
        .outs = loop_frag.outs,
        .nullable = f1.nullable,
    };
}

fn star(c: *Compiler, f1: Frag, lazy: bool) !Frag {
    if (f1.nullable) {
        // Use (f1+)? to get priority match order correct.
        // https://github.com/golang/go/issues/46123
        return c.quest(try c.plus(f1, lazy), lazy);
    }
    return c.loop(f1, lazy);
}

fn compileNTimes(c: *Compiler, ast: *const Ast, node_index: Ast.Node.Index, count: u16) !Frag {
    if (count == 0) return c.empty();

    var frag = try c.compileNode(ast, node_index);
    for (1..count) |_| {
        frag = c.cat(frag, try c.compileNode(ast, node_index));
    }
    return frag;
}

fn empty(c: *Compiler) !Frag {
    return c.state(.{ .empty = .{ .out = 0 } });
}

fn appendByteClassItem(c: *Compiler, gpa: Allocator, item: Ast.Class.Item) !void {
    const fold = c.flags.case_insensitive;
    switch (item) {
        .literal => |lit| {
            const byte = lit.byte() orelse return c.err(.unicode_in_byte_mode);
            try c.byte_cls.appendRange(gpa, .init(byte, byte), fold);
        },
        .range => |r| {
            const from = r.from.byte() orelse return c.err(.unicode_in_byte_mode);
            const to = r.to.byte() orelse return c.err(.unicode_in_byte_mode);
            try c.byte_cls.appendRange(gpa, .init(from, to), fold);
        },
        .perl => |cls| try c.byte_cls.appendPerlClass(gpa, cls, fold),
        .ascii => |cls| try c.byte_cls.appendPosixClass(gpa, cls, fold),
    }
}

fn appendScalarClassItem(c: *Compiler, gpa: Allocator, item: Ast.Class.Item) !void {
    const fold = c.flags.case_insensitive;
    switch (item) {
        .literal => |lit| try c.scalar_cls.appendRange(gpa, .init(lit.char(), lit.char()), fold),
        .range => |r| try c.scalar_cls.appendRange(gpa, .init(r.from.char(), r.to.char()), fold),
        .perl => |cls| try c.scalar_cls.appendPerlClass(gpa, cls, fold),
        .ascii => |cls| try c.scalar_cls.appendPosixClass(gpa, cls, fold),
    }
}

fn compileByteClass(c: *Compiler, ranges: []const ByteRange) !Frag {
    switch (ranges.len) {
        0 => return c.state(.fail),
        1 => return c.byteRange(ranges[0]),
        else => {
            const start = c.transitions.items.len;
            for (ranges) |range| {
                try c.transitions.append(c.arena.allocator(), .{
                    .from = range.from,
                    .to = range.to,
                    .out = 0,
                });
            }
            var frag = try c.state(.{ .sparse = .{
                .start = @intCast(start),
                .len = @intCast(ranges.len),
            } });
            frag.outs = .fromTransitionOuts(c, start, ranges.len);
            return frag;
        },
    }
}

fn compileScalarClass(c: *Compiler, ranges: []const ScalarRange) !Frag {
    // TODO: Use a range trie to share UTF-8 byte-range structure and avoid
    // large unshared alternations for Unicode classes. Reference:
    // https://github.com/rust-lang/regex/blob/master/regex-automata/src/nfa/thompson/range_trie.rs
    const branch_start = c.branches.items.len;
    var outs: PatchList = .empty;

    for (ranges) |range| {
        var seqs = utf8.Sequences.init(range);
        while (seqs.next()) |seq| {
            const branch = try c.compileUtf8Sequence(seq);
            try c.branches.append(c.arena.allocator(), branch.id);
            outs = outs.append(c, branch.outs);
        }
    }

    const branch_count = c.branches.items.len - branch_start;
    switch (branch_count) {
        0 => return c.state(.fail),
        1 => {
            const frag: Frag = .{
                .id = c.branches.items[branch_start],
                .outs = outs,
                .nullable = false,
            };
            c.branches.shrinkRetainingCapacity(branch_start);
            return frag;
        },
        2 => {
            var frag = try c.state(.{ .alt2 = .{
                .left = c.branches.items[branch_start],
                .right = c.branches.items[branch_start + 1],
            } });
            c.branches.shrinkRetainingCapacity(branch_start);
            frag.outs = outs;
            return frag;
        },
        else => {
            var frag = try c.state(.{ .alt = .{
                .start = @intCast(branch_start),
                .len = @intCast(branch_count),
            } });
            frag.outs = outs;
            return frag;
        },
    }
}

fn compileUtf8Sequence(c: *Compiler, seq: utf8.Sequence) !Frag {
    const ranges = seq.slice();
    var frag = try c.byteRange(ranges[0]);
    for (ranges[1..]) |range| {
        frag = c.cat(frag, try c.byteRange(range));
    }
    return frag;
}

fn byteRange(c: *Compiler, range: ByteRange) !Frag {
    return c.state(.{ .byte_range = .{
        .from = range.from,
        .to = range.to,
        .out = 0,
    } });
}

/// Apply parsed `Ast.Flags` to `SyntaxOptions`. `Ast.Flags` value is assumed to be
/// structurally correct: each flag and `-` only appears once.
fn applySyntaxFlags(c: *Compiler, flags: Ast.Flags) void {
    const opts = &c.flags;
    var flag_value = true;
    for (flags.slice()) |item| {
        switch (item) {
            .case_insensitive => opts.case_insensitive = flag_value,
            .multi_line => opts.multi_line = flag_value,
            .dot_matches_new_line => opts.dot_matches_new_line = flag_value,
            .swap_greed => opts.swap_greed = flag_value,
            .unicode => opts.unicode = flag_value,
            .disable_op => flag_value = false,
        }
    }
}

fn countMatcherStates(states: []const State) u32 {
    var count: u32 = 0;
    for (states) |s| {
        switch (s) {
            .byte_range, .sparse, .fail, .match => count += 1,
            .empty, .capture, .assert, .alt, .alt2 => {},
        }
    }
    return count;
}

/// A compiled fragment returned by compileNode.
/// - id: the id of the entry state of the fragment
/// - outs: dangling out-edges that must be patched to the next fragment
///
/// In the state list for execution, id 0 is reserved for .capture slot 0 state,
/// so `Frag.zero` can be used as an internal sentinel and never refers to a
/// real patchable fragment.
const Frag = struct {
    id: StateId,
    outs: PatchList,
    nullable: bool,

    const zero: Frag = .{ .id = 0, .outs = .empty, .nullable = false };
};

/// In the state list for execution, id 0 is reserved for .capture slot 0 state,
/// so it's safe to repurpose it during building as dangling (i.e. to be patched).
/// For `PatchList`, this means that `Ptr` with StateId = 0 indicates dangling.
///
/// PatchList stores pending patch targets as encoded values in the fields they
/// patch. Targets can be state fields or sparse transition `out` fields. Encoded
/// pointer 0 is the dangling/end sentinel; transition payload 0 remains valid
/// because target bits distinguish it from `Ptr.zero`.
///
/// Reference: https://github.com/golang/go/blob/master/src/regexp/syntax/compile.go
const PatchList = struct {
    head: Ptr,
    tail: Ptr,

    const empty: PatchList = .{ .head = .zero, .tail = .zero };

    fn fromStateOut(id: StateId) PatchList {
        return fromPtr(.init(id, .state_out));
    }

    fn fromAlt2Left(id: StateId) PatchList {
        return fromPtr(.init(id, .alt2_left));
    }

    fn fromAlt2Right(id: StateId) PatchList {
        return fromPtr(.init(id, .alt2_right));
    }

    fn fromTransitionOuts(c: *Compiler, start: usize, len: usize) PatchList {
        if (len == 0) return .empty;

        const head: Ptr = .init(start, .transition_out);
        var tail = head;
        for (start + 1..start + len) |i| {
            const next: Ptr = .init(i, .transition_out);
            tail.set(c, next.toId());
            tail = next;
        }
        return .{ .head = head, .tail = tail };
    }

    fn fromPtr(ptr: Ptr) PatchList {
        return .{ .head = ptr, .tail = ptr };
    }

    /// Walks the encoded Ptr linked list and patches each target to `value`.
    /// Encoded pointer 0 marks the end of the list.
    fn patch(l1: PatchList, c: *Compiler, value: StateId) void {
        assert(value != 0);
        var head = l1.head;
        while (!head.isZero()) {
            const next = head.get(c);
            head.set(c, value);
            head = next;
        }
    }

    fn append(l1: PatchList, c: *Compiler, l2: PatchList) PatchList {
        if (l1.head.isZero()) return l2;
        if (l2.head.isZero()) return l1;
        l1.tail.set(c, l2.head.toId());
        return .{ .head = l1.head, .tail = l2.tail };
    }

    const Ptr = packed struct {
        payload: u30,
        target: Target,

        const zero: Ptr = .{ .payload = 0, .target = .state_out };
        const max = std.math.maxInt(u30);

        // Implementation note: Ptr currently has two target bits, so keeping
        // both `alt2_left` and `alt2_right` costs nothing. If another target
        // kind is needed later, `alt2_left` can be merged into `state_out`,
        // with `.alt2` treating its default state-out field as `.left`.
        const Target = enum(u2) {
            /// Patch a normal state's `out` field.
            state_out = 0,
            /// Patch an `alt2` state's `left` field.
            alt2_left = 1,
            /// Patch an `alt2` state's `right` field.
            alt2_right = 2,
            /// Patch a `Transition.out` field in Compiler.transitions.
            transition_out = 3,
        };

        fn init(payload: usize, target: Target) Ptr {
            assert(payload <= max);
            assert(if (target != .transition_out) payload != 0 else true);
            return .{ .payload = @intCast(payload), .target = target };
        }

        fn toId(self: Ptr) StateId {
            return (@as(StateId, self.payload) << 2) | @intFromEnum(self.target);
        }

        fn fromId(id: StateId) Ptr {
            return .{ .payload = @truncate(id >> 2), .target = @enumFromInt(id & 0b11) };
        }

        fn isZero(self: Ptr) bool {
            return self.toId() == 0;
        }

        /// Sets the field encoded by Ptr to `value`.
        fn set(self: Ptr, c: *Compiler, value: StateId) void {
            switch (self.target) {
                .state_out => switch (c.states.items[self.payload]) {
                    .fail, .match, .alt, .alt2, .sparse => unreachable,
                    inline else => |*pl| pl.out = value,
                },
                .alt2_left => switch (c.states.items[self.payload]) {
                    .alt2 => |*pl| pl.left = value,
                    else => unreachable,
                },
                .alt2_right => switch (c.states.items[self.payload]) {
                    .alt2 => |*pl| pl.right = value,
                    else => unreachable,
                },
                .transition_out => {
                    c.transitions.items[self.payload].out = value;
                },
            }
        }

        /// Finds the value at the field encoded by Ptr. This value is assumed to be
        /// encoded and is turned into a new Ptr and returned.
        fn get(self: Ptr, c: *Compiler) Ptr {
            return .fromId(
                switch (self.target) {
                    .state_out => switch (c.states.items[self.payload]) {
                        .fail, .match, .alt, .alt2, .sparse => unreachable,
                        inline else => |pl| pl.out,
                    },
                    .alt2_left => switch (c.states.items[self.payload]) {
                        .alt2 => |pl| pl.left,
                        else => unreachable,
                    },
                    .alt2_right => switch (c.states.items[self.payload]) {
                        .alt2 => |pl| pl.right,
                        else => unreachable,
                    },
                    .transition_out => c.transitions.items[self.payload].out,
                },
            );
        }
    };
};

fn expectProgram(pattern: []const u8, expected: []const Vertex) !void {
    return expectProgramWithOptions(pattern, expected, .{});
}

fn expectProgramWithOptions(
    pattern: []const u8,
    expected: []const Vertex,
    opts: TopLevelOptions,
) !void {
    const a = testing.allocator;
    const prog = try Compiler.compile(a, pattern, opts);
    defer prog.deinit();
    const graph = try g.graphView(prog, a);
    defer graph.deinit(a);
    const actual = graph.vertices;

    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual, 0..) |want, got, i| {
        if (want.eql(got)) continue;
        const want_dump = try g.dumpGraphAlloc(a, expected);
        defer a.free(want_dump);
        const got_dump = try g.dumpGraphAlloc(a, actual);
        defer a.free(got_dump);
        std.debug.print(
            \\graph mismatch for `{s}` at s{d}
            \\want: {any}
            \\got:  {any}
            \\
            \\want graph:
            \\{s}
            \\
            \\got graph:
            \\{s}
            \\
        ,
            .{ pattern, i, want, got, want_dump, got_dump },
        );
        return error.TestExpectedEqual;
    }
}

test "basic compile" {
    try expectProgram("a((b|c)|\\d|)(x|y)z", &.{
        g.capt(0, 1),
        g.range('a', 'a', 2),
        g.capt(2, 3),
        g.alt(&.{ 4, 5, 6 }),
        g.capt(4, 7),
        g.range('0', '9', 11),
        g.empty(11),
        g.alt2(8, 9),
        g.range('b', 'b', 10),
        g.range('c', 'c', 10),
        g.capt(5, 11),
        g.capt(3, 12),
        g.capt(6, 13),
        g.alt2(14, 15),
        g.range('x', 'x', 16),
        g.range('y', 'y', 16),
        g.capt(7, 17),
        g.range('z', 'z', 18),
        g.capt(1, 19),
        g.match(),
    });
}

test "non-capturing group" {
    // does not emit capture states
    try expectProgram("(?:a)(b)", &.{
        g.capt(0, 1),
        g.range('a', 'a', 2),
        g.capt(2, 3),
        g.range('b', 'b', 4),
        g.capt(3, 5),
        g.capt(1, 6),
        g.match(),
    });
}

test "named capturing group" {
    try expectProgram("(?<first>a)(?P<last>b)", &.{
        g.capt(0, 1),
        g.capt(2, 2),
        g.range('a', 'a', 3),
        g.capt(3, 4),
        g.capt(4, 5),
        g.range('b', 'b', 6),
        g.capt(5, 7),
        g.capt(1, 8),
        g.match(),
    });
}

test "greedy repetition" {
    try expectProgram("a?", &.{
        g.capt(0, 1),
        g.alt2(2, 3),
        g.range('a', 'a', 3),
        g.capt(1, 4),
        g.match(),
    });
    try expectProgram("a*", &.{
        g.capt(0, 1),
        g.alt2(2, 3),
        g.range('a', 'a', 1),
        g.capt(1, 4),
        g.match(),
    });
    try expectProgram("a+", &.{
        g.capt(0, 1),
        g.range('a', 'a', 2),
        g.alt2(1, 3),
        g.capt(1, 4),
        g.match(),
    });
}

test "lazy repetition" {
    try expectProgram("a??", &.{
        g.capt(0, 1),
        g.alt2(2, 3),
        g.capt(1, 4),
        g.range('a', 'a', 2),
        g.match(),
    });
    try expectProgram("a*?", &.{
        g.capt(0, 1),
        g.alt2(2, 3),
        g.capt(1, 4),
        g.range('a', 'a', 1),
        g.match(),
    });
    try expectProgram("a+?", &.{
        g.capt(0, 1),
        g.range('a', 'a', 2),
        g.alt2(3, 1),
        g.capt(1, 4),
        g.match(),
    });
}

test "swap greed option" {
    try expectProgramWithOptions("a*", &.{
        g.capt(0, 1),
        g.alt2(2, 3),
        g.capt(1, 4),
        g.range('a', 'a', 1),
        g.match(),
    }, .{ .syntax = .{ .swap_greed = true } });

    try expectProgramWithOptions("a*?", &.{
        g.capt(0, 1),
        g.alt2(2, 3),
        g.range('a', 'a', 1),
        g.capt(1, 4),
        g.match(),
    }, .{ .syntax = .{ .swap_greed = true } });
}

test "dot compile" {
    try expectProgram(".", &.{
        g.capt(0, 1),
        g.sparse(&.{ g.t(0x00, '\n' - 1, 2), g.t('\n' + 1, 0xff, 2) }),
        g.capt(1, 3),
        g.match(),
    });
    try expectProgramWithOptions(".", &.{
        g.capt(0, 1),
        g.range(0x00, 0xff, 2),
        g.capt(1, 3),
        g.match(),
    }, .{ .syntax = .{ .dot_matches_new_line = true } });
}

test "unicode scalar class compile" {
    try expectProgramWithOptions("[\\x{0}\\x{80}\\x{800}]", &.{
        g.capt(0, 1),
        g.alt(&.{ 2, 3, 4 }),
        g.range(0x00, 0x00, 5),
        g.range(0xC2, 0xC2, 7),
        g.range(0xE0, 0xE0, 8),
        g.capt(1, 6),
        g.match(),
        g.range(0x80, 0x80, 5),
        g.range(0xA0, 0xA0, 9),
        g.range(0x80, 0x80, 5),
    }, .{ .syntax = .{ .unicode = true } });
}

test "case insensitive compile" {
    try expectProgramWithOptions("a", &.{
        g.capt(0, 1),
        g.sparse(&.{ g.t('A', 'A', 2), g.t('a', 'a', 2) }),
        g.capt(1, 3),
        g.match(),
    }, .{ .syntax = .{ .case_insensitive = true } });

    try expectProgramWithOptions("1", &.{
        g.capt(0, 1),
        g.range('1', '1', 2),
        g.capt(1, 3),
        g.match(),
    }, .{ .syntax = .{ .case_insensitive = true } });

    try expectProgramWithOptions("[A-Z]", &.{
        g.capt(0, 1),
        g.sparse(&.{ g.t('A', 'Z', 2), g.t('a', 'z', 2) }),
        g.capt(1, 3),
        g.match(),
    }, .{ .syntax = .{ .case_insensitive = true } });

    try expectProgramWithOptions("\\A[[:^lower:]]+\\z", &.{
        g.capt(0, 1),
        g.asrt(.start_text, 2),
        g.sparse(&.{ g.t(0x00, '@', 3), g.t('[', '`', 3), g.t('{', 0xFF, 3) }),
        g.alt2(2, 4),
        g.asrt(.end_text, 5),
        g.capt(1, 6),
        g.match(),
    }, .{ .syntax = .{ .case_insensitive = true } });
}

test "counted repetition" {
    try expectProgram("a{3}", &.{
        g.capt(0, 1),
        g.range('a', 'a', 2),
        g.range('a', 'a', 3),
        g.range('a', 'a', 4),
        g.capt(1, 5),
        g.match(),
    });
    try expectProgram("a{2,}", &.{
        g.capt(0, 1),
        g.range('a', 'a', 2),
        g.range('a', 'a', 3),
        g.alt2(2, 4),
        g.capt(1, 5),
        g.match(),
    });
    try expectProgram("a{2,}?", &.{
        g.capt(0, 1),
        g.range('a', 'a', 2),
        g.range('a', 'a', 3),
        g.alt2(4, 2),
        g.capt(1, 5),
        g.match(),
    });
    try expectProgram("a{2,4}", &.{
        g.capt(0, 1),
        g.range('a', 'a', 2),
        g.range('a', 'a', 3),
        g.alt2(4, 5),
        g.range('a', 'a', 6),
        g.capt(1, 8),
        g.alt2(7, 5),
        g.range('a', 'a', 5),
        g.match(),
    });
    try expectProgram("a{2,4}?", &.{
        g.capt(0, 1),
        g.range('a', 'a', 2),
        g.range('a', 'a', 3),
        g.alt2(4, 5),
        g.capt(1, 6),
        g.range('a', 'a', 7),
        g.match(),
        g.alt2(4, 8),
        g.range('a', 'a', 4),
    });
}

test "ascii class compile" {
    try expectProgram("[^[:digit:]]", &.{
        g.capt(0, 1),
        g.sparse(&.{ g.t(0x00, '/', 2), g.t(':', 0xFF, 2) }),
        g.capt(1, 3),
        g.match(),
    });
    try expectProgram("[[:digit:][:^digit:]]", &.{
        g.capt(0, 1),
        g.range(0x00, 0xFF, 2),
        g.capt(1, 3),
        g.match(),
    });
    try expectProgram("[^[:digit:][:^digit:]]", &.{
        g.capt(0, 1),
        g.fail(),
    });
}

test "assertions" {
    try expectProgram("^re$", &.{
        g.capt(0, 1),
        g.asrt(.start_text, 2),
        g.range('r', 'r', 3),
        g.range('e', 'e', 4),
        g.asrt(.end_text, 5),
        g.capt(1, 6),
        g.match(),
    });
    try expectProgram("\\Are\\z", &.{
        g.capt(0, 1),
        g.asrt(.start_text, 2),
        g.range('r', 'r', 3),
        g.range('e', 'e', 4),
        g.asrt(.end_text, 5),
        g.capt(1, 6),
        g.match(),
    });
    try expectProgram("\\b\\B", &.{
        g.capt(0, 1),
        g.asrt(.word_boundary, 2),
        g.asrt(.not_word_boundary, 3),
        g.capt(1, 4),
        g.match(),
    });
    try expectProgramWithOptions("^re$", &.{
        g.capt(0, 1),
        g.asrt(.start_line, 2),
        g.range('r', 'r', 3),
        g.range('e', 'e', 4),
        g.asrt(.end_line, 5),
        g.capt(1, 6),
        g.match(),
    }, .{ .syntax = .{ .multi_line = true } });
}

test "literal prefix" {
    const test_cases = &[_]struct {
        pattern: []const u8,
        expected: ?u8,
    }{
        .{ .pattern = "abc", .expected = 'a' },
        .{ .pattern = "(a)", .expected = 'a' },
        .{ .pattern = "(?:)abc", .expected = 'a' },
        .{ .pattern = "a|b", .expected = null },
        .{ .pattern = "^a", .expected = null },
        .{ .pattern = ".", .expected = null },
        .{ .pattern = "[ab]", .expected = null },
    };

    for (test_cases) |tc| {
        const prog = try Compiler.compile(testing.allocator, tc.pattern, .{});
        defer prog.deinit();
        try testing.expectEqual(tc.expected, prog.literalPrefix());
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;
const testing = std.testing;
const builtin = @import("builtin");

pub const Ast = @import("Ast.zig");
const ranges_mod = @import("Compiler/ranges.zig");
const ByteRange = ranges_mod.ByteRange;
const ScalarRange = ranges_mod.ScalarRange;
const utf8 = @import("Compiler/utf8.zig");
const errors = @import("errors.zig");
const Diagnostics = errors.Diagnostics;
const g = @import("program_graph.zig");
const Vertex = g.Vertex;
pub const Parser = @import("Parser.zig");
const Program = @import("Program.zig");
const State = Program.State;
const StateId = Program.StateId;
const Transition = State.Transition;
const TopLevelOptions = @import("types.zig").CompileOptions;
const SyntaxFlags = TopLevelOptions.Syntax;

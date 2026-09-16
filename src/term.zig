const std = @import("std");
const range_mod = @import("range.zig");

/// The set relationship between two terms (viewed as sets of versions).
pub const Relation = enum {
    /// The first set is entirely contained in the second.
    subset,
    /// The sets share no element.
    disjoint,
    /// Anything else, including a proper superset.
    overlapping,
};

/// A statement about a package that is true or false for a given selection of
/// package versions. A `positive` term is true when a selected version lies in
/// its range; a `negative` term is true when no selected version does.
///
/// See https://github.com/dart-lang/pub/tree/main/doc/solver.md#term.
pub fn Term(comptime V: type) type {
    return union(enum) {
        const Self = @This();
        pub const R = range_mod.Range(V);

        positive: R,
        negative: R,

        pub fn range(self: Self) R {
            return switch (self) {
                .positive => |r| r,
                .negative => |r| r,
            };
        }

        pub fn isPositive(self: Self) bool {
            return self == .positive;
        }

        /// A term that can never hold: `positive(∅)`.
        pub fn impossible() Self {
            return .{ .positive = R.empty };
        }

        pub fn isImpossible(self: Self) bool {
            return self == .positive and self.positive.isEmpty();
        }

        /// The term with the opposite sign.
        pub fn inverse(self: Self) Self {
            return switch (self) {
                .positive => |r| .{ .negative = r },
                .negative => |r| .{ .positive = r },
            };
        }

        /// The relationship between the versions allowed by `self` and `other`.
        pub fn relation(self: Self, other: Self) Relation {
            const a = self.range();
            const b = other.range();
            return switch (self) {
                .positive => switch (other) {
                    // foo ^1.0.0 ⊆ foo ^1.x / disjoint with foo ^2.x
                    .positive => if (a.isSubset(b)) .subset else if (a.isDisjoint(b)) .disjoint else .overlapping,
                    // foo ^2.0.0 ⊆ not foo ^1.0.0; disjoint iff a ⊆ b
                    .negative => if (a.isDisjoint(b)) .subset else if (a.isSubset(b)) .disjoint else .overlapping,
                },
                .negative => switch (other) {
                    // `not a` can never be a subset of `b`: the unselected
                    // selection satisfies `not a` but violates `b`. It is
                    // disjoint from `b` when every version in `b` is excluded
                    // (b ⊆ a), otherwise they overlap.
                    .positive => if (b.isSubset(a)) .disjoint else .overlapping,
                    // `not a` ⊆ `not b` iff b ⊆ a. Two negatives can never be
                    // disjoint: the unselected selection satisfies both.
                    .negative => if (b.isSubset(a)) .subset else .overlapping,
                },
            };
        }

        /// `self` being true implies `other` is true.
        pub fn satisfies(self: Self, other: Self) bool {
            return self.relation(other) == .subset;
        }

        /// `self` being true implies `other` is false.
        pub fn contradicts(self: Self, other: Self) bool {
            return self.relation(other) == .disjoint;
        }

        /// The term allowing versions allowed by both `self` and `other`.
        /// The result may be `impossible()` (a positive empty term).
        pub fn intersect(self: Self, other: Self, gpa: std.mem.Allocator) error{OutOfMemory}!Self {
            return switch (self) {
                .positive => |a| switch (other) {
                    .positive => |b| .{ .positive = try a.intersection(b, gpa) },
                    .negative => |b| .{ .positive = try a.difference(b, gpa) },
                },
                .negative => |a| switch (other) {
                    .positive => |b| .{ .positive = try b.difference(a, gpa) },
                    .negative => |b| .{ .negative = try a.unionWith(b, gpa) },
                },
            };
        }

        /// The term allowing versions allowed by `self` and not by `other`,
        /// or `null` when the result is empty.
        pub fn difference(self: Self, other: Self, gpa: std.mem.Allocator) error{OutOfMemory}!?Self {
            const t = try self.intersect(other.inverse(), gpa);
            if (t.isImpossible()) return null;
            return t;
        }
    };
}

// --------------------------------------------------------------------------
// Tests
// --------------------------------------------------------------------------

const NumVer = struct {
    n: u32,
    pub fn cmp(a: NumVer, b: NumVer) std.math.Order {
        return std.math.order(a.n, b.n);
    }
};
const NR = range_mod.Range(NumVer);
const TT = Term(NumVer);
const T = std.testing;

fn nv(n: u32) NumVer {
    return .{ .n = n };
}

fn range(gpa: std.mem.Allocator, lo: u32, hi: u32) !NR {
    return NR.between(gpa, nv(lo), true, nv(hi), false);
}

test "positive/positive relation" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const a: TT = .{ .positive = try range(gpa, 1, 5) };
    const sup: TT = .{ .positive = try range(gpa, 0, 9) };
    const dis: TT = .{ .positive = try range(gpa, 5, 9) };
    const ovl: TT = .{ .positive = try range(gpa, 4, 9) };
    try T.expectEqual(.subset, a.relation(sup));
    try T.expectEqual(.disjoint, a.relation(dis));
    try T.expectEqual(.overlapping, a.relation(ovl));
}

test "positive/negative relation" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    // {1..4} ⊆ not {5..8}: the ranges are disjoint.
    const a: TT = .{ .positive = try range(gpa, 1, 5) };
    const notb: TT = .{ .negative = try range(gpa, 5, 9) };
    try T.expectEqual(.subset, a.relation(notb));
    // {1..4} disjoint from not {1..4}: nothing satisfies both.
    const nota: TT = .{ .negative = try range(gpa, 1, 5) };
    try T.expectEqual(.disjoint, a.relation(nota));
    // {1..9} vs not {3..5}: some versions inside, some outside.
    const big: TT = .{ .positive = try range(gpa, 1, 10) };
    const notsmall: TT = .{ .negative = try range(gpa, 3, 6) };
    try T.expectEqual(.overlapping, big.relation(notsmall));
}

test "negative/positive relation" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    // not {1..4} ⊆ {0..4}?? ¬a ⊆ b iff a ∪ b = all — here not.
    const nota: TT = .{ .negative = try range(gpa, 1, 5) };
    const b: TT = .{ .positive = try range(gpa, 0, 5) };
    try T.expectEqual(.overlapping, nota.relation(b));
    // ¬a disjoint from b when b ⊆ a.
    const small: TT = .{ .positive = try range(gpa, 2, 4) };
    try T.expectEqual(.disjoint, nota.relation(small));
    // ¬a is never a subset of b, even when a ∪ b covers everything: the
    // unselected selection satisfies ¬a but violates b. a = {5..}, b = {..5}.
    const na2: TT = .{ .negative = .{ .intervals = (try NR.between(gpa, nv(5), true, null, false)).intervals } };
    const b2: TT = .{ .positive = .{ .intervals = (try NR.between(gpa, null, true, nv(5), false)).intervals } };
    try T.expectEqual(.overlapping, na2.relation(b2));
}

test "negative/negative relation" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    // not {0..8} ⊆ not {3..5} (the stronger exclusion implies the weaker).
    const notbig: TT = .{ .negative = try range(gpa, 0, 9) };
    const notsmall: TT = .{ .negative = try range(gpa, 3, 6) };
    try T.expectEqual(.subset, notbig.relation(notsmall));
    try T.expectEqual(.overlapping, notsmall.relation(notbig));
    // Two negatives are never disjoint: the unselected selection satisfies
    // both, even when their ranges cover everything.
    const na: TT = .{ .negative = try range(gpa, 0, 5) };
    const nb: TT = .{ .negative = try range(gpa, 5, 9) };
    try T.expectEqual(.overlapping, na.relation(nb));
}

test "intersect" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const a: TT = .{ .positive = try range(gpa, 1, 9) };
    const b: TT = .{ .positive = try range(gpa, 3, 6) };
    const i = try a.intersect(b, gpa);
    try T.expect(i.positive.contains(nv(4)));
    try T.expect(!i.positive.contains(nv(2)));
    // positive ∩ negative = positive difference
    const notb: TT = .{ .negative = try range(gpa, 3, 6) };
    const i_pos = try a.intersect(notb, gpa);
    try T.expect(i_pos.positive.contains(nv(2)));
    try T.expect(!i_pos.positive.contains(nv(4)));
    // negative ∩ negative = negative union of the excluded ranges.
    const na: TT = .{ .negative = try range(gpa, 1, 4) };
    const i_neg = try na.intersect(notb, gpa);
    try T.expect(i_neg == .negative);
    try T.expect(i_neg.negative.contains(nv(2))); // excluded by ¬a
    try T.expect(i_neg.negative.contains(nv(5))); // excluded by ¬b
    try T.expect(!i_neg.negative.contains(nv(9))); // excluded by neither
    // contradictory: pos{1..4} ∩ pos{5..9} = empty positive
    const p1: TT = .{ .positive = try range(gpa, 1, 4) };
    const c: TT = .{ .positive = try range(gpa, 5, 9) };
    const i_empty = try p1.intersect(c, gpa);
    try T.expect(i_empty.isImpossible());
}

test "difference" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const a: TT = .{ .positive = try range(gpa, 1, 9) };
    const b: TT = .{ .positive = try range(gpa, 3, 6) };
    const d = (try a.difference(b, gpa)).?;
    try T.expect(d.positive.contains(nv(2)));
    try T.expect(!d.positive.contains(nv(4)));
    const none = try b.difference(a, gpa);
    try T.expect(none == null);
}

test "inverse" {
    var arena = std.heap.ArenaAllocator.init(T.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const a: TT = .{ .positive = try range(gpa, 1, 5) };
    const ai = a.inverse();
    try T.expect(ai == .negative);
    try T.expect(ai.inverse().positive.contains(nv(3)));
}

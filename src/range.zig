const std = @import("std");

/// A set of versions of type `V`, represented as a canonical sorted list of
/// disjoint, non-adjacent intervals.
///
/// `V` must provide:
///   - `pub fn cmp(a: V, b: V) std.math.Order` — a total order
///   - `pub fn format(v: V, w: *std.Io.Writer) std.Io.Writer.Error!void`
///
/// Interval bounds are `?V`: `null` on the low side means "-infinity", on the
/// high side "+infinity". Each bound carries an inclusive flag, so both
/// `[v, v]` (a single version) and its complement can be expressed.
pub fn Range(comptime V: type) type {
    return struct {
        const Self = @This();

        pub const Bound = struct {
            v: ?V,
            inclusive: bool,
        };

        pub const Interval = struct {
            low: Bound,
            high: Bound,
        };

        /// Sorted, disjoint, non-adjacent, non-empty intervals.
        intervals: []const Interval,

        pub const empty: Self = .{ .intervals = &.{} };
        pub const any: Self = .{ .intervals = &.{.{
            .low = .{ .v = null, .inclusive = true },
            .high = .{ .v = null, .inclusive = true },
        }} };

        /// Allocating constructors and operations take `gpa` and return
        /// `error{OutOfMemory}`.
        pub fn singleton(gpa: std.mem.Allocator, v: V) error{OutOfMemory}!Self {
            const items = try gpa.alloc(Interval, 1);
            items[0] = .{
                .low = .{ .v = v, .inclusive = true },
                .high = .{ .v = v, .inclusive = true },
            };
            return .{ .intervals = items };
        }

        /// The half-open interval `low <= v < high` (either side nullable).
        /// `include_low`/`include_high` override the default `[)` shape.
        pub fn between(
            gpa: std.mem.Allocator,
            low: ?V,
            include_low: bool,
            high: ?V,
            include_high: bool,
        ) error{OutOfMemory}!Self {
            const iv: Interval = .{
                .low = .{ .v = low, .inclusive = include_low },
                .high = .{ .v = high, .inclusive = include_high },
            };
            if (intervalEmpty(iv)) return .empty;
            const items = try gpa.alloc(Interval, 1);
            items[0] = iv;
            return .{ .intervals = items };
        }

        pub fn isEmpty(self: Self) bool {
            return self.intervals.len == 0;
        }

        pub fn isAny(self: Self) bool {
            return self.intervals.len == 1 and
                self.intervals[0].low.v == null and self.intervals[0].high.v == null;
        }

        /// Whether `self` consists of exactly one version.
        pub fn isSingleton(self: Self) bool {
            if (self.intervals.len != 1) return false;
            const iv = self.intervals[0];
            return iv.low.v != null and iv.high.v != null and
                iv.low.inclusive and iv.high.inclusive and
                V.cmp(iv.low.v.?, iv.high.v.?) == .eq;
        }

        pub fn contains(self: Self, v: V) bool {
            for (self.intervals) |iv| {
                if (belowLow(v, iv.low)) continue;
                if (aboveHigh(v, iv.high)) return false; // sorted: later intervals start higher
                return true;
            }
            return false;
        }

        fn belowLow(v: V, low: Bound) bool {
            const lv = low.v orelse return false;
            return switch (V.cmp(v, lv)) {
                .lt => true,
                .eq => !low.inclusive,
                .gt => false,
            };
        }

        fn aboveHigh(v: V, high: Bound) bool {
            const hv = high.v orelse return false;
            return switch (V.cmp(v, hv)) {
                .gt => true,
                .eq => !high.inclusive,
                .lt => false,
            };
        }

        // --- bound ordering -------------------------------------------------

        /// Order on lower bounds: -inf is smallest; at equal versions the
        /// inclusive bound starts earlier.
        fn cmpLow(a: Bound, b: Bound) std.math.Order {
            if (a.v == null and b.v == null) return .eq;
            if (a.v == null) return .lt;
            if (b.v == null) return .gt;
            const c = V.cmp(a.v.?, b.v.?);
            if (c != .eq) return c;
            if (a.inclusive == b.inclusive) return .eq;
            return if (a.inclusive) .lt else .gt;
        }

        /// Order on upper bounds: +inf is largest; at equal versions the
        /// exclusive bound ends earlier.
        fn cmpHigh(a: Bound, b: Bound) std.math.Order {
            if (a.v == null and b.v == null) return .eq;
            if (a.v == null) return .gt;
            if (b.v == null) return .lt;
            const c = V.cmp(a.v.?, b.v.?);
            if (c != .eq) return c;
            if (a.inclusive == b.inclusive) return .eq;
            return if (a.inclusive) .gt else .lt;
        }

        /// Compare an upper bound `hi` to a lower bound `lo` at a potential
        /// boundary. `.lt` means `hi` ends strictly before `lo` starts (a gap);
        /// `.eq` means they touch at a point covered by at least one side;
        /// `.gt` means they overlap.
        fn cmpHighLow(hi: Bound, lo: Bound) std.math.Order {
            // hi = +inf or lo = -inf: no gap is possible.
            if (hi.v == null or lo.v == null) return .gt;
            const c = V.cmp(hi.v.?, lo.v.?);
            if (c != .eq) return c;
            return if (hi.inclusive or lo.inclusive) .eq else .lt;
        }

        fn intervalEmpty(iv: Interval) bool {
            const lo = iv.low;
            const hi = iv.high;
            if (lo.v == null or hi.v == null) return false;
            return switch (V.cmp(lo.v.?, hi.v.?)) {
                .gt => true,
                .lt => false,
                // [v, v] holds a single version; (v, v] and [v, v) are empty.
                .eq => !(lo.inclusive and hi.inclusive),
            };
        }

        fn maxLow(a: Bound, b: Bound) Bound {
            return if (cmpLow(a, b) == .lt) b else a;
        }

        fn minHigh(a: Bound, b: Bound) Bound {
            return if (cmpHigh(a, b) == .lt) a else b;
        }

        fn maxHigh(a: Bound, b: Bound) Bound {
            return if (cmpHigh(a, b) == .lt) b else a;
        }

        // --- set relations (allocation-free) --------------------------------

        /// `self ⊆ other`.
        pub fn isSubset(self: Self, other: Self) bool {
            var j: usize = 0;
            for (self.intervals) |a| {
                // Skip `other` intervals ending strictly before `a` starts.
                while (j < other.intervals.len and
                    cmpHighLow(other.intervals[j].high, a.low) == .lt) j += 1;
                if (j == other.intervals.len) return false;
                if (cmpLow(other.intervals[j].low, a.low) == .gt) return false;
                // `a.low` is covered; extend coverage while intervals chain.
                var cur = other.intervals[j].high;
                while (cmpHigh(cur, a.high) == .lt) {
                    j += 1;
                    if (j == other.intervals.len) return false;
                    if (cmpHighLow(cur, other.intervals[j].low) == .lt) return false;
                    cur = other.intervals[j].high;
                }
            }
            return true;
        }

        /// `self ∩ other = ∅`.
        pub fn isDisjoint(self: Self, other: Self) bool {
            var i: usize = 0;
            var j: usize = 0;
            while (i < self.intervals.len and j < other.intervals.len) {
                const a = self.intervals[i];
                const b = other.intervals[j];
                const cand: Interval = .{
                    .low = maxLow(a.low, b.low),
                    .high = minHigh(a.high, b.high),
                };
                if (!intervalEmpty(cand)) return false;
                switch (cmpHigh(a.high, b.high)) {
                    .lt => i += 1,
                    .gt => j += 1,
                    .eq => {
                        i += 1;
                        j += 1;
                    },
                }
            }
            return true;
        }

        /// `self ∪ other` covers every version.
        pub fn coversAll(self: Self, other: Self) bool {
            var i: usize = 0;
            var j: usize = 0;
            var cur: Bound = .{ .v = null, .inclusive = false };
            var first = true;
            while (i < self.intervals.len or j < other.intervals.len) {
                const pick_a = j == other.intervals.len or
                    (i < self.intervals.len and
                        cmpLow(self.intervals[i].low, other.intervals[j].low) != .gt);
                const iv = if (pick_a) self.intervals[i] else other.intervals[j];
                if (pick_a) i += 1 else j += 1;
                if (first) {
                    if (iv.low.v != null) return false; // gap at -inf
                    cur = iv.high;
                    first = false;
                    if (cur.v == null) return true;
                    continue;
                }
                if (cmpHighLow(cur, iv.low) == .lt) return false; // gap
                cur = maxHigh(cur, iv.high);
                if (cur.v == null) return true;
            }
            return !first and cur.v == null;
        }

        // --- set operations (allocating) ------------------------------------

        pub fn intersection(self: Self, other: Self, gpa: std.mem.Allocator) error{OutOfMemory}!Self {
            var out: std.ArrayList(Interval) = .empty;
            var i: usize = 0;
            var j: usize = 0;
            while (i < self.intervals.len and j < other.intervals.len) {
                const a = self.intervals[i];
                const b = other.intervals[j];
                const cand: Interval = .{
                    .low = maxLow(a.low, b.low),
                    .high = minHigh(a.high, b.high),
                };
                if (!intervalEmpty(cand)) try out.append(gpa, cand);
                switch (cmpHigh(a.high, b.high)) {
                    .lt => i += 1,
                    .gt => j += 1,
                    .eq => {
                        i += 1;
                        j += 1;
                    },
                }
            }
            return .{ .intervals = try out.toOwnedSlice(gpa) };
        }

        pub fn complement(self: Self, gpa: std.mem.Allocator) error{OutOfMemory}!Self {
            var out: std.ArrayList(Interval) = .empty;
            // `cursor` is the low bound of the next gap, as a lower Bound.
            var cursor: Bound = .{ .v = null, .inclusive = true };
            // Whether versions beyond `cursor` remain uncovered. An interval
            // ending at +inf closes the space.
            var open = true;
            for (self.intervals) |iv| {
                if (iv.low.v != null) {
                    // A gap ends where the interval starts; flip the flag when
                    // moving a bound to the other side.
                    const gap: Interval = .{
                        .low = cursor,
                        .high = .{ .v = iv.low.v, .inclusive = !iv.low.inclusive },
                    };
                    if (!intervalEmpty(gap)) try out.append(gpa, gap);
                }
                if (iv.high.v == null) {
                    open = false;
                    break;
                }
                cursor = .{ .v = iv.high.v, .inclusive = !iv.high.inclusive };
            }
            if (open) {
                const tail: Interval = .{
                    .low = cursor,
                    .high = .{ .v = null, .inclusive = true },
                };
                try out.append(gpa, tail);
            }
            return .{ .intervals = try out.toOwnedSlice(gpa) };
        }

        pub fn unionWith(self: Self, other: Self, gpa: std.mem.Allocator) error{OutOfMemory}!Self {
            var out: std.ArrayList(Interval) = .empty;
            var i: usize = 0;
            var j: usize = 0;
            var cur: ?Interval = null;
            while (i < self.intervals.len or j < other.intervals.len) {
                const pick_a = j == other.intervals.len or
                    (i < self.intervals.len and
                        cmpLow(self.intervals[i].low, other.intervals[j].low) != .gt);
                const iv = if (pick_a) self.intervals[i] else other.intervals[j];
                if (pick_a) i += 1 else j += 1;
                if (cur == null) {
                    cur = iv;
                    continue;
                }
                if (cmpHighLow(cur.?.high, iv.low) != .lt) {
                    cur.?.high = maxHigh(cur.?.high, iv.high);
                } else {
                    try out.append(gpa, cur.?);
                    cur = iv;
                }
            }
            if (cur) |last| try out.append(gpa, last);
            return .{ .intervals = try out.toOwnedSlice(gpa) };
        }

        /// `self ∖ other`.
        pub fn difference(self: Self, other: Self, gpa: std.mem.Allocator) error{OutOfMemory}!Self {
            const comp = try other.complement(gpa);
            return self.intersection(comp, gpa);
        }

        /// Structural equality on the canonical form.
        pub fn eql(self: Self, other: Self) bool {
            if (self.intervals.len != other.intervals.len) return false;
            for (self.intervals, other.intervals) |a, b| {
                if (!boundEql(a.low, b.low) or !boundEql(a.high, b.high)) return false;
            }
            return true;
        }

        fn boundEql(a: Bound, b: Bound) bool {
            if (a.inclusive != b.inclusive) return false;
            if (a.v == null and b.v == null) return true;
            if (a.v == null or b.v == null) return false;
            return V.cmp(a.v.?, b.v.?) == .eq;
        }

        /// `self ⊇ other` — the set relationship used by `Term.relation`.
        pub fn isSuperset(self: Self, other: Self) bool {
            return other.isSubset(self);
        }

        /// Formats like `>=1.0.0 <2.0.0`, `1.2.3`, `*`, or `>=1.0.0 <1.5.0 || >=2.0.0`.
        pub fn format(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            if (self.isEmpty()) return w.writeAll("<empty>");
            if (self.isAny()) return w.writeAll("*");
            for (self.intervals, 0..) |iv, k| {
                if (k != 0) try w.writeAll(" || ");
                const low = iv.low;
                const high = iv.high;
                if (low.v != null and high.v != null and
                    V.cmp(low.v.?, high.v.?) == .eq and low.inclusive and high.inclusive)
                {
                    try w.print("{f}", .{low.v.?});
                    continue;
                }
                if (low.v) |lv| {
                    try w.print("{s}{f}", .{ if (low.inclusive) ">=" else ">", lv });
                }
                if (low.v != null and high.v != null) try w.writeAll(" ");
                if (high.v) |hv| {
                    try w.print("{s}{f}", .{ if (high.inclusive) "<=" else "<", hv });
                }
            }
        }
    };
}

// --------------------------------------------------------------------------
// Tests (version domain = small integers 0..15 wrapped in a version type)
// --------------------------------------------------------------------------

const NumVer = struct {
    n: u32,
    pub fn cmp(a: NumVer, b: NumVer) std.math.Order {
        return std.math.order(a.n, b.n);
    }
    pub fn format(v: NumVer, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}", .{v.n});
    }
};
const TR = Range(NumVer);
const T = std.testing;

fn nv(n: u32) NumVer {
    return .{ .n = n };
}

fn nvo(n: ?u32) ?NumVer {
    return if (n) |x| nv(x) else null;
}

fn between(lo: ?u32, hi: ?u32) !TR {
    return TR.between(T.allocator, nvo(lo), true, nvo(hi), false);
}

fn betweenInc(lo: ?u32, li: bool, hi: ?u32, hi_incl: bool) !TR {
    return TR.between(T.allocator, nvo(lo), li, nvo(hi), hi_incl);
}

test "between and contains" {
    const r = try between(5, 10);
    try T.expect(!r.contains(nv(4)));
    try T.expect(r.contains(nv(5)));
    try T.expect(r.contains(nv(9)));
    try T.expect(!r.contains(nv(10)));
    try T.expect(!r.contains(nv(11)));
}

test "between unbounded sides" {
    const low = try between(null, 3);
    try T.expect(low.contains(nv(0)));
    try T.expect(low.contains(nv(2)));
    try T.expect(!low.contains(nv(3)));
    const high = try between(3, null);
    try T.expect(!high.contains(nv(2)));
    try T.expect(high.contains(nv(3)));
    try T.expect(high.contains(nv(999)));
    const any_r = try between(null, null);
    try T.expect(any_r.isAny());
    try T.expect(any_r.contains(nv(12345)));
}

test "empty and degenerate intervals" {
    try T.expect((try between(5, 5)).isEmpty()); // [5,5)
    try T.expect((try betweenInc(5, false, 5, true)).isEmpty()); // (5,5]
    try T.expect((try betweenInc(5, true, 5, false)).isEmpty()); // [5,5)
    const one = try betweenInc(5, true, 5, true); // [5,5]
    try T.expect(one.isSingleton());
    try T.expect(one.contains(nv(5)));
    try T.expect(!one.contains(nv(4)));
    try T.expect(!one.contains(nv(6)));
}

test "complement of any is empty and vice versa" {
    try T.expect((try TR.any.complement(T.allocator)).isEmpty());
    try T.expect((try TR.empty.complement(T.allocator)).isAny());
}

test "complement of bounded interval" {
    const r = try between(3, 7); // [3,7)
    const c = try r.complement(T.allocator);
    // Expect (-inf,3) ∪ [7,+inf)
    try T.expect(c.contains(nv(0)));
    try T.expect(c.contains(nv(2)));
    try T.expect(!c.contains(nv(3)));
    try T.expect(!c.contains(nv(6)));
    try T.expect(c.contains(nv(7)));
    try T.expect(c.contains(nv(999)));
    const back = try c.complement(T.allocator);
    try T.expect(back.eql(r));
}

test "complement of lower-unbounded interval" {
    const r = try between(null, 7); // (-inf,7)
    const c = try r.complement(T.allocator);
    try T.expect(!c.contains(nv(0)));
    try T.expect(c.contains(nv(7)));
    try T.expect(c.contains(nv(999)));
    try T.expect(c.eql(try between(7, null)));
}

test "complement of upper-unbounded interval" {
    const r = try between(3, null); // [3,+inf)
    const c = try r.complement(T.allocator);
    try T.expect(c.contains(nv(0)));
    try T.expect(!c.contains(nv(3)));
    try T.expect(c.eql(try between(null, 3)));
}

test "complement of multi-interval range" {
    const a = try between(2, 4);
    const b = try between(7, 9);
    const u = try a.unionWith(b, T.allocator); // [2,4) ∪ [7,9)
    const c = try u.complement(T.allocator);
    try T.expect(c.contains(nv(0)));
    try T.expect(!c.contains(nv(2)));
    try T.expect(c.contains(nv(4)));
    try T.expect(c.contains(nv(6)));
    try T.expect(!c.contains(nv(7)));
    try T.expect(c.contains(nv(9)));
    const back = try c.complement(T.allocator);
    try T.expect(back.eql(u));
}

test "complement touching boundaries" {
    // [2,4] ∪ [5,7): the gap is the open interval (4,5).
    const a = try betweenInc(2, true, 4, true);
    const b = try between(5, 7);
    const u = try a.unionWith(b, T.allocator);
    const c = try u.complement(T.allocator);
    const gap = try betweenInc(4, false, 5, false);
    try T.expect(c.eql(gap));
}

test "union merges overlapping and touching intervals" {
    const a = try between(1, 5);
    const b = try between(4, 9);
    try T.expect((try a.unionWith(b, T.allocator)).eql(try between(1, 9)));
    const c = try betweenInc(1, true, 5, true); // [1,5]
    const d = try betweenInc(5, true, 9, false); // [5,9) — touches at 5
    try T.expect((try c.unionWith(d, T.allocator)).eql(try between(1, 9)));
    // (1,5) ∪ (5,9): point 5 uncovered → stays split.
    const e = try betweenInc(1, true, 5, false);
    const f = try betweenInc(5, false, 9, false);
    const u = try e.unionWith(f, T.allocator);
    try T.expectEqual(@as(usize, 2), u.intervals.len);
    try T.expect(!u.contains(nv(5)));
}

test "intersection" {
    const a = try between(1, 8);
    const b = try between(3, 12);
    try T.expect((try a.intersection(b, T.allocator)).eql(try between(3, 8)));
    const c = try between(9, 12);
    try T.expect((try a.intersection(c, T.allocator)).isEmpty());
}

test "difference" {
    const a = try between(1, 9);
    const b = try between(3, 6);
    const d = try a.difference(b, T.allocator); // [1,3) ∪ [6,9)
    try T.expectEqual(@as(usize, 2), d.intervals.len);
    try T.expect(d.contains(nv(1)));
    try T.expect(!d.contains(nv(4)));
    try T.expect(d.contains(nv(7)));
    try T.expect(!d.contains(nv(9)));
}

test "isSubset" {
    const small = try between(2, 5);
    const big = try between(1, 9);
    try T.expect(small.isSubset(big));
    try T.expect(!big.isSubset(small));
    try T.expect(TR.any.isSubset(TR.any));
    try T.expect(small.isSubset(TR.any));
    try T.expect(TR.empty.isSubset(small));
    try T.expect(!small.isSubset(TR.empty));
}

test "isSubset across chained intervals" {
    // other = [0,4] ∪ [5,9] does NOT cover [0,10) (gap at (4,5)).
    const a = try betweenInc(0, true, 4, true);
    const b = try betweenInc(5, true, 9, true);
    const other = try a.unionWith(b, T.allocator);
    const probe = try between(0, 10);
    try T.expect(!probe.isSubset(other));
    try T.expect(a.isSubset(other));
    // other2 = [0,5) ∪ [4,9] covers [0,10).
    const a2 = try between(0, 5);
    const b2 = try betweenInc(4, true, 9, true);
    const other2 = try a2.unionWith(b2, T.allocator);
    try T.expect(probe.isSubset(other2));
}

test "isSubset point-exclusion edges" {
    // [0,5] ⊆ [0,5)? No — 5 is missing.
    const a = try betweenInc(0, true, 5, true);
    const other = try between(0, 5);
    try T.expect(!a.isSubset(other));
    // (0,5] ⊆ [0,5].
    const a2 = try betweenInc(0, false, 5, true);
    const other2 = try betweenInc(0, true, 5, true);
    try T.expect(a2.isSubset(other2));
    // [0,5] ⊆ [0,4] ∪ [5,6) — covered via chain at point 5.
    const p = try betweenInc(0, true, 4, true);
    const q = try between(5, 6);
    const chain = try p.unionWith(q, T.allocator);
    try T.expect(a.isSubset(chain));
}

test "isDisjoint" {
    const a = try between(1, 4);
    const b = try between(4, 8);
    try T.expect(a.isDisjoint(b));
    const c = try between(3, 8);
    try T.expect(!a.isDisjoint(c));
    try T.expect(TR.empty.isDisjoint(TR.any));
    try T.expect(!TR.any.isDisjoint(TR.any));
}

test "coversAll" {
    const a = try between(null, 5);
    const b = try between(5, null);
    try T.expect(a.coversAll(b)); // (-inf,5) ∪ [5,+inf) = all
    const c = try between(null, 6);
    const d = try between(4, null);
    try T.expect(c.coversAll(d));
    const e = try between(null, 4);
    const f = try between(6, null);
    try T.expect(!e.coversAll(f)); // gap [4,6)
    // Touch at a single uncovered point: (-inf,5) ∪ (5,+inf) → missing 5.
    const g = try betweenInc(null, true, 5, false);
    const h = try betweenInc(5, false, null, true);
    try T.expect(!g.coversAll(h));
}

test "eql canonical form" {
    const a = try between(1, 5);
    const b = try between(1, 5);
    try T.expect(a.eql(b));
    const u = try (try between(1, 3)).unionWith(try between(3, 5), T.allocator);
    try T.expect(u.eql(a));
    const c = try betweenInc(1, false, 5, false);
    try T.expect(!a.eql(c));
}

test "range set operations against sampled versions" {
    const a = try betweenInc(2, true, 6, true);
    const b = try between(5, 9);
    const au = try a.unionWith(b, T.allocator);
    const an = try a.intersection(b, T.allocator);
    const ad = try a.difference(b, T.allocator);
    const ac = try a.complement(T.allocator);
    var v_i: u32 = 0;
    while (v_i < 16) : (v_i += 1) {
        const v = nv(v_i);
        const in_a = a.contains(v);
        const in_b = b.contains(v);
        try T.expectEqual(in_a or in_b, au.contains(v));
        try T.expectEqual(in_a and in_b, an.contains(v));
        try T.expectEqual(in_a and !in_b, ad.contains(v));
        try T.expectEqual(!in_a, ac.contains(v));
    }
}

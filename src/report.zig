const std = @import("std");

const Allocator = std.mem.Allocator;

/// Renders the derivation graph of a failed solve as a human-readable
/// explanation. Port of pub's solver failure writer; see
/// https://github.com/dart-lang/pub/tree/main/doc/solver.md#error-reporting.
///
fn fieldType(comptime S: type, comptime name: []const u8) type {
    for (@typeInfo(S).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.type;
    }
    unreachable;
}

/// `I` is the solver's `Incompatibility` type (from `Solver(P, V)`).
pub fn Reporter(comptime I: type) type {
    return struct {
        const Self = @This();

        const Incompatibility = I;
        const TermEntry = std.meta.Child(fieldType(I, "terms"));
        const P = fieldType(TermEntry, "package");
        const T = fieldType(TermEntry, "term");

        const Line = struct { msg: []const u8, number: ?u32 };

        gpa: Allocator,
        store: []const Incompatibility,
        root_pkg: P,
        failure_id: u32,

        /// id → how many derivations in the failure's graph use the
        /// incompatibility as a cause.
        derivations: std.AutoHashMap(u32, u32) = undefined,
        /// id → assigned line number.
        line_numbers: std.AutoHashMap(u32, u32) = undefined,
        lines: std.ArrayList(Line) = .empty,

        fn countDerivations(self: *Self, id: u32) !void {
            const gop = try self.derivations.getOrPut(id);
            if (gop.found_existing) {
                gop.value_ptr.* += 1;
                return;
            }
            gop.value_ptr.* = 1;
            const cause = self.store[id].cause;
            if (cause == .derived) {
                try self.countDerivations(cause.derived.conflict);
                try self.countDerivations(cause.derived.other);
            }
        }

        /// Render the failure explanation.
        pub fn write(self: *Self) ![]const u8 {
            const gpa = self.gpa;
            self.derivations = std.AutoHashMap(u32, u32).init(gpa);
            self.line_numbers = std.AutoHashMap(u32, u32).init(gpa);
            try self.countDerivations(self.failure_id);

            const root = self.store[self.failure_id];
            if (root.cause == .derived) {
                try self.visit(self.failure_id, false);
            } else {
                const s = try self.toString(self.failure_id);
                try self.writeLine(
                    self.failure_id,
                    try self.fmt("Because {s}, version solving failed.", .{s}),
                    false,
                );
            }

            var out: std.ArrayList(u8) = .empty;
            var padding: usize = 0;
            if (self.line_numbers.count() > 0) {
                var max: u32 = 0;
                var it = self.line_numbers.valueIterator();
                while (it.next()) |n| max = @max(max, n.*);
                padding = std.fmt.count("({d}) ", .{max});
            }

            var last_empty = false;
            for (self.lines.items) |line| {
                if (line.msg.len == 0) {
                    if (!last_empty) try out.appendSlice(gpa, "\n");
                    last_empty = true;
                    continue;
                }
                last_empty = false;
                var width: usize = 0;
                if (line.number) |n| {
                    const num = try std.fmt.allocPrint(gpa, "({d})", .{n});
                    try out.appendSlice(gpa, num);
                    width = num.len + 1; // "(n) "
                }
                while (width < padding) : (width += 1) try out.append(gpa, ' ');
                try out.appendSlice(gpa, line.msg);
                try out.append(gpa, '\n');
            }

            // Hints: reasons attached to external incompatibilities in the
            // derivation graph, deduplicated and sorted for determinism.
            var hints: std.ArrayList([]const u8) = .empty;
            var seen = std.AutoHashMap(u32, void).init(gpa);
            try self.collectHints(self.failure_id, &hints, &seen);
            std.mem.sort([]const u8, hints.items, {}, struct {
                fn lt(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.lt);
            var prev: ?[]const u8 = null;
            for (hints.items) |h| {
                if (prev != null and std.mem.eql(u8, prev.?, h)) continue;
                prev = h;
                try out.appendSlice(gpa, "\n");
                try out.appendSlice(gpa, h);
                try out.append(gpa, '\n');
            }

            return out.items;
        }

        fn collectHints(
            self: *Self,
            id: u32,
            out: *std.ArrayList([]const u8),
            seen: *std.AutoHashMap(u32, void),
        ) !void {
            if (seen.contains(id)) return;
            try seen.put(id, {});
            switch (self.store[id].cause) {
                .derived => |d| {
                    try self.collectHints(d.conflict, out, seen);
                    try self.collectHints(d.other, out, seen);
                },
                .forbidden => |r| if (r) |s| try out.append(self.gpa, s),
                .required => |r| if (r) |s| try out.append(self.gpa, s),
                .unavailable => |r| if (r) |s| try out.append(self.gpa, s),
                else => {},
            }
        }

        fn fmt(self: *Self, comptime f: []const u8, args: anytype) ![]const u8 {
            return std.fmt.allocPrint(self.gpa, f, args);
        }

        fn writeLine(self: *Self, id: u32, msg: []const u8, numbered: bool) !void {
            if (numbered) {
                const n: u32 = @intCast(self.line_numbers.count() + 1);
                try self.line_numbers.put(id, n);
                try self.lines.append(self.gpa, .{ .msg = msg, .number = n });
            } else {
                try self.lines.append(self.gpa, .{ .msg = msg, .number = null });
            }
        }

        fn isDerived(self: *Self, id: u32) bool {
            return self.store[id].cause == .derived;
        }

        /// Whether both causes of `id`'s (derived) incompatibility are
        /// external, so it can be described in a single line.
        fn isSingleLine(self: *Self, id: u32) bool {
            const c = self.store[id].cause.derived;
            return !self.isDerived(c.conflict) and !self.isDerived(c.other);
        }

        /// Whether `id`'s derivation may be folded into its successor: it feeds
        /// only one derivation, is not derived from two derived
        /// incompatibilities, and is not itself the merge of two externals.
        fn isCollapsible(self: *Self, id: u32) bool {
            if ((self.derivations.get(id) orelse 0) > 1) return false;
            const c = self.store[id].cause.derived;
            const c_d = self.isDerived(c.conflict);
            const o_d = self.isDerived(c.other);
            if (c_d and o_d) return false;
            if (!c_d and !o_d) return false;
            const complex = if (c_d) c.conflict else c.other;
            return !self.line_numbers.contains(complex);
        }

        fn visit(self: *Self, id: u32, conclusion: bool) anyerror!void {
            const inc = self.store[id];
            const numbered = conclusion or (self.derivations.get(id) orelse 0) > 1;
            const conjunction = if (conclusion or id == self.failure_id) "So," else "And";
            const inc_str = try self.toString(id);
            const cause = inc.cause.derived;

            const c_d = self.isDerived(cause.conflict);
            const o_d = self.isDerived(cause.other);
            if (c_d and o_d) {
                const cl = self.line_numbers.get(cause.conflict);
                const ol = self.line_numbers.get(cause.other);
                if (cl != null and ol != null) {
                    const both = try self.andToString(cause.conflict, cause.other, cl, ol);
                    try self.writeLine(
                        id,
                        try self.fmt("Because {s}, {s}.", .{ both, inc_str }),
                        numbered,
                    );
                } else if (cl != null or ol != null) {
                    const with_line = if (cl != null) cause.conflict else cause.other;
                    const without_line = if (cl != null) cause.other else cause.conflict;
                    const line = (cl orelse ol).?;
                    try self.visit(without_line, false);
                    const s = try self.toString(with_line);
                    try self.writeLine(
                        id,
                        try self.fmt("{s} because {s} ({d}), {s}.", .{ conjunction, s, line, inc_str }),
                        numbered,
                    );
                } else {
                    const single_c = self.isSingleLine(cause.conflict);
                    const single_o = self.isSingleLine(cause.other);
                    if (single_c or single_o) {
                        const first = if (single_o) cause.conflict else cause.other;
                        const second = if (single_o) cause.other else cause.conflict;
                        try self.visit(first, false);
                        try self.visit(second, false);
                        try self.writeLine(id, try self.fmt("Thus, {s}.", .{inc_str}), numbered);
                    } else {
                        try self.visit(cause.conflict, true);
                        try self.lines.append(self.gpa, .{ .msg = "", .number = null });
                        try self.visit(cause.other, false);
                        const s = try self.toString(cause.conflict);
                        try self.writeLine(
                            id,
                            try self.fmt("{s} because {s} ({d}), {s}.", .{
                                conjunction,
                                s,
                                self.line_numbers.get(cause.conflict).?,
                                inc_str,
                            }),
                            numbered,
                        );
                    }
                }
            } else if (c_d or o_d) {
                const derived = if (c_d) cause.conflict else cause.other;
                const ext = if (c_d) cause.other else cause.conflict;
                const dl = self.line_numbers.get(derived);
                if (dl != null) {
                    const s = try self.andToString(ext, derived, null, dl);
                    try self.writeLine(
                        id,
                        try self.fmt("Because {s}, {s}.", .{ s, inc_str }),
                        numbered,
                    );
                } else if (self.isCollapsible(derived)) {
                    const dc = self.store[derived].cause.derived;
                    const collapsed_derived = if (self.isDerived(dc.conflict)) dc.conflict else dc.other;
                    const collapsed_ext = if (self.isDerived(dc.conflict)) dc.other else dc.conflict;
                    try self.visit(collapsed_derived, false);
                    const s = try self.andToString(collapsed_ext, ext, null, null);
                    try self.writeLine(
                        id,
                        try self.fmt("{s} because {s}, {s}.", .{ conjunction, s, inc_str }),
                        numbered,
                    );
                } else {
                    try self.visit(derived, false);
                    const s = try self.toString(ext);
                    try self.writeLine(
                        id,
                        try self.fmt("{s} because {s}, {s}.", .{ conjunction, s, inc_str }),
                        numbered,
                    );
                }
            } else {
                const s = try self.andToString(cause.conflict, cause.other, null, null);
                try self.writeLine(
                    id,
                    try self.fmt("Because {s}, {s}.", .{ s, inc_str }),
                    numbered,
                );
            }
        }

        // ------------------------------------------------------------------
        // Incompatibility → text
        // ------------------------------------------------------------------

        /// "`pkg range`"; with `allow_every`, an unrestricted range reads
        /// "every version of pkg".
        fn terse(self: *Self, e: TermEntry, allow_every: bool) ![]const u8 {
            const r = e.term.range();
            if (allow_every and r.isAny())
                return self.fmt("every version of {f}", .{e.package});
            return self.fmt("{f} {f}", .{ e.package, r });
        }

        /// The package name alone.
        fn terseRef(self: *Self, e: TermEntry) ![]const u8 {
            return self.fmt("{f}", .{e.package});
        }

        /// Full sentence for an incompatibility (port of
        /// Incompatibility.toString).
        fn toString(self: *Self, id: u32) anyerror![]const u8 {
            const inc = self.store[id];
            const terms = inc.terms;
            switch (inc.cause) {
                .dependency => {
                    return self.fmt("{s} depends on {s}", .{
                        try self.terse(terms[0], true),
                        try self.terse(terms[1], false),
                    });
                },
                .no_versions => {
                    return self.fmt("no versions of {s} match {f}", .{
                        try self.terseRef(terms[0]),
                        terms[0].term.range(),
                    });
                },
                .not_found => return self.fmt("{s} doesn't exist", .{try self.terseRef(terms[0])}),
                .root => return self.fmt("{f} is {f}", .{ terms[0].package, terms[0].term.range() }),
                .unavailable => |r| {
                    if (r) |reason|
                        return self.fmt("{s} is unavailable ({s})", .{ try self.terse(terms[0], true), reason });
                    return self.fmt("{s} is unavailable", .{try self.terse(terms[0], true)});
                },
                // .forbidden / .required fall through to generic rendering.
                else => {},
            }

            if (inc.isFailure(self.root_pkg)) return self.fmt("version solving failed", .{});

            if (terms.len == 1) {
                const t = terms[0];
                const word = if (t.term == .positive) "forbidden" else "required";
                if (t.term.range().isAny())
                    return self.fmt("{s} is {s}", .{ try self.terseRef(t), word });
                return self.fmt("{s} is {s}", .{ try self.terse(t, false), word });
            }

            if (terms.len == 2 and
                (terms[0].term == .positive) == (terms[1].term == .positive))
            {
                if (terms[0].term == .positive) {
                    const a = if (terms[0].term.range().isAny())
                        try self.terseRef(terms[0])
                    else
                        try self.terse(terms[0], false);
                    const b = if (terms[1].term.range().isAny())
                        try self.terseRef(terms[1])
                    else
                        try self.terse(terms[1], false);
                    return self.fmt("{s} is incompatible with {s}", .{ a, b });
                }
                return self.fmt("either {s} or {s}", .{
                    try self.terse(terms[0], false),
                    try self.terse(terms[1], false),
                });
            }

            var positive: std.ArrayList([]const u8) = .empty;
            var negative: std.ArrayList([]const u8) = .empty;
            for (terms) |t| {
                const s = try self.terse(t, false);
                if (t.term == .positive)
                    try positive.append(self.gpa, s)
                else
                    try negative.append(self.gpa, s);
            }
            if (positive.items.len != 0 and negative.items.len != 0) {
                if (positive.items.len == 1) {
                    const pt = for (terms) |t| {
                        if (t.term == .positive) break t;
                    } else unreachable;
                    return self.fmt("{s} requires {s}", .{
                        try self.terse(pt, true),
                        try std.mem.join(self.gpa, " or ", negative.items),
                    });
                }
                return self.fmt("if {s} then {s}", .{
                    try std.mem.join(self.gpa, " and ", positive.items),
                    try std.mem.join(self.gpa, " or ", negative.items),
                });
            }
            if (positive.items.len != 0) {
                return self.fmt("one of {s} must be false", .{
                    try std.mem.join(self.gpa, " or ", positive.items),
                });
            }
            return self.fmt("one of {s} must be true", .{
                try std.mem.join(self.gpa, " or ", negative.items),
            });
        }

        /// "`a` and `b`" with smarter phrasing where possible (port of
        /// Incompatibility.andToString).
        fn andToString(self: *Self, a: u32, b: u32, a_line: ?u32, b_line: ?u32) ![]const u8 {
            if (try self.tryRequiresBoth(a, b, a_line, b_line)) |s| return s;
            if (try self.tryRequiresThrough(a, b, a_line, b_line)) |s| return s;
            if (try self.tryRequiresForbidden(a, b, a_line, b_line)) |s| return s;

            const sa = try self.toString(a);
            const sb = try self.toString(b);
            const al = try self.lineSuffix(a_line);
            const bl = try self.lineSuffix(b_line);
            return self.fmt("{s}{s} and {s}{s}", .{ sa, al, sb, bl });
        }

        fn singleTermWhere(inc: Incompatibility, positive: bool) ?TermEntry {
            var found: ?TermEntry = null;
            for (inc.terms) |t| {
                if ((t.term == .positive) != positive) continue;
                if (found != null) return null;
                found = t;
            }
            return found;
        }

        fn lineSuffix(self: *Self, line: ?u32) ![]const u8 {
            return if (line) |l| self.fmt(" ({d})", .{l}) else "";
        }

        /// "X requires both Y and Z".
        fn tryRequiresBoth(self: *Self, a: u32, b: u32, a_line: ?u32, b_line: ?u32) !?[]const u8 {
            const ia = self.store[a];
            const ib = self.store[b];
            if (ia.terms.len == 1 or ib.terms.len == 1) return null;
            const pa = singleTermWhere(ia, true) orelse return null;
            const pb = singleTermWhere(ib, true) orelse return null;
            if (!P.eql(pa.package, pb.package)) return null;

            var negs_a: std.ArrayList([]const u8) = .empty;
            var negs_b: std.ArrayList([]const u8) = .empty;
            for (ia.terms) |t| {
                if (t.term == .negative) try negs_a.append(self.gpa, try self.terse(t, false));
            }
            for (ib.terms) |t| {
                if (t.term == .negative) try negs_b.append(self.gpa, try self.terse(t, false));
            }
            const verb = if (ia.cause == .dependency and ib.cause == .dependency)
                "depends on"
            else
                "requires";
            return try self.fmt("{s} {s} both {s}{s} and {s}{s}", .{
                try self.terse(pa, true),
                verb,
                try std.mem.join(self.gpa, " or ", negs_a.items),
                try self.lineSuffix(a_line),
                try std.mem.join(self.gpa, " or ", negs_b.items),
                try self.lineSuffix(b_line),
            });
        }

        /// "X requires Y which requires Z".
        fn tryRequiresThrough(self: *Self, a: u32, b: u32, a_line: ?u32, b_line: ?u32) !?[]const u8 {
            const ia = self.store[a];
            const ib = self.store[b];
            if (ia.terms.len == 1 or ib.terms.len == 1) return null;
            const na = singleTermWhere(ia, false);
            const nb = singleTermWhere(ib, false);
            if (na == null and nb == null) return null;
            const pa = singleTermWhere(ia, true);
            const pb = singleTermWhere(ib, true);

            var prior: u32 = undefined;
            var prior_negative: TermEntry = undefined;
            var prior_line: ?u32 = null;
            var latter: u32 = undefined;
            var latter_line: ?u32 = null;
            if (na != null and pb != null and
                P.eql(na.?.package, pb.?.package) and
                na.?.term.inverse().satisfies(pb.?.term))
            {
                prior = a;
                prior_negative = na.?;
                prior_line = a_line;
                latter = b;
                latter_line = b_line;
            } else if (nb != null and pa != null and
                P.eql(nb.?.package, pa.?.package) and
                nb.?.term.inverse().satisfies(pa.?.term))
            {
                prior = b;
                prior_negative = nb.?;
                prior_line = b_line;
                latter = a;
                latter_line = a_line;
            } else return null;

            const ip = self.store[prior];
            const il = self.store[latter];
            var buf: std.ArrayList(u8) = .empty;
            const w = &buf;
            const gpa = self.gpa;

            var prior_pos_count: usize = 0;
            var prior_pos: ?TermEntry = null;
            for (ip.terms) |t| {
                if (t.term == .positive) {
                    prior_pos_count += 1;
                    prior_pos = t;
                }
            }
            if (prior_pos_count == 0) return null;
            if (prior_pos_count > 1) {
                var parts: std.ArrayList([]const u8) = .empty;
                for (ip.terms) |t| {
                    if (t.term == .positive) try parts.append(gpa, try self.terse(t, false));
                }
                try w.print(gpa, "if {s} then ", .{try std.mem.join(gpa, " or ", parts.items)});
            } else {
                const verb = if (ip.cause == .dependency) "depends on" else "requires";
                try w.print(gpa, "{s} {s} ", .{ try self.terse(prior_pos.?, true), verb });
            }
            try w.print(gpa, "{s}{s} which ", .{
                try self.terse(prior_negative, false),
                try self.lineSuffix(prior_line),
            });
            try w.appendSlice(gpa, if (il.cause == .dependency) "depends on " else "requires ");
            var latter_negs: std.ArrayList([]const u8) = .empty;
            for (il.terms) |t| {
                if (t.term == .negative) try latter_negs.append(gpa, try self.terse(t, false));
            }
            try w.print(gpa, "{s}{s}", .{
                try std.mem.join(gpa, " or ", latter_negs.items),
                try self.lineSuffix(latter_line),
            });
            return w.items;
        }

        /// "X requires Y which is forbidden / doesn't match / doesn't exist".
        fn tryRequiresForbidden(self: *Self, a: u32, b: u32, a_line: ?u32, b_line: ?u32) !?[]const u8 {
            const ia = self.store[a];
            const ib = self.store[b];
            if (ia.terms.len != 1 and ib.terms.len != 1) return null;
            const prior_id = if (ia.terms.len == 1) b else a;
            const latter_id = if (ia.terms.len == 1) a else b;
            const prior_line = if (ia.terms.len == 1) b_line else a_line;
            const latter_line = if (ia.terms.len == 1) a_line else b_line;
            const ip = self.store[prior_id];
            const il = self.store[latter_id];

            const negative = singleTermWhere(ip, false) orelse return null;
            if (!negative.term.inverse().satisfies(il.terms[0].term)) return null;

            var buf: std.ArrayList(u8) = .empty;
            const w = &buf;
            const gpa = self.gpa;

            var pos_count: usize = 0;
            var pos: ?TermEntry = null;
            for (ip.terms) |t| {
                if (t.term == .positive) {
                    pos_count += 1;
                    pos = t;
                }
            }
            if (pos_count == 0) return null;
            if (pos_count > 1) {
                var parts: std.ArrayList([]const u8) = .empty;
                for (ip.terms) |t| {
                    if (t.term == .positive) try parts.append(gpa, try self.terse(t, false));
                }
                try w.print(gpa, "if {s} then ", .{try std.mem.join(gpa, " or ", parts.items)});
            } else {
                try w.appendSlice(gpa, try self.terse(pos.?, true));
                try w.appendSlice(gpa, if (ip.cause == .dependency) " depends on " else " requires ");
            }
            try w.print(gpa, "{s}{s} ", .{
                try self.terse(il.terms[0], false),
                try self.lineSuffix(prior_line),
            });

            switch (il.cause) {
                .no_versions => try w.appendSlice(gpa, "which doesn't match any versions"),
                .not_found => try w.appendSlice(gpa, "which doesn't exist"),
                .unavailable => |r| {
                    if (r) |reason|
                        try w.print(gpa, "which is unavailable ({s})", .{reason})
                    else
                        try w.appendSlice(gpa, "which is unavailable");
                },
                else => try w.appendSlice(gpa, "which is forbidden"),
            }
            try w.appendSlice(gpa, try self.lineSuffix(latter_line));
            return w.items;
        }
    };
}

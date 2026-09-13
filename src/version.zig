const std = @import("std");

/// A [Semantic Versioning 2.0.0](https://semver.org/) version.
///
/// Satisfies the version-type interface required by `pubgrub.Solver`:
/// `cmp`, `eql`, `format`, and `isPrerelease`.
pub const SemanticVersion = struct {
    major: u64,
    minor: u64,
    patch: u64,
    /// Dot-separated pre-release identifiers, or "" for a release version.
    pre: []const u8 = "",
    /// Build metadata, or "" when absent. Ignored for precedence.
    build: []const u8 = "",

    pub const ParseError = error{ Invalid, Overflow };

    pub fn parse(text: []const u8) ParseError!SemanticVersion {
        var rest = text;
        var build: []const u8 = "";
        if (std.mem.indexOfScalar(u8, rest, '+')) |plus| {
            build = rest[plus + 1 ..];
            rest = rest[0..plus];
            if (!validIdents(build, false)) return error.Invalid;
        }
        var pre: []const u8 = "";
        if (std.mem.indexOfScalar(u8, rest, '-')) |dash| {
            pre = rest[dash + 1 ..];
            rest = rest[0..dash];
            if (!validIdents(pre, true)) return error.Invalid;
        }
        var it = std.mem.splitScalar(u8, rest, '.');
        const major = try numIdent(it.next() orelse return error.Invalid);
        const minor = try numIdent(it.next() orelse return error.Invalid);
        const patch = try numIdent(it.next() orelse return error.Invalid);
        if (it.next() != null) return error.Invalid;
        return .{ .major = major, .minor = minor, .patch = patch, .pre = pre, .build = build };
    }

    fn numIdent(s: []const u8) ParseError!u64 {
        if (s.len == 0) return error.Invalid;
        if (s.len > 1 and s[0] == '0') return error.Invalid; // no leading zeros
        for (s) |c| if (!std.ascii.isDigit(c)) return error.Invalid;
        return std.fmt.parseInt(u64, s, 10) catch return error.Overflow;
    }

    fn validIdents(s: []const u8, pre_release: bool) bool {
        if (s.len == 0) return false;
        var it = std.mem.splitScalar(u8, s, '.');
        while (it.next()) |ident| {
            if (ident.len == 0) return false;
            var numeric = true;
            for (ident) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '-') return false;
                if (!std.ascii.isDigit(c)) numeric = false;
            }
            // Numeric pre-release identifiers must not have leading zeros.
            if (pre_release and numeric and ident.len > 1 and ident[0] == '0') return false;
        }
        return true;
    }

    /// Total order by precedence. Build metadata is ignored, per semver §10.
    pub fn cmp(a: SemanticVersion, b: SemanticVersion) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        if (a.patch != b.patch) return std.math.order(a.patch, b.patch);
        return cmpPre(a.pre, b.pre);
    }

    fn cmpPre(a: []const u8, b: []const u8) std.math.Order {
        // A release version sorts after any of its pre-releases.
        if (a.len == 0 and b.len == 0) return .eq;
        if (a.len == 0) return .gt;
        if (b.len == 0) return .lt;
        var ai = std.mem.splitScalar(u8, a, '.');
        var bi = std.mem.splitScalar(u8, b, '.');
        while (true) {
            const x = ai.next();
            const y = bi.next();
            if (x == null and y == null) return .eq;
            if (x == null) return .lt; // fewer identifiers < more
            if (y == null) return .gt;
            const c = cmpIdent(x.?, y.?);
            if (c != .eq) return c;
        }
    }

    fn cmpIdent(a: []const u8, b: []const u8) std.math.Order {
        const a_numeric = allDigits(a);
        const b_numeric = allDigits(b);
        if (a_numeric and b_numeric) {
            const an = std.fmt.parseInt(u64, a, 10) catch null;
            const bn = std.fmt.parseInt(u64, b, 10) catch null;
            if (an != null and bn != null)
                return std.math.order(an.?, bn.?);
            // An identifier overflowing u64 is still numeric: compare by
            // significant-digit count (leading zeros skipped), then digits.
            var az: usize = 0;
            while (az < a.len and a[az] == '0') az += 1;
            var bz: usize = 0;
            while (bz < b.len and b[bz] == '0') bz += 1;
            const at = a[az..];
            const bt = b[bz..];
            if (at.len != bt.len) return std.math.order(at.len, bt.len);
            return std.mem.order(u8, at, bt);
        }
        if (a_numeric) return .lt; // numeric < alphanumeric
        if (b_numeric) return .gt;
        return std.mem.order(u8, a, b);
    }

    fn allDigits(s: []const u8) bool {
        for (s) |c| if (!std.ascii.isDigit(c)) return false;
        return s.len > 0;
    }

    /// Structural equality including build metadata.
    pub fn eql(a: SemanticVersion, b: SemanticVersion) bool {
        return a.major == b.major and a.minor == b.minor and a.patch == b.patch and
            std.mem.eql(u8, a.pre, b.pre) and std.mem.eql(u8, a.build, b.build);
    }

    /// Semantic equality, ignoring build metadata (same precedence).
    pub fn equivalent(a: SemanticVersion, b: SemanticVersion) bool {
        return a.cmp(b) == .eq;
    }

    pub fn hash(v: SemanticVersion) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&v.major));
        h.update(std.mem.asBytes(&v.minor));
        h.update(std.mem.asBytes(&v.patch));
        h.update(v.pre);
        h.update(v.build);
        return h.final();
    }

    pub fn isPrerelease(v: SemanticVersion) bool {
        return v.pre.len != 0;
    }

    pub fn format(v: SemanticVersion, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
        if (v.pre.len != 0) try w.print("-{s}", .{v.pre});
        if (v.build.len != 0) try w.print("+{s}", .{v.build});
    }
};

test "parse and compare" {
    const a = try SemanticVersion.parse("1.2.3-alpha.1+build.5");
    try std.testing.expectEqual(@as(u64, 1), a.major);
    try std.testing.expectEqualStrings("alpha.1", a.pre);
    try std.testing.expectEqualStrings("build.5", a.build);
    try std.testing.expectEqualStrings("1.2.3-alpha.1+build.5", try std.fmt.allocPrint(std.testing.allocator, "{f}", .{a}));

    const order = std.math.order;
    const V = SemanticVersion;
    try std.testing.expect((try V.parse("1.0.0-alpha")).cmp(try V.parse("1.0.0")) == .lt);
    try std.testing.expect((try V.parse("1.0.0-alpha")).cmp(try V.parse("1.0.0-alpha.1")) == .lt);
    try std.testing.expect((try V.parse("1.0.0-alpha.1")).cmp(try V.parse("1.0.0-alpha.beta")) == .lt);
    try std.testing.expect((try V.parse("1.0.0-beta.2")).cmp(try V.parse("1.0.0-beta.11")) == .lt);
    try std.testing.expect((try V.parse("1.0.0-rc.1")).cmp(try V.parse("1.0.0")) == .lt);
    try std.testing.expect((try V.parse("2.0.0")).cmp(try V.parse("10.0.0")) == .lt);
    _ = order;

    try std.testing.expectError(error.Invalid, V.parse("1.0"));
    try std.testing.expectError(error.Invalid, V.parse("01.0.0"));
    try std.testing.expectError(error.Invalid, V.parse("1.0.0-01"));
    try std.testing.expectError(error.Invalid, V.parse("1.0.0-"));
}

const std = @import("std");
const version_mod = @import("version.zig");
const range_mod = @import("range.zig");

const SemanticVersion = version_mod.SemanticVersion;
const SemverRange = range_mod.Range(SemanticVersion);

pub const ParseError = error{ Invalid, OutOfMemory };

/// Parses an npm/cargo-style version requirement into a `Range(SemanticVersion)`.
///
/// Grammar (case-insensitive, extra whitespace allowed):
///   range   := union
///   union   := intersection ("||" intersection)*
///   intersection := comparator+
///   comparator := "*" | "x"
///               | ("^" | "~") partial
///               | ("<=" | ">=" | "<" | ">" | "=")? partial
///   partial := [0-9]+ (".x" | ".*")?
///            | [0-9]+ "." ([0-9]+ | "x" | "*") (("." ([0-9]+ | "x" | "*") partialSuffix?)?)
///
/// Examples: `*`, `1.2.3`, `^1.2.3`, `~1.2`, `>=1.0.0 <2.0.0`, `1.x`,
/// `>=1.0.0 <2.0.0 || >=3.0.0`.
///
/// Unlike npm's implementation, pre-release versions are not excluded from
/// ranges implicitly: `>=1.0.0` also admits `2.0.0-alpha` unless the range
/// upper bound excludes it. Express exclusions with explicit bounds.
pub fn parse(gpa: std.mem.Allocator, text: []const u8) ParseError!SemverRange {
    // A lone `|` is not a separator; only `||` is.
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '|') continue;
        const lone = !(i > 0 and text[i - 1] == '|') and
            !(i + 1 < text.len and text[i + 1] == '|');
        if (lone) return error.Invalid;
    }
    var it = std.mem.splitSequence(u8, text, "||");
    var result: SemverRange = .empty;
    var saw_any = false;
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) {
            if (saw_any) return error.Invalid;
            continue;
        }
        saw_any = true;
        const inter = try parseIntersection(gpa, trimmed);
        result = try result.unionWith(inter, gpa);
    }
    if (!saw_any) return error.Invalid;
    return result;
}

fn parseIntersection(gpa: std.mem.Allocator, text: []const u8) ParseError!SemverRange {
    var result: SemverRange = .any;
    var pos: usize = 0;
    var saw = false;
    while (pos < text.len) {
        while (pos < text.len and (text[pos] == ' ' or text[pos] == '\t')) pos += 1;
        if (pos >= text.len) break;
        const start = pos;
        while (pos < text.len and text[pos] != ' ' and text[pos] != '\t') pos += 1;
        const tok = text[start..pos];
        if (std.mem.eql(u8, tok, "|")) return error.Invalid;
        const cmp = try parseComparator(gpa, tok);
        result = try result.intersection(cmp, gpa);
        saw = true;
    }
    if (!saw) return error.Invalid;
    return result;
}

const Kind = enum { caret, tilde, ge, gt, le, lt, eq };

fn parseComparator(gpa: std.mem.Allocator, tok: []const u8) ParseError!SemverRange {
    if (tok.len == 0) return error.Invalid;
    var kind: Kind = .eq;
    var rest = tok;
    if (std.mem.startsWith(u8, rest, ">=")) {
        kind = .ge;
        rest = rest[2..];
    } else if (std.mem.startsWith(u8, rest, "<=")) {
        kind = .le;
        rest = rest[2..];
    } else if (rest[0] == '>') {
        kind = .gt;
        rest = rest[1..];
    } else if (rest[0] == '<') {
        kind = .lt;
        rest = rest[1..];
    } else if (rest[0] == '=') {
        kind = .eq;
        rest = rest[1..];
    } else if (rest[0] == '^') {
        kind = .caret;
        rest = rest[1..];
    } else if (rest[0] == '~') {
        kind = .tilde;
        rest = rest[1..];
    }
    if (rest.len == 0) return error.Invalid;
    if (isWildcard(rest)) {
        return switch (kind) {
            .eq, .ge, .caret, .tilde => .any,
            .gt => .empty,
            .le, .lt => .empty,
        };
    }

    // Parse a partial version: digits|x for each of up to 3 components.
    var nums: [3]?u64 = .{ null, null, null };
    var suffix: []const u8 = "";
    {
        var body = rest;
        // Split off pre-release/build suffix only after the numeric part.
        var i: usize = 0;
        while (i < body.len and body[i] != '-' and body[i] != '+') i += 1;
        if (i < body.len) {
            suffix = body[i..];
            body = body[0..i];
        }
        var it = std.mem.splitScalar(u8, body, '.');
        var n: usize = 0;
        while (it.next()) |seg| {
            if (n >= 3) return error.Invalid;
            if (isWildcard(seg)) break;
            nums[n] = std.fmt.parseInt(u64, seg, 10) catch return error.Invalid;
            n += 1;
        }
        // A wildcard must terminate the partial.
        if (it.next() != null) return error.Invalid;
        if (n == 0) return error.Invalid;
    }

    // Full version with suffix: only valid when all three components present.
    if (suffix.len != 0 and nums[2] == null) return error.Invalid;

    const ver = SemanticVersion{
        .major = nums[0] orelse 0,
        .minor = nums[1] orelse 0,
        .patch = nums[2] orelse 0,
    };
    const with_suffix = suffix.len != 0;

    switch (kind) {
        .eq => {
            if (nums[1] == null) return upperBump(gpa, ver, .major);
            if (nums[2] == null) return upperBump(gpa, ver, .minor);
            if (with_suffix) {
                const exact = SemanticVersion.parse(rest) catch return error.Invalid;
                return SemverRange.singleton(gpa, exact);
            }
            return SemverRange.singleton(gpa, ver);
        },
        .ge, .gt, .le, .lt => {
            if (with_suffix) {
                const exact = SemanticVersion.parse(rest) catch return error.Invalid;
                return boundRange(gpa, kind, exact);
            }
            // Comparators over partials compare against the full partial
            // value or its next upper bound.
            return switch (kind) {
                .ge => boundRange(gpa, .ge, ver),
                .gt => if (nums[2] == null)
                    // >1.2 means >=1.3.0
                    aboveBump(gpa, ver, if (nums[1] == null) .major else .minor)
                else
                    boundRange(gpa, .gt, ver),
                .le => if (nums[2] == null)
                    // <=1.2 means <1.3.0
                    upperBumpExcl(gpa, ver, if (nums[1] == null) .major else .minor)
                else
                    boundRange(gpa, .le, ver),
                .lt => boundRange(gpa, .lt, ver),
                else => unreachable,
            };
        },
        .caret, .tilde => {
            if (with_suffix) return error.Invalid;
            const lvl: Bump = switch (kind) {
                .caret => blk: {
                    if (ver.major != 0) break :blk .major;
                    if (nums[1] == null or ver.minor != 0) break :blk .minor;
                    break :blk .patch;
                },
                .tilde => if (nums[1] == null) .major else .minor,
                else => unreachable,
            };
            const lo = ver;
            var hi_v = ver;
            switch (lvl) {
                .major => {
                    hi_v.major += 1;
                    hi_v.minor = 0;
                    hi_v.patch = 0;
                },
                .minor => {
                    hi_v.minor += 1;
                    hi_v.patch = 0;
                },
                .patch => {
                    hi_v.patch += 1;
                },
            }
            return SemverRange.between(gpa, lo, true, hi_v, false);
        },
    }
    unreachable;
}

const Bump = enum { major, minor, patch };

/// `[ver, ver + bump)` — used for partial equality like `1.2` meaning
/// `>=1.2.0 <1.3.0`.
fn upperBump(gpa: std.mem.Allocator, ver: SemanticVersion, bump: Bump) ParseError!SemverRange {
    var hi = ver;
    switch (bump) {
        .major => {
            hi.major += 1;
            hi.minor = 0;
            hi.patch = 0;
        },
        .minor => {
            hi.minor += 1;
            hi.patch = 0;
        },
        .patch => hi.patch += 1,
    }
    return SemverRange.between(gpa, ver, true, hi, false);
}

/// `[ver + bump, +inf)` — used for `>1.2`-style partials.
fn aboveBump(gpa: std.mem.Allocator, ver: SemanticVersion, bump: Bump) ParseError!SemverRange {
    var lo = ver;
    switch (bump) {
        .major => {
            lo.major += 1;
            lo.minor = 0;
            lo.patch = 0;
        },
        .minor => {
            lo.minor += 1;
            lo.patch = 0;
        },
        .patch => lo.patch += 1,
    }
    return SemverRange.between(gpa, lo, true, null, true);
}

/// `(-inf, ver + bump)` — used for `<=1.2`-style partials.
fn upperBumpExcl(gpa: std.mem.Allocator, ver: SemanticVersion, bump: Bump) ParseError!SemverRange {
    var hi = ver;
    switch (bump) {
        .major => {
            hi.major += 1;
            hi.minor = 0;
            hi.patch = 0;
        },
        .minor => {
            hi.minor += 1;
            hi.patch = 0;
        },
        .patch => hi.patch += 1,
    }
    return SemverRange.between(gpa, null, true, hi, false);
}

fn boundRange(gpa: std.mem.Allocator, kind: Kind, bound: SemanticVersion) ParseError!SemverRange {
    return switch (kind) {
        .ge => SemverRange.between(gpa, bound, true, null, true),
        .gt => SemverRange.between(gpa, bound, false, null, true),
        .le => SemverRange.between(gpa, null, true, bound, true),
        .lt => SemverRange.between(gpa, null, true, bound, false),
        else => unreachable,
    };
}

fn isWildcard(s: []const u8) bool {
    return s.len == 1 and (s[0] == 'x' or s[0] == 'X' or s[0] == '*');
}

// --------------------------------------------------------------------------
// Tests
// --------------------------------------------------------------------------

const T = std.testing;

fn p(text: []const u8) !SemverRange {
    return parse(T.allocator, text);
}

fn v(text: []const u8) SemanticVersion {
    return SemanticVersion.parse(text) catch unreachable;
}

test "parse wildcard" {
    try T.expect((try p("*")).isAny());
    try T.expect((try p("x")).isAny());
    try T.expect((try p("1.x")).eql(try p(">=1.0.0 <2.0.0")));
    try T.expect((try p("1.2.x")).eql(try p(">=1.2.0 <1.3.0")));
}

test "parse exact and partial" {
    const r = try p("1.2.3");
    try T.expect(r.contains(v("1.2.3")));
    try T.expect(!r.contains(v("1.2.4")));
    const part = try p("1.2");
    try T.expect(part.contains(v("1.2.0")));
    try T.expect(part.contains(v("1.2.9")));
    try T.expect(!part.contains(v("1.3.0")));
}

test "parse comparators" {
    const r = try p(">=1.0.0 <2.0.0");
    try T.expect(r.contains(v("1.0.0")));
    try T.expect(r.contains(v("1.9.9")));
    try T.expect(!r.contains(v("2.0.0")));
    try T.expect(!r.contains(v("0.9.9")));
    const gt = try p(">1.2.3");
    try T.expect(!gt.contains(v("1.2.3")));
    try T.expect(gt.contains(v("1.2.4")));
    const le = try p("<=1.2.3");
    try T.expect(le.contains(v("1.2.3")));
    try T.expect(!le.contains(v("1.2.4")));
    const gt_part = try p(">1.2");
    try T.expect(!gt_part.contains(v("1.2.9")));
    try T.expect(gt_part.contains(v("1.3.0")));
    const le_part = try p("<=1.2");
    try T.expect(le_part.contains(v("1.2.9")));
    try T.expect(!le_part.contains(v("1.3.0")));
}

test "parse caret" {
    const r = try p("^1.2.3");
    try T.expect(r.contains(v("1.2.3")));
    try T.expect(r.contains(v("1.9.9")));
    try T.expect(!r.contains(v("2.0.0")));
    try T.expect(!r.contains(v("1.2.2")));
    const z = try p("^0.2.3");
    try T.expect(z.contains(v("0.2.9")));
    try T.expect(!z.contains(v("0.3.0")));
    const zz = try p("^0.0.3");
    try T.expect(!zz.contains(v("0.0.4")));
}

test "parse tilde" {
    const r = try p("~1.2.3");
    try T.expect(r.contains(v("1.2.9")));
    try T.expect(!r.contains(v("1.3.0")));
    const t = try p("~1");
    try T.expect(t.contains(v("1.9.9")));
    try T.expect(!t.contains(v("2.0.0")));
}

test "parse union" {
    const r = try p("<1.0.0 || >=2.0.0");
    try T.expect(r.contains(v("0.9.0")));
    try T.expect(!r.contains(v("1.5.0")));
    try T.expect(r.contains(v("2.0.0")));
}

test "parse prerelease bound" {
    const r = try p(">=1.0.0-alpha");
    try T.expect(r.contains(v("1.0.0-alpha")));
    try T.expect(r.contains(v("1.0.0")));
    const exact = try p("=1.0.0-alpha.1");
    try T.expect(exact.contains(v("1.0.0-alpha.1")));
    try T.expect(!exact.contains(v("1.0.0-alpha.2")));
}

test "parse errors" {
    try T.expectError(error.Invalid, parse(T.allocator, ""));
    try T.expectError(error.Invalid, parse(T.allocator, "1.2.3.4"));
    try T.expectError(error.Invalid, parse(T.allocator, ">="));
    try T.expectError(error.Invalid, parse(T.allocator, "a.b.c"));
    try T.expectError(error.Invalid, parse(T.allocator, "1.2.3|2.0.0"));
}

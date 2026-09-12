const std = @import("std");

pub const SemanticVersion = @import("version.zig").SemanticVersion;
pub const Range = @import("range.zig").Range;
pub const Term = @import("term.zig").Term;
pub const Relation = @import("term.zig").Relation;
pub const Solver = @import("solver.zig").Solver;
/// Parses npm/cargo-style requirement strings into `Range(SemanticVersion)`.
pub const parseVersionReq = @import("semver_range.zig").parse;

/// A package identifier for `[]const u8` names — the common case for
/// registry-based ecosystems. Satisfies the package interface required by
/// `Solver`.
pub const StringPackage = struct {
    name: []const u8,

    pub fn eql(a: StringPackage, b: StringPackage) bool {
        return std.mem.eql(u8, a.name, b.name);
    }

    pub fn hash(p: StringPackage) u64 {
        return std.hash_map.hashString(p.name);
    }

    pub fn lessThan(a: StringPackage, b: StringPackage) bool {
        return std.mem.order(u8, a.name, b.name) == .lt;
    }

    pub fn format(p: StringPackage, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(p.name);
    }
};

/// `Solver` specialized to string package names and semantic versions.
pub const SemverSolver = Solver(StringPackage, SemanticVersion);

test {
    _ = @import("version.zig");
    _ = @import("range.zig");
    _ = @import("term.zig");
    _ = @import("semver_range.zig");
    _ = @import("solver.zig");
    _ = @import("report.zig");
}

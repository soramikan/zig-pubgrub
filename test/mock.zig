const std = @import("std");
const pubgrub = @import("pubgrub");

const Allocator = std.mem.Allocator;
const S = pubgrub.SemverSolver;
const Pkg = pubgrub.StringPackage;
const V = pubgrub.SemanticVersion;
const R = S.R;

/// An in-memory registry for tests and examples.
pub const Mock = struct {
    pub const Dep = struct {
        name: []const u8,
        req: []const u8, // parsed via pubgrub.parseVersionReq
    };
    pub const Ver = struct {
        version: []const u8,
        deps: []const Dep = &.{},
        /// When set, the version exists but cannot be selected.
        unavailable: ?[]const u8 = null,
    };
    pub const Package = struct {
        name: []const u8,
        /// When null, the package is absent from the registry entirely
        /// (listVersions → error.PackageNotFound).
        versions: ?[]const Ver = &.{},
    };
    pub const Locked = struct { name: []const u8, version: []const u8 };

    pkgs: []const Package,
    locked: []const Locked = &.{},

    /// Optional failure injected into dependency fetches.
    dep_error: ?anyerror = null,

    /// Package versions whose dependency metadata cannot be read
    /// (`dependencies` → error.PackageNotFound).
    bad_versions: []const Locked = &.{},

    fn findPkg(self: *const Mock, name: []const u8) ?*const Package {
        for (self.pkgs) |*p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    pub fn listVersions(self: *const Mock, gpa: Allocator, p: Pkg) ![]V {
        const entry = self.findPkg(p.name) orelse return error.PackageNotFound;
        const vers = entry.versions orelse return error.PackageNotFound;
        const out = try gpa.alloc(V, vers.len);
        for (vers, 0..) |ver, i| out[i] = try V.parse(ver.version);
        return out;
    }

    pub fn dependencies(self: *const Mock, gpa: Allocator, p: Pkg, version: V) !S.DepResult {
        if (self.dep_error) |e| return e;
        for (self.bad_versions) |bv| {
            if (!std.mem.eql(u8, bv.name, p.name)) continue;
            const bad = V.parse(bv.version) catch continue;
            if (V.cmp(bad, version) == .eq) return error.PackageNotFound;
        }
        const entry = self.findPkg(p.name) orelse return error.PackageNotFound;
        const vers = entry.versions orelse return error.PackageNotFound;
        for (vers) |ver| {
            const pv = try V.parse(ver.version);
            if (V.cmp(pv, version) != .eq) continue;
            if (ver.unavailable) |reason| return .{ .unavailable = reason };
            const deps = try gpa.alloc(S.Dependency, ver.deps.len);
            for (ver.deps, 0..) |d, i| {
                deps[i] = .{
                    .package = .{ .name = d.name },
                    .constraint = try pubgrub.parseVersionReq(gpa, d.req),
                };
            }
            return .{ .known = deps };
        }
        return error.PackageNotFound;
    }

    pub fn lockedVersion(self: *const Mock, p: Pkg) ?V {
        for (self.locked) |l| {
            if (std.mem.eql(u8, l.name, p.name))
                return V.parse(l.version) catch null;
        }
        return null;
    }
};

pub fn named(name: []const u8) Pkg {
    return .{ .name = name };
}

pub fn v(text: []const u8) V {
    return V.parse(text) catch unreachable;
}

pub fn dep(gpa: Allocator, name: []const u8, req: []const u8) S.Dependency {
    return .{
        .package = .{ .name = name },
        .constraint = pubgrub.parseVersionReq(gpa, req) catch unreachable,
    };
}

/// Solve `root` 0.0.0 with the given root dependencies. All allocations
/// (including `dep` constraints and the returned `Outcome`) must come from
/// an arena that outlives the result.
pub fn solve(
    gpa: Allocator,
    mock: *const Mock,
    root_deps: []const S.Dependency,
    opts: S.Options,
) !S.Outcome {
    return S.solve(gpa, mock, named("root"), v("0.0.0"), root_deps, opts);
}

pub fn expectResolved(out: *S.Outcome) []const S.Selection {
    switch (out.result) {
        .resolved => |r| return r.selections,
        .failed => |f| {
            std.debug.print("unexpected failure:\n{s}\n", .{f.message});
            unreachable;
        },
    }
}

pub fn expectFailed(out: *S.Outcome) []const u8 {
    switch (out.result) {
        .failed => |f| return f.message,
        .resolved => |r| {
            std.debug.print("unexpected resolution ({d} selections)\n", .{r.selections.len});
            unreachable;
        },
    }
}

/// Look up the selected version of a package, or null when unselected.
pub fn selected(selections: []const S.Selection, name: []const u8) ?V {
    for (selections) |s| {
        if (std.mem.eql(u8, s.package.name, name)) return s.version;
    }
    return null;
}

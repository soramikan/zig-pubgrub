const std = @import("std");
const pubgrub = @import("pubgrub");
const mock = @import("mock.zig");

const T = std.testing;
const S = pubgrub.SemverSolver;
const Mock = mock.Mock;
const V = pubgrub.SemanticVersion;

/// Brute-force oracle: for small random registries, enumerate every
/// (subset × version) combination and compare "a valid assignment exists"
/// against the solver's verdict; when the solver resolves, verify the
/// selection truly satisfies all dependency constraints.
const Req = struct {
    dep_name: usize,
    constraint: S.R,
};
const GenVer = struct {
    deps: []const Req,
    unavailable: bool,
};

fn randomRegistry(gpa: std.mem.Allocator, rng: std.Random, n_pkgs: usize, max_vers: usize) !struct {
    mock_pkgs: []Mock.Package,
    /// [pkg][ver] → dependency list (as parsed constraints).
    deps: [][]const []const Req,
    unavailable: [][]const bool,
    versions: [][]const V,
} {
    const versions = try gpa.alloc([]const V, n_pkgs);
    const deps = try gpa.alloc([]const []const Req, n_pkgs);
    const unavailable = try gpa.alloc([]const bool, n_pkgs);
    const mock_pkgs = try gpa.alloc(Mock.Package, n_pkgs);
    const names = try gpa.alloc([]const u8, n_pkgs);
    for (names, 0..) |*n, i| n.* = try std.fmt.allocPrint(gpa, "p{d}", .{i});

    for (0..n_pkgs) |p| {
        const nv = 1 + rng.uintLessThan(usize, max_vers);
        const vers = try gpa.alloc(V, nv);
        const vdeps = try gpa.alloc([]const Req, nv);
        const vunav = try gpa.alloc(bool, nv);
        const mock_vers = try gpa.alloc(Mock.Ver, nv);
        for (0..nv) |vi| {
            vers[vi] = .{ .major = 0, .minor = @intCast(vi + 1), .patch = 0 };
            // Random deps: each other package with ~35% probability.
            var list: std.ArrayList(Req) = .empty;
            var mock_deps: std.ArrayList(Mock.Dep) = .empty;
            for (0..n_pkgs) |d| {
                if (d == p) continue;
                if (rng.float(f32) >= 0.35) continue;
                const target = rng.uintLessThan(usize, nv);
                const tv = vers[target];
                const req_str = switch (rng.uintLessThan(u8, 4)) {
                    0 => try std.fmt.allocPrint(gpa, "*", .{}),
                    1 => try std.fmt.allocPrint(gpa, ">=0.{d}.0", .{vi + 1 -| rng.uintLessThan(usize, vi + 1)}),
                    2 => try std.fmt.allocPrint(gpa, "<0.{d}.0", .{tv.minor}),
                    3 => try std.fmt.allocPrint(gpa, "0.{d}.0", .{tv.minor}),
                    else => unreachable,
                };
                // `<0.1.0` is unsatisfiable (versions start at 0.1.0) — that's
                // fine and intentionally exercised.
                try list.append(gpa, .{
                    .dep_name = d,
                    .constraint = try pubgrub.parseVersionReq(gpa, req_str),
                });
                try mock_deps.append(gpa, .{ .name = names[d], .req = req_str });
            }
            vdeps[vi] = list.items;
            vunav[vi] = rng.float(f32) < 0.08;
            mock_vers[vi] = .{
                .version = try std.fmt.allocPrint(gpa, "0.{d}.0", .{vi + 1}),
                .deps = mock_deps.items,
                .unavailable = if (vunav[vi]) "generated-unavailable" else null,
            };
        }
        versions[p] = vers;
        deps[p] = vdeps;
        unavailable[p] = vunav;
        mock_pkgs[p] = .{ .name = names[p], .versions = mock_vers };
    }
    return .{
        .mock_pkgs = mock_pkgs,
        .deps = deps,
        .unavailable = unavailable,
        .versions = versions,
    };
}

/// Whether `combo[dep]` (selected version index, or null) satisfies `req`.
fn satisfied(combo: []const ?usize, versions: [][]const V, req: Req) bool {
    const sel = combo[req.dep_name] orelse return false;
    return req.constraint.contains(versions[req.dep_name][sel]);
}

/// Enumerate all subset×version combinations; return true iff some
/// combination satisfies every selected package's deps and all root deps.
fn bruteForceExists(
    gpa: std.mem.Allocator,
    n: usize,
    versions: [][]const V,
    deps: [][]const []const Req,
    unavailable: [][]const bool,
    root_reqs: []const Req,
) !bool {
    const combo = try gpa.alloc(?usize, n);
    defer gpa.free(combo);

    // Iterate over subsets by bitmask, then versions per package.
    const total_subsets = @as(usize, 1) << @intCast(n);
    var mask: usize = 0;
    while (mask < total_subsets) : (mask += 1) {
        // Version-space size for this subset.
        var space: usize = 1;
        var any = false;
        for (0..n) |p| {
            if (mask & (@as(usize, 1) << @intCast(p)) == 0) continue;
            any = true;
            var avail: usize = 0;
            for (unavailable[p]) |u| {
                if (!u) avail += 1;
            }
            if (avail == 0) {
                space = 0;
                break;
            }
            space *= avail;
        }
        if (!any or space == 0) continue;

        var i: usize = 0;
        outer: while (i < space) : (i += 1) {
            // Decode `i` into per-package available-version indices.
            var rem = i;
            for (0..n) |p| {
                if (mask & (@as(usize, 1) << @intCast(p)) == 0) {
                    combo[p] = null;
                    continue;
                }
                var avail: std.ArrayList(usize) = .empty;
                for (unavailable[p], 0..) |u, vi| {
                    if (!u) try avail.append(gpa, vi);
                }
                defer avail.deinit(gpa);
                combo[p] = avail.items[rem % avail.items.len];
                rem /= avail.items.len;
            }
            // Check root deps and every selected package's deps.
            for (root_reqs) |r| {
                if (!satisfied(combo, versions, r)) continue :outer;
            }
            for (0..n) |p| {
                const sel = combo[p] orelse continue;
                for (deps[p][sel]) |r| {
                    if (!satisfied(combo, versions, r)) continue :outer;
                }
            }
            return true;
        }
    }
    return false;
}

/// Verify a solver selection satisfies the registry's constraints.
fn verifySelection(
    selections: []const S.Selection,
    versions: [][]const V,
    deps: [][]const []const Req,
    unavailable: [][]const bool,
    root_reqs: []const Req,
) !void {
    // Index selection by package.
    var by_pkg = std.AutoHashMap(usize, V).init(std.heap.page_allocator);
    defer by_pkg.deinit();
    for (selections) |s| {
        const name = s.package.name;
        if (name.len >= 2 and name[0] == 'p') {
            const idx = try std.fmt.parseInt(usize, name[1..], 10);
            try by_pkg.put(idx, s.version);
        }
    }
    // Root deps.
    for (root_reqs) |r| {
        const sv = by_pkg.get(r.dep_name) orelse return error.MissingPackage;
        try T.expect(r.constraint.contains(sv));
    }
    // Every selected package's deps.
    for (selections) |s| {
        const name = s.package.name;
        if (name.len < 2 or name[0] != 'p') continue; // root
        const p = try std.fmt.parseInt(usize, name[1..], 10);
        var vi: ?usize = null;
        for (versions[p], 0..) |ver, k| {
            if (V.cmp(ver, s.version) == .eq) vi = k;
        }
        const idx = vi orelse return error.SelectedUnlisted;
        try T.expect(!unavailable[p][idx]);
        for (deps[p][idx]) |r| {
            const sv = by_pkg.get(r.dep_name) orelse return error.MissingDep;
            try T.expect(r.constraint.contains(sv));
        }
    }
}

const verbose = false;

test "oracle: solver verdict matches brute force on random small graphs" {
    var a = std.heap.ArenaAllocator.init(T.allocator);
    defer a.deinit();
    const gpa = a.allocator();

    var rng = std.Random.DefaultPrng.init(0xC0FFEE);
    const r = rng.random();

    var case: usize = 0;
    while (case < 120) : (case += 1) {
        const n_pkgs = 2 + r.uintLessThan(usize, 4); // 2..5 packages
        const max_vers = 1 + r.uintLessThan(usize, 3); // 1..3 versions each
        const reg = try randomRegistry(gpa, r, n_pkgs, max_vers);
        const registry = Mock{ .pkgs = reg.mock_pkgs };

        // Root deps: 1..n_pkgs random package constraints.
        const n_root = 1 + r.uintLessThan(usize, n_pkgs);
        var root_reqs: std.ArrayList(Req) = .empty;
        var root_deps: std.ArrayList(S.Dependency) = .empty;
        var used = std.AutoHashMap(usize, void).init(gpa);
        for (0..n_root) |_| {
            const d = r.uintLessThan(usize, n_pkgs);
            if (used.contains(d)) continue;
            try used.put(d, {});
            const req_str = switch (r.uintLessThan(u8, 3)) {
                0 => "*",
                1 => ">=0.1.0",
                else => "<0.2.0",
            };
            const c = try pubgrub.parseVersionReq(gpa, req_str);
            try root_reqs.append(gpa, .{ .dep_name = d, .constraint = c });
            try root_deps.append(gpa, .{
                .package = .{ .name = reg.mock_pkgs[d].name },
                .constraint = c,
            });
        }

        if (verbose) std.debug.print("case {d} (n={d} mv={d} root={d})\n", .{ case, n_pkgs, max_vers, root_deps.items.len });
        var out = try mock.solve(gpa, &registry, root_deps.items, .{});
        defer out.deinit();

        const exists = try bruteForceExists(
            gpa,
            n_pkgs,
            reg.versions,
            reg.deps,
            reg.unavailable,
            root_reqs.items,
        );

        switch (out.result) {
            .resolved => |res| {
                if (!exists) {
                    std.debug.print("case {d}: solver resolved but oracle says UNSAT\n", .{case});
                    return error.TestUnexpectedResult;
                }
                try verifySelection(
                    res.selections,
                    reg.versions,
                    reg.deps,
                    reg.unavailable,
                    root_reqs.items,
                );
            },
            .failed => |f| {
                if (exists) {
                    std.debug.print("case {d}: solver failed but oracle found a solution\n{s}\n", .{ case, f.message });
                    return error.TestUnexpectedResult;
                }
            },
        }
    }
}

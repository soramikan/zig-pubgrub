const std = @import("std");
const pubgrub = @import("pubgrub");
const mock = @import("mock.zig");

const T = std.testing;
const S = pubgrub.SemverSolver;
const Mock = mock.Mock;

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(T.allocator);
}

test "simple chain resolves to latest" {
    var a = arena();
    defer a.deinit();
    const gpa = a.allocator();

    const registry = Mock{
        .pkgs = &.{
            .{ .name = "a", .versions = &.{
                .{ .version = "1.0.0", .deps = &.{.{ .name = "b", .req = "^1.0.0" }} },
                .{ .version = "1.1.0", .deps = &.{.{ .name = "b", .req = "^1.0.0" }} },
            } },
            .{ .name = "b", .versions = &.{
                .{ .version = "1.0.0" },
                .{ .version = "1.5.0" },
            } },
        },
    };
    const deps = [_]S.Dependency{mock.dep(gpa, "a", "*")};
    var out = try mock.solve(gpa, &registry, &deps, .{});
    defer out.deinit();
    const sel = mock.expectResolved(&out);
    try T.expectEqual(v("1.1.0"), mock.selected(sel, "a").?);
    try T.expectEqual(v("1.5.0"), mock.selected(sel, "b").?);
    try T.expectEqual(v("0.0.0"), mock.selected(sel, "root").?);
}

fn v(text: []const u8) pubgrub.SemanticVersion {
    return mock.v(text);
}

test "diamond dependency resolves shared version once" {
    var a = arena();
    defer a.deinit();
    const gpa = a.allocator();
    const registry = Mock{
        .pkgs = &.{
            .{ .name = "left", .versions = &.{
                .{ .version = "1.0.0", .deps = &.{.{ .name = "shared", .req = ">=1.0.0 <2.0.0" }} },
            } },
            .{ .name = "right", .versions = &.{
                .{ .version = "1.0.0", .deps = &.{.{ .name = "shared", .req = ">=1.2.0" }} },
            } },
            .{ .name = "shared", .versions = &.{
                .{ .version = "1.0.0" },
                .{ .version = "1.3.0" },
                .{ .version = "2.0.0" },
            } },
        },
    };
    const deps = [_]S.Dependency{
        mock.dep(gpa, "left", "*"),
        mock.dep(gpa, "right", "*"),
    };
    var out = try mock.solve(gpa, &registry, &deps, .{});
    defer out.deinit();
    const sel = mock.expectResolved(&out);
    // Intersection: >=1.2.0 <2.0.0 → 1.3.0.
    try T.expectEqual(v("1.3.0"), mock.selected(sel, "shared").?);
}

test "conflict produces explanation naming the chain" {
    var a = arena();
    defer a.deinit();
    const gpa = a.allocator();
    const registry = Mock{
        .pkgs = &.{
            .{ .name = "new", .versions = &.{
                .{ .version = "2.0.0", .deps = &.{.{ .name = "dep", .req = ">=2.0.0" }} },
            } },
            .{ .name = "old", .versions = &.{
                .{ .version = "1.0.0", .deps = &.{.{ .name = "dep", .req = "<2.0.0" }} },
            } },
            .{ .name = "dep", .versions = &.{
                .{ .version = "1.0.0" },
                .{ .version = "2.0.0" },
            } },
        },
    };
    const deps = [_]S.Dependency{
        mock.dep(gpa, "new", "*"),
        mock.dep(gpa, "old", "*"),
    };
    var out = try mock.solve(gpa, &registry, &deps, .{});
    defer out.deinit();
    const msg = mock.expectFailed(&out);
    // The explanation must mention the conflicting chain end-to-end.
    try T.expect(std.mem.indexOf(u8, msg, "version solving failed") != null);
    try T.expect(std.mem.indexOf(u8, msg, "new") != null);
    try T.expect(std.mem.indexOf(u8, msg, "old") != null);
    try T.expect(std.mem.indexOf(u8, msg, "dep") != null);
}

test "backtracking: newest version's conflict is retried with older" {
    var a = arena();
    defer a.deinit();
    const gpa = a.allocator();
    const registry = Mock{
        .pkgs = &.{
            .{
                .name = "foo",
                .versions = &.{
                    .{ .version = "1.0.0" }, // no deps — fallback works
                    .{ .version = "2.0.0", .deps = &.{.{ .name = "baz", .req = ">=2.0.0" }} },
                },
            },
            .{
                .name = "baz",
                .versions = &.{
                    .{ .version = "1.0.0" }, // no 2.0.0 exists
                },
            },
        },
    };
    const deps = [_]S.Dependency{mock.dep(gpa, "foo", "*")};
    var out = try mock.solve(gpa, &registry, &deps, .{});
    defer out.deinit();
    const sel = mock.expectResolved(&out);
    try T.expectEqual(v("1.0.0"), mock.selected(sel, "foo").?);
    try T.expectEqual(@as(?pubgrub.SemanticVersion, null), mock.selected(sel, "baz"));
}

test "cyclic dependencies resolve" {
    var a = arena();
    defer a.deinit();
    const gpa = a.allocator();
    const registry = Mock{
        .pkgs = &.{
            .{ .name = "a", .versions = &.{
                .{ .version = "1.0.0", .deps = &.{.{ .name = "b", .req = "^1.0.0" }} },
            } },
            .{ .name = "b", .versions = &.{
                .{ .version = "1.0.0", .deps = &.{.{ .name = "a", .req = "^1.0.0" }} },
            } },
        },
    };
    const deps = [_]S.Dependency{mock.dep(gpa, "a", "*")};
    var out = try mock.solve(gpa, &registry, &deps, .{});
    defer out.deinit();
    const sel = mock.expectResolved(&out);
    try T.expectEqual(v("1.0.0"), mock.selected(sel, "a").?);
    try T.expectEqual(v("1.0.0"), mock.selected(sel, "b").?);
}

test "root-level conflict: dependency on missing package" {
    var a = arena();
    defer a.deinit();
    const gpa = a.allocator();
    const registry = Mock{
        .pkgs = &.{
            .{ .name = "ghost", .versions = null },
        },
    };
    const deps = [_]S.Dependency{mock.dep(gpa, "ghost", "*")};
    var out = try mock.solve(gpa, &registry, &deps, .{});
    defer out.deinit();
    const msg = mock.expectFailed(&out);
    try T.expect(std.mem.indexOf(u8, msg, "ghost") != null);
    try T.expect(std.mem.indexOf(u8, msg, "doesn't exist") != null);
}

test "locked version is preferred over newer" {
    var a = arena();
    defer a.deinit();
    const gpa = a.allocator();
    const registry = Mock{
        .pkgs = &.{
            .{ .name = "lib", .versions = &.{
                .{ .version = "1.0.0" },
                .{ .version = "2.0.0" },
            } },
        },
        .locked = &.{.{ .name = "lib", .version = "1.0.0" }},
    };
    const deps = [_]S.Dependency{mock.dep(gpa, "lib", "*")};
    var out = try mock.solve(gpa, &registry, &deps, .{});
    defer out.deinit();
    const sel = mock.expectResolved(&out);
    try T.expectEqual(v("1.0.0"), mock.selected(sel, "lib").?);
}

test "locked version outside constraint is ignored" {
    var a = arena();
    defer a.deinit();
    const gpa = a.allocator();
    const registry = Mock{
        .pkgs = &.{
            .{ .name = "lib", .versions = &.{
                .{ .version = "1.0.0" },
                .{ .version = "2.0.0" },
            } },
        },
        .locked = &.{.{ .name = "lib", .version = "1.0.0" }},
    };
    const deps = [_]S.Dependency{mock.dep(gpa, "lib", ">=2.0.0")};
    var out = try mock.solve(gpa, &registry, &deps, .{});
    defer out.deinit();
    const sel = mock.expectResolved(&out);
    try T.expectEqual(v("2.0.0"), mock.selected(sel, "lib").?);
}

test "repeated runs produce identical results" {
    var a = arena();
    defer a.deinit();
    const gpa = a.allocator();
    const registry = Mock{
        .pkgs = &.{
            .{ .name = "a", .versions = &.{
                .{ .version = "1.0.0", .deps = &.{.{ .name = "c", .req = "^1.0.0" }} },
                .{ .version = "2.0.0", .deps = &.{.{ .name = "c", .req = "^1.0.0" }} },
            } },
            .{ .name = "b", .versions = &.{
                .{ .version = "1.0.0", .deps = &.{.{ .name = "c", .req = "<1.5.0" }} },
            } },
            .{ .name = "c", .versions = &.{
                .{ .version = "1.0.0" },
                .{ .version = "1.4.0" },
                .{ .version = "1.6.0" },
            } },
        },
    };
    const deps = [_]S.Dependency{
        mock.dep(gpa, "a", "*"),
        mock.dep(gpa, "b", "*"),
    };

    var first: ?[]const S.Selection = null;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var out = try mock.solve(gpa, &registry, &deps, .{});
        defer out.deinit();
        const sel = mock.expectResolved(&out);
        if (first) |f| {
            try T.expectEqualSlices(S.Selection, f, sel);
        } else {
            first = try T.allocator.dupe(S.Selection, sel);
        }
    }
    T.allocator.free(first.?);
}

test "unavailable versions are skipped" {
    var a = arena();
    defer a.deinit();
    const gpa = a.allocator();
    const registry = Mock{
        .pkgs = &.{
            .{ .name = "lib", .versions = &.{
                .{ .version = "1.0.0" },
                .{ .version = "2.0.0", .unavailable = "yanked: CVE-1234" },
            } },
        },
    };
    const deps = [_]S.Dependency{mock.dep(gpa, "lib", "*")};
    var out = try mock.solve(gpa, &registry, &deps, .{});
    defer out.deinit();
    const sel = mock.expectResolved(&out);
    try T.expectEqual(v("1.0.0"), mock.selected(sel, "lib").?);
}

test "all versions unavailable fails with reason" {
    var a = arena();
    defer a.deinit();
    const gpa = a.allocator();
    const registry = Mock{
        .pkgs = &.{
            .{ .name = "lib", .versions = &.{
                .{ .version = "1.0.0", .unavailable = "broken manifest" },
            } },
        },
    };
    const deps = [_]S.Dependency{mock.dep(gpa, "lib", "*")};
    var out = try mock.solve(gpa, &registry, &deps, .{});
    defer out.deinit();
    const msg = mock.expectFailed(&out);
    try T.expect(std.mem.indexOf(u8, msg, "version solving failed") != null);
}

test "extra forbidden constraint forces older version" {
    var a = arena();
    defer a.deinit();
    const gpa = a.allocator();
    const registry = Mock{
        .pkgs = &.{
            .{ .name = "lib", .versions = &.{
                .{ .version = "1.0.0" },
                .{ .version = "2.0.0" },
            } },
        },
    };
    const deps = [_]S.Dependency{mock.dep(gpa, "lib", "*")};
    const forbid = [_]S.ExtraConstraint{.{
        .package = mock.named("lib"),
        .constraint = try pubgrub.parseVersionReq(gpa, ">=2.0.0"),
        .require = false,
        .reason = "lib >=2 is banned by policy",
    }};
    var out = try mock.solve(gpa, &registry, &deps, .{ .constraints = &forbid });
    defer out.deinit();
    const sel = mock.expectResolved(&out);
    try T.expectEqual(v("1.0.0"), mock.selected(sel, "lib").?);
}

test "extra required constraint narrows reachable package" {
    var a = arena();
    defer a.deinit();
    const gpa = a.allocator();
    const registry = Mock{
        .pkgs = &.{
            .{ .name = "tool", .versions = &.{
                .{ .version = "2.0.0" },
                .{ .version = "3.1.0" },
                .{ .version = "4.0.0" },
            } },
        },
    };
    const deps = [_]S.Dependency{mock.dep(gpa, "tool", "*")};
    const req = [_]S.ExtraConstraint{.{
        .package = mock.named("tool"),
        .constraint = try pubgrub.parseVersionReq(gpa, "^3.0.0"),
        .require = true,
        .reason = "toolchain pin",
    }};
    var out = try mock.solve(gpa, &registry, &deps, .{ .constraints = &req });
    defer out.deinit();
    const sel = mock.expectResolved(&out);
    try T.expectEqual(v("3.1.0"), mock.selected(sel, "tool").?);
}

test "extra required constraint conflict shows reason" {
    var a = arena();
    defer a.deinit();
    const gpa = a.allocator();
    const registry = Mock{
        .pkgs = &.{
            .{ .name = "tool", .versions = &.{
                .{ .version = "2.0.0" },
            } },
        },
    };
    const deps = [_]S.Dependency{mock.dep(gpa, "tool", "*")};
    const req = [_]S.ExtraConstraint{.{
        .package = mock.named("tool"),
        .constraint = try pubgrub.parseVersionReq(gpa, "^3.0.0"),
        .require = true,
        .reason = "toolchain pin says >=3",
    }};
    var out = try mock.solve(gpa, &registry, &deps, .{ .constraints = &req });
    defer out.deinit();
    const msg = mock.expectFailed(&out);
    try T.expect(std.mem.indexOf(u8, msg, "version solving failed") != null);
}

test "prefer_oldest picks minimal versions" {
    var a = arena();
    defer a.deinit();
    const gpa = a.allocator();
    const registry = Mock{
        .pkgs = &.{
            .{ .name = "lib", .versions = &.{
                .{ .version = "1.0.0" },
                .{ .version = "1.5.0" },
                .{ .version = "2.0.0" },
            } },
        },
    };
    const deps = [_]S.Dependency{mock.dep(gpa, "lib", "*")};
    var out = try mock.solve(gpa, &registry, &deps, .{ .prefer_oldest = true });
    defer out.deinit();
    const sel = mock.expectResolved(&out);
    try T.expectEqual(v("1.0.0"), mock.selected(sel, "lib").?);
}

test "prerelease only selected when no release matches" {
    var a = arena();
    defer a.deinit();
    const gpa = a.allocator();
    const registry = Mock{
        .pkgs = &.{
            .{ .name = "lib", .versions = &.{
                .{ .version = "1.0.0" },
                .{ .version = "2.0.0-alpha" },
            } },
        },
    };
    // Constraint admits both; release must win.
    const deps = [_]S.Dependency{mock.dep(gpa, "lib", "*")};
    var out = try mock.solve(gpa, &registry, &deps, .{});
    defer out.deinit();
    try T.expectEqual(v("1.0.0"), mock.selected(mock.expectResolved(&out), "lib").?);

    // Constraint admits only the prerelease.
    const deps2 = [_]S.Dependency{mock.dep(gpa, "lib", ">=2.0.0-alpha")};
    var out2 = try mock.solve(gpa, &registry, &deps2, .{});
    defer out2.deinit();
    try T.expectEqual(v("2.0.0-alpha"), mock.selected(mock.expectResolved(&out2), "lib").?);
}

test "deep backtracking over multiple decision levels" {
    var a = arena();
    defer a.deinit();
    const gpa = a.allocator();
    // root → top any. top 2 → mid ^2, mid 2 → leaf >=9 (no such version).
    // top 1 → mid ^1, mid 1 → leaf ^1 (exists).
    const registry = Mock{
        .pkgs = &.{
            .{ .name = "top", .versions = &.{
                .{ .version = "1.0.0", .deps = &.{.{ .name = "mid", .req = "^1.0.0" }} },
                .{ .version = "2.0.0", .deps = &.{.{ .name = "mid", .req = "^2.0.0" }} },
            } },
            .{ .name = "mid", .versions = &.{
                .{ .version = "1.0.0", .deps = &.{.{ .name = "leaf", .req = "^1.0.0" }} },
                .{ .version = "2.0.0", .deps = &.{.{ .name = "leaf", .req = ">=9.0.0" }} },
            } },
            .{ .name = "leaf", .versions = &.{
                .{ .version = "1.0.0" },
            } },
        },
    };
    const deps = [_]S.Dependency{mock.dep(gpa, "top", "*")};
    var out = try mock.solve(gpa, &registry, &deps, .{});
    defer out.deinit();
    const sel = mock.expectResolved(&out);
    try T.expectEqual(v("1.0.0"), mock.selected(sel, "top").?);
    try T.expectEqual(v("1.0.0"), mock.selected(sel, "mid").?);
    try T.expectEqual(v("1.0.0"), mock.selected(sel, "leaf").?);
    try T.expect(out.attempted_solutions >= 2);
}

test "conflict explanation is deterministic" {
    var a = arena();
    defer a.deinit();
    const gpa = a.allocator();
    const registry = Mock{
        .pkgs = &.{
            .{ .name = "a", .versions = &.{
                .{ .version = "1.0.0", .deps = &.{.{ .name = "c", .req = ">=2.0.0" }} },
            } },
            .{ .name = "b", .versions = &.{
                .{ .version = "1.0.0", .deps = &.{.{ .name = "c", .req = "<2.0.0" }} },
            } },
            .{ .name = "c", .versions = &.{
                .{ .version = "1.0.0" },
                .{ .version = "2.0.0" },
            } },
        },
    };
    const deps = [_]S.Dependency{
        mock.dep(gpa, "a", "*"),
        mock.dep(gpa, "b", "*"),
    };
    var first: ?[]const u8 = null;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var out = try mock.solve(gpa, &registry, &deps, .{});
        defer out.deinit();
        const msg = mock.expectFailed(&out);
        if (first) |f| {
            try T.expectEqualStrings(f, msg);
        } else {
            first = try T.allocator.dupe(u8, msg);
        }
    }
    T.allocator.free(first.?);
}

test "provider errors propagate" {
    var a = arena();
    defer a.deinit();
    const gpa = a.allocator();
    const registry = Mock{
        .pkgs = &.{
            .{ .name = "lib", .versions = &.{.{ .version = "1.0.0" }} },
        },
        .dep_error = error.ConnectionFailed,
    };
    const deps = [_]S.Dependency{mock.dep(gpa, "lib", "*")};
    try T.expectError(
        error.ConnectionFailed,
        mock.solve(gpa, &registry, &deps, .{}),
    );
}

// Regression: a small contradictory graph once sent conflict resolution into
// an unbounded merge loop. p2 needs p1, p1 needs p0 <0.1.0, but root pins
// p0 >=0.1.0 and only p0 0.1.0 exists — the solver must report failure.
test "conflict through mutually dependent packages terminates" {
    var a = arena();
    defer a.deinit();
    const gpa = a.allocator();
    const registry = Mock{
        .pkgs = &.{
            .{ .name = "p0", .versions = &.{.{ .version = "0.1.0" }} },
            .{ .name = "p1", .versions = &.{
                .{ .version = "0.1.0", .deps = &.{
                    .{ .name = "p0", .req = "<0.1.0" },
                    .{ .name = "p2", .req = "*" },
                } },
            } },
            .{ .name = "p2", .versions = &.{
                .{ .version = "0.1.0", .deps = &.{
                    .{ .name = "p0", .req = "*" },
                    .{ .name = "p1", .req = "*" },
                } },
            } },
        },
    };
    const deps = [_]S.Dependency{
        mock.dep(gpa, "p2", "*"),
        mock.dep(gpa, "p0", ">=0.1.0"),
    };
    var out = try mock.solve(gpa, &registry, &deps, .{});
    defer out.deinit();
    const msg = mock.expectFailed(&out);
    try T.expect(std.mem.indexOf(u8, msg, "p0 <0.1.0") != null);
    try T.expect(std.mem.indexOf(u8, msg, "version solving failed") != null);
}

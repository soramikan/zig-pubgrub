const std = @import("std");
const pubgrub = @import("pubgrub");

const S = pubgrub.SemverSolver;
const V = pubgrub.SemanticVersion;
const Pkg = pubgrub.StringPackage;

// A tiny static registry.
const Registry = struct {
    const Entry = struct {
        name: []const u8,
        version: []const u8,
        deps: []const Dep,
    };
    const Dep = struct { name: []const u8, req: []const u8 };

    entries: []const Entry,

    pub fn listVersions(self: *const Registry, gpa: std.mem.Allocator, pkg: Pkg) ![]V {
        var out: std.ArrayList(V) = .empty;
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.name, pkg.name))
                try out.append(gpa, try V.parse(e.version));
        }
        if (out.items.len == 0) return error.PackageNotFound;
        return out.items;
    }

    pub fn dependencies(self: *const Registry, gpa: std.mem.Allocator, pkg: Pkg, version: V) !S.DepResult {
        for (self.entries) |e| {
            if (!std.mem.eql(u8, e.name, pkg.name)) continue;
            if (V.cmp(try V.parse(e.version), version) != .eq) continue;
            const deps = try gpa.alloc(S.Dependency, e.deps.len);
            for (e.deps, 0..) |d, i| {
                deps[i] = .{
                    .package = .{ .name = d.name },
                    .constraint = try pubgrub.parseVersionReq(gpa, d.req),
                };
            }
            return .{ .known = deps };
        }
        return error.PackageNotFound;
    }
};

const registry = Registry{
    .entries = &.{
        .{ .name = "app", .version = "1.0.0", .deps = &.{
            .{ .name = "ui", .req = "^2.0.0" },
            .{ .name = "store", .req = "*" },
        } },
        .{ .name = "ui", .version = "2.0.0", .deps = &.{
            .{ .name = "gfx", .req = ">=1.5.0" },
        } },
        .{ .name = "ui", .version = "2.1.0", .deps = &.{
            .{ .name = "gfx", .req = ">=1.5.0 <2.0.0" },
        } },
        .{ .name = "store", .version = "1.0.0", .deps = &.{
            .{ .name = "gfx", .req = "<1.6.0" },
        } },
        .{ .name = "store", .version = "1.1.0", .deps = &.{
            .{ .name = "gfx", .req = ">=1.4.0 <2.0.0" },
        } },
        .{ .name = "gfx", .version = "1.4.0", .deps = &.{} },
        .{ .name = "gfx", .version = "1.5.0", .deps = &.{} },
        .{ .name = "gfx", .version = "1.6.0", .deps = &.{} },
        .{ .name = "gfx", .version = "2.0.0", .deps = &.{} },
    },
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const root_deps = [_]S.Dependency{
        .{ .package = .{ .name = "app" }, .constraint = try pubgrub.parseVersionReq(gpa, "^1.0.0") },
    };

    var out = try S.solve(gpa, &registry, .{ .name = "my-project" }, try V.parse("1.0.0"), &root_deps, .{});
    defer out.deinit();

    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    const stdout = &w.interface;
    switch (out.result) {
        .resolved => |r| {
            try stdout.print("resolved ({d} packages):\n", .{r.selections.len});
            for (r.selections) |s| try stdout.print("  {f} {f}\n", .{ s.package, s.version });
        },
        .failed => |f| try stdout.print("failed:\n{s}\n", .{f.message}),
    }
    try stdout.flush();
}

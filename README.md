# zig-pubgrub

[日本語版はこちら](README.ja.md)

A [PubGrub](https://github.com/dart-lang/pub/tree/main/doc/solver.md) version
solver for Zig, generic over package and version types. Ported from Dart pub's
reference implementation: unit propagation, conflict-driven learning with
backjumping, and human-readable conflict explanations derived from the
incompatibility derivation graph.

Published as a standalone, reusable library.

## Features

- **Deterministic resolution** — identical inputs always produce identical
  selections.
- **Conflict explanations** — on failure, produces an explanation traceable
  from the root requirements to the conflict (e.g. "Because every version of
  p2 depends on p1 * which depends on p0 <0.1.0, ...").
- **Lockfile preference** — versions recorded in an existing lockfile are
  preferred whenever allowed.
- **Generic** — the solver is parameterized over package identifier and
  version types; a semantic-version implementation is included.
- **Provider-separated** — package metadata (version lists, dependencies,
  unavailable markers) is supplied through a user-implemented provider, so
  the solver works with registries, filesystems, git, or anything else.
- **Adjacent-version collapsing** — runs of versions sharing a dependency are
  collapsed into a single depender range, like pub's `PackageLister`.

## Usage

Fetch the package into a `build.zig.zon` dependency, then:

```zig
const std = @import("std");
const pubgrub = @import("pubgrub");

const S = pubgrub.SemverSolver;      // Solver(StringPackage, SemanticVersion)
const V = pubgrub.SemanticVersion;

const Provider = struct {
    pub fn listVersions(self: *const Provider, gpa: std.mem.Allocator, pkg: pubgrub.StringPackage) ![]const V {
        // Return every known version of `pkg`, in any order.
        // Return error.PackageNotFound when the package does not exist.
    }

    pub fn dependencies(self: *const Provider, gpa: std.mem.Allocator, pkg: pubgrub.StringPackage, version: V) !S.DepResult {
        // .{ .known = deps } or .{ .unavailable = "reason or null" }
    }

    // Optional: prefer a version already recorded in a lockfile.
    pub fn lockedVersion(self: *const Provider, pkg: pubgrub.StringPackage) ?V {
        return null;
    }
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const root_deps = [_]S.Dependency{
        .{ .package = .{ .name = "app" }, .constraint = try pubgrub.parseVersionReq(gpa, "^1.0.0") },
    };

    const provider = Provider{};
    var out = try S.solve(gpa, &provider, .{ .name = "my-project" }, try V.parse("1.0.0"), &root_deps, .{});
    defer out.deinit();

    switch (out.result) {
        .resolved => |r| for (r.selections) |s| {
            std.debug.print("{f} {f}\n", .{ s.package, s.version });
        },
        .failed => |f| std.debug.print("{s}\n", .{f.message}),
    }
}
```

See `examples/resolve_demo.zig` for a complete runnable provider
(`zig build example`).

### Provider contract

- `listVersions(gpa, package) ![]const V` — every known version; may return
  `error.PackageNotFound`, which becomes a solver conflict rather than a
  hard error. Other errors abort the solve.
- `dependencies(gpa, package, version) !DepResult` — `.known` dependency
  edges or `.unavailable` (yanked/broken/incompatible) with an optional
  human-readable reason.
- `lockedVersion(package) ?V` *(optional)* — a version already recorded in a
  lockfile; preferred whenever the accumulated constraint allows it.

All allocators passed to provider methods are arenas that outlive the solve;
providers must not free memory backing returned values.

### Options

- `prefer_oldest` — pick the oldest matching versions (downgrade semantics).
- `constraints` — extra external requirements: `require` forces a version in
  the constraint to be selected (when the package is otherwise selected);
  `!require` forbids every matching version. Each may carry a `reason` that
  appears as a hint in failure reports.

### Custom package and version types

`Solver(P, V)` is generic. `P` must provide `eql`, `hash`, and `format`
(and optionally `lessThan`/`cmp` for deterministic dependency ordering).
`V` must provide `cmp` (a total order) and `format` (and optionally
`isPrerelease` for prerelease deprioritization).

## Version requirements

`pubgrub.parseVersionReq` parses semver requirement strings:

| Syntax | Meaning |
| --- | --- |
| `1.2.3`, `=1.2.3` | exact version |
| `>=1.2.0 <2.0.0` | intersection of comparisons |
| `1.2`, `1` | partial versions (`>=1.2.0 <1.3.0`, `>=1.0.0 <2.0.0`) |
| `*`, `1.x`, `1.2.*` | wildcards |
| `^1.2.3` | compatible (`>=1.2.3 <2.0.0`) |
| `~1.2.3` | patch-level (`>=1.2.3 <1.3.0`) |
| `>=1.0.0 <2.0.0 \|\| >=3.0.0` | union |

Prereleases are not implicitly excluded; explicit bounds control whether they
are selected (and they are always deprioritized in favor of releases).

## Testing

```sh
zig build test       # unit + integration + randomized brute-force oracle
zig build fmt-check  # zig fmt --check
zig build example    # run the demo resolver
```

The oracle test compares the solver's verdict against exhaustive brute-force
enumeration on 120 randomly generated small registries.

## License

MIT

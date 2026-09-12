const std = @import("std");
const range_mod = @import("range.zig");
const term_mod = @import("term.zig");
const report_mod = @import("report.zig");

const Allocator = std.mem.Allocator;

/// A PubGrub version solver, generic over the package identifier type `P` and
/// the version type `V`.
///
/// `P` must provide:
///   - `pub fn eql(a: P, b: P) bool`
///   - `pub fn hash(p: P) u64`
///   - `pub fn format(p: P, w: *std.Io.Writer) std.Io.Writer.Error!void`
///   - optionally `pub fn lessThan(a: P, b: P) bool` — used to canonicalize
///     the order dependency incompatibilities are emitted in
///
/// `V` must provide:
///   - `pub fn cmp(a: V, b: V) std.math.Order` — a total order
///   - `pub fn format(v: V, w: *std.Io.Writer) std.Io.Writer.Error!void`
///   - optionally `pub fn isPrerelease(v: V) bool` — when present, release
///     versions are preferred over pre-releases during decision making
///
/// The metadata source is supplied per solve as a provider value (usually a
/// pointer) implementing:
///   - `fn listVersions(self, gpa, package: P) ![]V` — every selectable
///     version, in any order. `error.PackageNotFound` produces a
///     "doesn't exist" conflict instead of aborting the solve.
///   - `fn dependencies(self, gpa, package: P, version: V) !DepResult` —
///     `.known` dependencies, or `.unavailable` with an optional reason.
///   - optionally `fn lockedVersion(self, package: P) ?V` — a version recorded
///     in an existing lockfile; it is preferred whenever it is allowed.
///
/// Allocators handed to provider methods are arenas that outlive the solve;
/// providers must not free memory backing returned values.
pub fn Solver(comptime P: type, comptime V: type) type {
    return struct {
        const Self = @This();

        pub const Package = P;
        pub const Version = V;
        pub const R = range_mod.Range(V);
        pub const T = term_mod.Term(V);
        pub const Relation = term_mod.Relation;

        /// A dependency edge: `package` constrained to `constraint`.
        pub const Dependency = struct {
            package: P,
            constraint: R,
        };

        /// What a provider knows about a concrete package version.
        pub const DepResult = union(enum) {
            known: []const Dependency,
            /// The version cannot be selected (yanked, incompatible SDK bound,
            /// broken manifest, ...). `reason` is shown to users when set.
            unavailable: ?[]const u8,
        };

        /// An additional external constraint injected into the solve.
        pub const ExtraConstraint = struct {
            package: P,
            constraint: R,
            /// `true` forces a version in `constraint` to be selected;
            /// `false` forbids every version in `constraint`.
            require: bool,
            /// Optional human-readable explanation appended to a failure
            /// report.
            reason: ?[]const u8 = null,
        };

        pub const Options = struct {
            /// Prefer the oldest matching versions instead of the newest
            /// (downgrade semantics).
            prefer_oldest: bool = false,
            /// Extra incompatibilities added before solving begins.
            constraints: []const ExtraConstraint = &.{},
        };

        pub const Selection = struct {
            package: P,
            version: V,
        };

        /// The outcome of `solve`; owns all memory via an internal arena.
        pub const Outcome = struct {
            arena: std.heap.ArenaAllocator,
            result: union(enum) {
                /// A selected version for every package reachable from root,
                /// including the root itself, ordered by decision.
                resolved: struct { selections: []const Selection },
                /// Version solving failed. `message` is a human-readable
                /// explanation of the conflict derivation; the derivation
                /// graph is kept in `store` for programmatic inspection.
                failed: struct {
                    message: []const u8,
                    root_incompatibility: u32,
                    store: []const Incompatibility,
                },
            },
            /// How many candidate solutions were attempted.
            attempted_solutions: u32,

            pub fn deinit(self: *Outcome) void {
                self.arena.deinit();
                self.* = undefined;
            }
        };

        // ------------------------------------------------------------------
        // Terms, incompatibilities, assignments
        // ------------------------------------------------------------------

        pub const TermEntry = struct {
            package: P,
            term: T,
        };

        /// Why an incompatibility exists. `derived` causes point to the two
        /// parent incompatibilities (by index into the store) from which the
        /// incompatibility was obtained during conflict resolution.
        pub const Cause = union(enum) {
            /// `{not root v}` — the requirement that root exists.
            root,
            /// `{depender +, dependee -}` — a dependency edge.
            dependency,
            /// `{p +}` — no listed version matched the accumulated term.
            no_versions,
            /// `{p * +}` — the package could not be listed at all.
            not_found,
            /// `{p r +}` — forbidden by an external constraint.
            forbidden: ?[]const u8,
            /// `{not p r}` — required by an external constraint.
            required: ?[]const u8,
            /// `{p r +}` — the provider marked these versions unavailable.
            unavailable: ?[]const u8,
            /// Derived during conflict resolution.
            derived: struct { conflict: u32, other: u32 },
        };

        pub const Incompatibility = struct {
            /// Normalized: at most one term per package, first-seen order.
            terms: []const TermEntry,
            cause: Cause,
            /// Whether this incompatibility participates in propagation.
            /// Derived intermediate incompatibilities exist only as nodes of
            /// the derivation graph.
            indexed: bool = false,

            /// Whether this incompatibility means solving has failed: empty,
            /// or a single term referring to the root package.
            pub fn isFailure(self: Incompatibility, root: P) bool {
                return self.terms.len == 0 or
                    (self.terms.len == 1 and P.eql(self.terms[0].package, root));
            }
        };

        const Assignment = struct {
            package: P,
            term: T,
            /// `cause == null` marks a decision (a concrete version pick); the
            /// term is then `positive(singleton(version))`.
            cause: ?u32,
            decision_level: u32,

            fn version(self: Assignment) V {
                return self.term.positive.intervals[0].low.v.?;
            }
        };

        fn pkgMap(comptime Val: type) type {
            return std.HashMap(P, Val, struct {
                pub fn hash(_: @This(), k: P) u64 {
                    return k.hash();
                }
                pub fn eql(_: @This(), a: P, b: P) bool {
                    return a.eql(b);
                }
            }, std.hash_map.default_max_load_percentage);
        }

        // ------------------------------------------------------------------
        // Partial solution
        // ------------------------------------------------------------------

        const PartialSolution = struct {
            assignments: std.ArrayList(Assignment) = .empty,
            /// Package → decided version.
            decisions: pkgMap(V),
            /// Package → intersection of all its assignments, when that
            /// intersection is (or became) positive.
            positive: pkgMap(T),
            /// Package → union of its negative assignments, while it has no
            /// positive assignment.
            negative: pkgMap(T),
            /// Packages in `positive`, in the order they first became positive.
            positive_order: std.ArrayList(P) = .empty,

            fn init(gpa: Allocator) PartialSolution {
                return .{
                    .decisions = pkgMap(V).init(gpa),
                    .positive = pkgMap(T).init(gpa),
                    .negative = pkgMap(T).init(gpa),
                };
            }

            fn decisionLevel(self: *const PartialSolution) u32 {
                return @intCast(self.decisions.count());
            }

            /// The earliest assignment index making `term` satisfied.
            /// Caller must only query satisfied terms.
            fn satisfier(self: *const PartialSolution, gpa: Allocator, package: P, term: T) !usize {
                var acc: ?T = null;
                for (self.assignments.items, 0..) |a, i| {
                    if (!P.eql(a.package, package)) continue;
                    acc = if (acc) |x| try x.intersect(a.term, gpa) else a.term;
                    if (acc.?.relation(term) == .subset) return i;
                }
                unreachable;
            }

            fn relation(self: *const PartialSolution, package: P, term: T) Relation {
                if (self.positive.get(package)) |pos| return pos.relation(term);
                if (self.negative.get(package)) |neg| return neg.relation(term);
                return .overlapping;
            }

            fn satisfies(self: *const PartialSolution, package: P, term: T) bool {
                return self.relation(package, term) == .subset;
            }

            fn decide(self: *PartialSolution, gpa: Allocator, package: P, version: V) !void {
                const r = try R.singleton(gpa, version);
                try self.decisions.put(package, version);
                try self.push(gpa, .{
                    .package = package,
                    .term = .{ .positive = r },
                    .cause = null,
                    .decision_level = self.decisionLevel(),
                });
            }

            fn derive(self: *PartialSolution, gpa: Allocator, package: P, term: T, cause: u32) !void {
                try self.push(gpa, .{
                    .package = package,
                    .term = term,
                    .cause = cause,
                    .decision_level = self.decisionLevel(),
                });
            }

            fn push(self: *PartialSolution, gpa: Allocator, a: Assignment) !void {
                try self.assignments.append(gpa, a);
                try self.register(gpa, a);
            }

            fn register(self: *PartialSolution, gpa: Allocator, a: Assignment) !void {
                if (self.positive.getPtr(a.package)) |pos| {
                    pos.* = try pos.intersect(a.term, gpa);
                    return;
                }
                const merged = if (self.negative.get(a.package)) |neg|
                    try neg.intersect(a.term, gpa)
                else
                    a.term;
                if (merged == .positive) {
                    _ = self.negative.remove(a.package);
                    try self.positive.put(a.package, merged);
                    try self.positive_order.append(gpa, a.package);
                } else {
                    try self.negative.put(a.package, merged);
                }
            }

            /// Remove every assignment with `decision_level > level`, then
            /// rebuild the per-package aggregates of the survivors.
            fn backtrack(self: *PartialSolution, gpa: Allocator, level: u32) !void {
                var affected: std.ArrayList(P) = .empty;
                while (self.assignments.items.len > 0 and
                    self.assignments.items[self.assignments.items.len - 1].decision_level > level)
                {
                    const removed = self.assignments.pop().?;
                    if (removed.cause == null) _ = self.decisions.remove(removed.package);
                    if (indexOfPkg(affected.items, removed.package) == null)
                        try affected.append(gpa, removed.package);
                }
                for (affected.items) |pkg| {
                    _ = self.positive.remove(pkg);
                    _ = self.negative.remove(pkg);
                    if (indexOfPkg(self.positive_order.items, pkg)) |i|
                        _ = self.positive_order.orderedRemove(i);
                }
                for (self.assignments.items) |a| {
                    if (indexOfPkg(affected.items, a.package) != null) try self.register(gpa, a);
                }
            }

            fn indexOfPkg(items: []const P, pkg: P) ?usize {
                for (items, 0..) |x, i| if (P.eql(x, pkg)) return i;
                return null;
            }
        };

        // ------------------------------------------------------------------
        // Per-package version lister (lazy dependency → incompatibility)
        // ------------------------------------------------------------------

        const Lister = struct {
            pkg: P,
            is_root: bool = false,
            locked: ?V = null,
            root_deps: []const Dependency = &.{},
            root_emitted: bool = false,

            versions_fetched: bool = false,
            versions: []const V = &.{},
            not_found: bool = false,

            /// Dependency results cached parallel to `versions`.
            deps_cache: std.ArrayList(?DepResult) = .empty,
            /// Cache for a `version` absent from `versions` (e.g. locked).
            extra_deps: ?DepResult = null,
            extra_deps_version: ?V = null,

            /// Union of ranges already reported unavailable.
            known_invalid: R = .empty,
            /// Dependency name → union of depender ranges already emitted.
            already_listed: pkgMap(R),

            fn init(gpa: Allocator, pkg: P) Lister {
                return .{ .pkg = pkg, .already_listed = pkgMap(R).init(gpa) };
            }
        };

        // ------------------------------------------------------------------
        // Solve session, generic over the provider type
        // ------------------------------------------------------------------

        fn Session(comptime PT: type) type {
            return struct {
                const Sess = @This();

                gpa: Allocator, // arena — lives until Outcome.deinit
                provider: PT,
                root: P,
                root_version: V,
                opts: Options,

                solution: PartialSolution,
                store: std.ArrayList(Incompatibility) = .empty,
                /// Package → indices into `store`, insertion-ordered.
                index: pkgMap(std.ArrayList(u32)),
                listers: pkgMap(*Lister),
                attempted_solutions: u32 = 1,
                backtracking: bool = false,
                /// Set when conflict resolution proves failure.
                failure: ?u32 = null,

                const Reporter = report_mod.Reporter(Incompatibility);

                fn init(
                    gpa: Allocator,
                    provider: PT,
                    root: P,
                    root_version: V,
                    root_deps: []const Dependency,
                    opts: Options,
                ) !Sess {
                    var s = Sess{
                        .gpa = gpa,
                        .provider = provider,
                        .root = root,
                        .root_version = root_version,
                        .opts = opts,
                        .solution = PartialSolution.init(gpa),
                        .index = pkgMap(std.ArrayList(u32)).init(gpa),
                        .listers = pkgMap(*Lister).init(gpa),
                    };
                    const root_lister = try gpa.create(Lister);
                    root_lister.* = Lister.init(gpa, root);
                    root_lister.is_root = true;
                    root_lister.locked = root_version;
                    root_lister.root_deps = root_deps;
                    try s.listers.put(root, root_lister);
                    return s;
                }

                // -- provider plumbing ---------------------------------------

                fn listVersions(self: *Sess, lister: *Lister) ![]const V {
                    if (lister.versions_fetched) {
                        if (lister.not_found) return error.PackageNotFound;
                        return lister.versions;
                    }
                    if (lister.is_root) {
                        lister.versions_fetched = true;
                        lister.versions = try self.gpa.dupe(V, &.{self.root_version});
                        try lister.deps_cache.appendNTimes(self.gpa, null, 1);
                        return lister.versions;
                    }
                    // Coerce to anyerror so providers with narrow inferred
                    // error sets still hit the `else` branch.
                    const raw_res: anyerror![]V = self.provider.listVersions(self.gpa, lister.pkg);
                    const raw = raw_res catch |e| switch (e) {
                        error.PackageNotFound => {
                            lister.versions_fetched = true;
                            lister.not_found = true;
                            return error.PackageNotFound;
                        },
                        else => return e,
                    };
                    const versions = try self.gpa.dupe(V, raw);
                    std.mem.sort(V, versions, {}, struct {
                        fn lt(_: void, a: V, b: V) bool {
                            return V.cmp(a, b) == .lt;
                        }
                    }.lt);
                    lister.versions_fetched = true;
                    lister.versions = versions;
                    try lister.deps_cache.appendNTimes(self.gpa, null, versions.len);
                    return versions;
                }

                fn getLister(self: *Sess, pkg: P) !*Lister {
                    if (self.listers.get(pkg)) |l| return l;
                    const l = try self.gpa.create(Lister);
                    l.* = Lister.init(self.gpa, pkg);
                    const C = if (@typeInfo(PT) == .pointer) std.meta.Child(PT) else PT;
                    if (comptime @hasDecl(C, "lockedVersion")) {
                        l.locked = self.provider.lockedVersion(pkg);
                    }
                    try self.listers.put(pkg, l);
                    return l;
                }

                fn depsOf(self: *Sess, lister: *Lister, version: V) !DepResult {
                    // Cache by index when the version is listed, else in the
                    // single extra slot.
                    var idx: ?usize = null;
                    if (lister.versions_fetched and !lister.not_found) {
                        for (lister.versions, 0..) |v, i| {
                            if (V.cmp(v, version) == .eq) {
                                idx = i;
                                break;
                            }
                        }
                    }
                    if (idx) |i| {
                        if (lister.deps_cache.items[i]) |cached| return cached;
                        const res: DepResult = try self.provider.dependencies(self.gpa, lister.pkg, version);
                        lister.deps_cache.items[i] = res;
                        return res;
                    }
                    if (lister.extra_deps_version) |ev| {
                        if (V.cmp(ev, version) == .eq) return lister.extra_deps.?;
                    }
                    const res: DepResult = try self.provider.dependencies(self.gpa, lister.pkg, version);
                    lister.extra_deps = res;
                    lister.extra_deps_version = version;
                    return res;
                }

                // -- top level ------------------------------------------------

                fn run(self: *Sess) !void {
                    const gpa = self.gpa;
                    // "{not root v}": the root version must be selected.
                    _ = try self.addIncompatibility(.{
                        .terms = try self.singleTerm(self.root, .{
                            .negative = try R.singleton(gpa, self.root_version),
                        }),
                        .cause = .root,
                    }, true);
                    for (self.opts.constraints) |c| {
                        const term: T = if (c.require)
                            .{ .negative = c.constraint }
                        else
                            .{ .positive = c.constraint };
                        _ = try self.addIncompatibility(.{
                            .terms = try self.singleTerm(c.package, term),
                            .cause = if (c.require)
                                .{ .required = c.reason }
                            else
                                .{ .forbidden = c.reason },
                        }, true);
                    }

                    var next: ?P = self.root;
                    while (next) |pkg| {
                        try self.propagate(pkg);
                        next = try self.choosePackageVersion();
                    }
                }

                // -- unit propagation -----------------------------------------

                fn propagate(self: *Sess, start: P) !void {
                    const gpa = self.gpa;
                    var changed: std.ArrayList(P) = .empty;
                    var in_changed = pkgMap(void).init(gpa);
                    try changed.append(gpa, start);
                    try in_changed.put(start, {});
                    var head: usize = 0;
                    while (head < changed.items.len) {
                        const pkg = changed.items[head];
                        head += 1;
                        _ = in_changed.remove(pkg);
                        const ids = self.index.get(pkg) orelse continue;
                        var i = ids.items.len;
                        // Iterate newest first: conflict resolution tends to
                        // produce more general incompatibilities over time.
                        outer: while (i > 0) {
                            i -= 1;
                            switch (try self.propagateIncompatibility(ids.items[i])) {
                                .none => {},
                                .derived => |name| {
                                    if (!in_changed.contains(name)) {
                                        try changed.append(gpa, name);
                                        try in_changed.put(name, {});
                                    }
                                },
                                .conflict => {
                                    const root_cause = try self.resolveConflict(ids.items[i]);
                                    // Guaranteed almost-satisfied after
                                    // backtracking: it must derive.
                                    const r = try self.propagateIncompatibility(root_cause);
                                    changed.clearRetainingCapacity();
                                    in_changed.clearRetainingCapacity();
                                    head = 0;
                                    switch (r) {
                                        .derived => |name| {
                                            try changed.append(gpa, name);
                                            try in_changed.put(name, {});
                                        },
                                        else => unreachable,
                                    }
                                    break :outer;
                                },
                            }
                        }
                    }
                }

                const PropResult = union(enum) {
                    none,
                    derived: P,
                    conflict,
                };

                fn propagateIncompatibility(self: *Sess, id: u32) !PropResult {
                    const incompat = self.store.items[id];
                    var unsatisfied: ?TermEntry = null;
                    for (incompat.terms) |entry| {
                        switch (self.solution.relation(entry.package, entry.term)) {
                            .disjoint => return .none,
                            .overlapping => {
                                if (unsatisfied != null) return .none;
                                unsatisfied = entry;
                            },
                            .subset => {},
                        }
                    }
                    const u = unsatisfied orelse return .conflict;
                    try self.solution.derive(self.gpa, u.package, u.term.inverse(), id);
                    return .{ .derived = u.package };
                }

                // -- conflict resolution ---------------------------------------

                fn resolveConflict(self: *Sess, start_id: u32) !u32 {
                    const gpa = self.gpa;
                    var incompat = self.store.items[start_id];
                    // Whether `incompat` was derived in this loop and is not yet
                    // present in the store.
                    var fresh = false;
                    var fresh_id: u32 = start_id;
                    while (!incompat.isFailure(self.root)) {
                        var most_recent_term_idx: usize = 0;
                        var most_recent_satisfier: usize = 0;
                        var difference: ?T = null;
                        var previous_satisfier_level: u32 = 1;

                        for (incompat.terms, 0..) |entry, ti| {
                            const s = try self.solution.satisfier(gpa, entry.package, entry.term);
                            var just_updated = false;
                            if (ti == 0) {
                                most_recent_term_idx = ti;
                                most_recent_satisfier = s;
                                just_updated = true;
                            } else if (most_recent_satisfier < s) {
                                previous_satisfier_level = @max(
                                    previous_satisfier_level,
                                    self.solution.assignments.items[most_recent_satisfier].decision_level,
                                );
                                most_recent_term_idx = ti;
                                most_recent_satisfier = s;
                                difference = null;
                                just_updated = true;
                            } else {
                                previous_satisfier_level = @max(
                                    previous_satisfier_level,
                                    self.solution.assignments.items[s].decision_level,
                                );
                            }

                            if (just_updated) {
                                const sat = self.solution.assignments.items[most_recent_satisfier];
                                difference = try sat.term.difference(entry.term, gpa);
                                if (difference) |diff| {
                                    const d = try self.solution.satisfier(
                                        gpa,
                                        entry.package,
                                        diff.inverse(),
                                    );
                                    previous_satisfier_level = @max(
                                        previous_satisfier_level,
                                        self.solution.assignments.items[d].decision_level,
                                    );
                                }
                            }
                        }

                        const satisfier_a = self.solution.assignments.items[most_recent_satisfier];
                        if (previous_satisfier_level < satisfier_a.decision_level or
                            satisfier_a.cause == null)
                        {
                            try self.solution.backtrack(gpa, previous_satisfier_level);
                            self.backtracking = true;
                            if (!fresh) return start_id;
                            return self.addIncompatibility(incompat, true);
                        }

                        var new_terms: std.ArrayList(TermEntry) = .empty;
                        for (incompat.terms, 0..) |entry, ti| {
                            if (ti != most_recent_term_idx) try new_terms.append(gpa, entry);
                        }
                        const cause_id = satisfier_a.cause.?;
                        for (self.store.items[cause_id].terms) |entry| {
                            if (!P.eql(entry.package, satisfier_a.package))
                                try new_terms.append(gpa, entry);
                        }
                        if (difference) |diff|
                            try new_terms.append(gpa, .{
                                .package = satisfier_a.package,
                                .term = diff.inverse(),
                            });

                        // The conflict side of the new derived cause must be a
                        // stored incompatibility for the derivation graph.
                        if (fresh) {
                            incompat.indexed = false;
                            fresh_id = try self.storeRaw(incompat);
                        }
                        incompat = try self.normalize(new_terms.items, .{
                            .derived = .{ .conflict = fresh_id, .other = cause_id },
                        });
                        fresh = true;
                    }
                    self.failure = try self.storeRaw(incompat);
                    return error.VersionConflict;
                }

                // -- decision making ------------------------------------------

                fn choosePackageVersion(self: *Sess) !?P {
                    const gpa = self.gpa;
                    var best_pkg: ?P = null;
                    var best_term: ?T = null;
                    var best_count: usize = std.math.maxInt(usize);
                    for (self.solution.positive_order.items) |pkg| {
                        if (self.solution.decisions.contains(pkg)) continue;
                        const term = self.solution.positive.get(pkg).?;
                        const lister = try self.getLister(pkg);
                        const n = try self.countVersions(lister, term.range());
                        if (n < best_count) {
                            best_count = n;
                            best_pkg = pkg;
                            best_term = term;
                        }
                    }
                    const pkg = best_pkg orelse return null;
                    const term = best_term.?;
                    const lister = self.listers.get(pkg).?;

                    var version: ?V = self.bestVersion(lister, term.range()) catch |e| switch (e) {
                        error.PackageNotFound => {
                            _ = try self.addIncompatibility(.{
                                .terms = try self.singleTerm(pkg, .{ .positive = .any }),
                                .cause = .not_found,
                            }, true);
                            return pkg;
                        },
                        else => return e,
                    };
                    if (version == null) {
                        // If the constraint excludes only a single version, it
                        // most likely came from inverting a lockfile
                        // dependency. Asking for any version instead gives
                        // more general incompatibilities and clearer errors.
                        const complement = try term.range().complement(gpa);
                        if (complement.isSingleton())
                            version = try self.bestVersion(lister, .any);
                    }
                    if (version == null) {
                        _ = try self.addIncompatibility(.{
                            .terms = try self.singleTerm(pkg, term),
                            .cause = .no_versions,
                        }, true);
                        return pkg;
                    }
                    const v = version.?;

                    var conflict = false;
                    for (try self.incompatibilitiesFor(lister, v)) |inc| {
                        _ = try self.addIncompatibility(inc, true);
                        var all_satisfied = true;
                        for (inc.terms) |entry| {
                            if (P.eql(entry.package, pkg)) continue;
                            if (!self.solution.satisfies(entry.package, entry.term)) {
                                all_satisfied = false;
                                break;
                            }
                        }
                        conflict = conflict or all_satisfied;
                    }
                    if (!conflict) {
                        if (self.backtracking) self.attempted_solutions += 1;
                        self.backtracking = false;
                        try self.solution.decide(gpa, pkg, v);
                    }
                    return pkg;
                }

                fn countVersions(self: *Sess, lister: *Lister, constraint: R) !usize {
                    if (lister.locked) |l| {
                        if (constraint.contains(l)) return 1;
                    }
                    const versions = self.listVersions(lister) catch return 0;
                    var n: usize = 0;
                    for (versions) |v| {
                        if (constraint.contains(v)) n += 1;
                    }
                    return n;
                }

                fn bestVersion(self: *Sess, lister: *Lister, constraint: R) !?V {
                    if (lister.locked) |l| {
                        if (constraint.contains(l)) return l;
                    }
                    const versions = try self.listVersions(lister);
                    var best_pre: ?V = null;
                    if (self.opts.prefer_oldest) {
                        for (versions) |v| {
                            if (!constraint.contains(v)) continue;
                            if (!isPrerelease(v)) return v;
                            if (best_pre == null) best_pre = v;
                        }
                    } else {
                        var i = versions.len;
                        while (i > 0) {
                            i -= 1;
                            const v = versions[i];
                            if (!constraint.contains(v)) continue;
                            if (!isPrerelease(v)) return v;
                            if (best_pre == null) best_pre = v;
                        }
                    }
                    return best_pre;
                }

                fn isPrerelease(v: V) bool {
                    if (comptime @hasDecl(V, "isPrerelease")) return V.isPrerelease(v);
                    return false;
                }

                // -- dependency → incompatibility conversion -------------------

                /// Port of pub's PackageLister.incompatibilitiesFor: collapse
                /// runs of adjacent versions sharing a dependency into a
                /// single depender range.
                fn incompatibilitiesFor(self: *Sess, lister: *Lister, v: V) ![]Incompatibility {
                    const gpa = self.gpa;
                    if (lister.known_invalid.contains(v)) return &.{};

                    if (lister.is_root) {
                        if (lister.root_emitted) return &.{};
                        lister.root_emitted = true;
                        const depender = try R.singleton(gpa, v);
                        var out: std.ArrayList(Incompatibility) = .empty;
                        for (lister.root_deps) |dep| {
                            try out.append(gpa, try self.dependencyIncompat(lister.pkg, depender, dep));
                        }
                        return out.items;
                    }

                    const versions = self.listVersions(lister) catch |e| switch (e) {
                        error.PackageNotFound => &.{},
                        else => return e,
                    };
                    const idx = indexOfVersion(versions, v);

                    const res = try self.depsOf(lister, v);
                    switch (res) {
                        .unavailable => |reason| {
                            // Collapse the contiguous run of unavailable
                            // versions around `v` into one positive term.
                            var r = try R.singleton(gpa, v);
                            if (idx) |at| {
                                const bounds = try self.unavailableBounds(lister, versions, at);
                                r = try R.between(gpa, bounds.low, true, bounds.high, false);
                            }
                            lister.known_invalid = try lister.known_invalid.unionWith(r, gpa);
                            const inc: Incompatibility = .{
                                .terms = try self.singleTerm(lister.pkg, .{ .positive = r }),
                                .cause = .{ .unavailable = reason },
                                .indexed = false,
                            };
                            const out = try gpa.alloc(Incompatibility, 1);
                            out[0] = inc;
                            return out;
                        },
                        .known => |deps| {
                            var new_deps: std.ArrayList(Dependency) = .empty;
                            for (deps) |dep| {
                                if (lister.already_listed.get(dep.package)) |r| {
                                    if (r.contains(v)) continue;
                                }
                                try new_deps.append(gpa, dep);
                            }
                            if (new_deps.items.len == 0) return &.{};

                            sortDeps(new_deps.items);

                            var out: std.ArrayList(Incompatibility) = .empty;
                            if (idx) |at| {
                                const lowers = try self.depBounds(lister, versions, at, new_deps.items, false);
                                const uppers = try self.depBounds(lister, versions, at, new_deps.items, true);
                                for (new_deps.items) |dep| {
                                    const r = try R.between(
                                        gpa,
                                        lowers.get(dep.package),
                                        true,
                                        uppers.get(dep.package),
                                        false,
                                    );
                                    const merged = if (lister.already_listed.get(dep.package)) |old|
                                        try old.unionWith(r, gpa)
                                    else
                                        r;
                                    try lister.already_listed.put(dep.package, merged);
                                    try out.append(gpa, try self.dependencyIncompat(lister.pkg, r, dep));
                                }
                            } else {
                                // Unlisted version (e.g. lockfile-only): no
                                // adjacent versions to collapse with. Record
                                // the singleton as listed so a later call does
                                // not re-emit the same incompatibilities.
                                const r = try R.singleton(gpa, v);
                                for (new_deps.items) |dep| {
                                    const merged = if (lister.already_listed.get(dep.package)) |old|
                                        try old.unionWith(r, gpa)
                                    else
                                        r;
                                    try lister.already_listed.put(dep.package, merged);
                                    try out.append(gpa, try self.dependencyIncompat(lister.pkg, r, dep));
                                }
                            }
                            return out.items;
                        },
                    }
                }

                /// Scan versions adjacent to `versions[at]` and record, per
                /// dependency, the bound where its constraint stops matching
                /// `versions[at]`'s. For `upper == false` the bound is the last
                /// matching version (inclusive); for `upper == true` it is the
                /// first non-matching version (exclusive). An absent entry
                /// means unbounded. An unavailable neighbour bounds every
                /// remaining dependency.
                fn depBounds(
                    self: *Sess,
                    lister: *Lister,
                    versions: []const V,
                    at: usize,
                    deps: []const Dependency,
                    upper: bool,
                ) !pkgMap(V) {
                    var bounds = pkgMap(V).init(self.gpa);
                    var remaining = pkgMap(void).init(self.gpa);
                    for (deps) |dep| try remaining.put(dep.package, {});
                    var prev = versions[at];
                    var i = at;
                    while (if (upper) i + 1 < versions.len else i > 0) {
                        const j = if (upper) i + 1 else i - 1;
                        const res = try self.depsOf(lister, versions[j]);
                        // The upper bound is the first different version; the
                        // lower bound is the last same version.
                        const boundary = if (upper) versions[j] else prev;
                        switch (res) {
                            .unavailable => {
                                var it = remaining.keyIterator();
                                while (it.next()) |name| try bounds.put(name.*, boundary);
                                break;
                            },
                            .known => |ds| {
                                for (deps) |dep| {
                                    if (!remaining.contains(dep.package)) continue;
                                    var same = false;
                                    for (ds) |d| {
                                        if (P.eql(d.package, dep.package)) {
                                            same = d.constraint.eql(dep.constraint);
                                            break;
                                        }
                                    }
                                    if (!same) {
                                        try bounds.put(dep.package, boundary);
                                        _ = remaining.remove(dep.package);
                                    }
                                }
                                if (remaining.count() == 0) break;
                            },
                        }
                        prev = versions[j];
                        i = j;
                    }
                    return bounds;
                }

                const Bounds = struct { low: ?V, high: ?V };

                /// Bounds of the contiguous run of `unavailable` versions
                /// around `versions[at]`: inclusive lower = first unavailable
                /// version, exclusive upper = first available one. `null` when
                /// the run reaches the respective end.
                fn unavailableBounds(self: *Sess, lister: *Lister, versions: []const V, at: usize) !Bounds {
                    var low: ?V = null;
                    var high: ?V = null;
                    var i = at;
                    while (i > 0) {
                        const res = try self.depsOf(lister, versions[i - 1]);
                        if (res != .unavailable) {
                            low = versions[i];
                            break;
                        }
                        i -= 1;
                    }
                    i = at;
                    while (i + 1 < versions.len) {
                        const res = try self.depsOf(lister, versions[i + 1]);
                        if (res != .unavailable) {
                            high = versions[i + 1];
                            break;
                        }
                        i += 1;
                    }
                    return .{ .low = low, .high = high };
                }

                fn dependencyIncompat(self: *Sess, pkg: P, depender: R, dep: Dependency) !Incompatibility {
                    const terms = try self.gpa.alloc(TermEntry, 2);
                    terms[0] = .{ .package = pkg, .term = .{ .positive = depender } };
                    terms[1] = .{ .package = dep.package, .term = .{ .negative = dep.constraint } };
                    return .{ .terms = terms, .cause = .dependency, .indexed = false };
                }

                // -- incompatibility store -------------------------------------

                /// Store + index for propagation.
                fn addIncompatibility(self: *Sess, raw: Incompatibility, indexed: bool) !u32 {
                    var incompat = try self.normalize(raw.terms, raw.cause);
                    incompat.indexed = indexed;
                    const id = try self.storeRaw(incompat);
                    if (indexed) {
                        for (incompat.terms) |entry| {
                            const gop = try self.index.getOrPut(entry.package);
                            if (!gop.found_existing) gop.value_ptr.* = .empty;
                            try gop.value_ptr.append(self.gpa, id);
                        }
                    }
                    return id;
                }

                fn storeRaw(self: *Sess, incompat: Incompatibility) !u32 {
                    const id: u32 = @intCast(self.store.items.len);
                    try self.store.append(self.gpa, incompat);
                    return id;
                }

                /// Normalize a term list: drop positive root terms (derived
                /// causes only, matching upstream pub) and coalesce multiple
                /// terms per package into their intersection, preserving
                /// first-seen package order.
                fn normalize(self: *Sess, raw: []const TermEntry, cause: Cause) !Incompatibility {
                    const gpa = self.gpa;
                    var terms: std.ArrayList(TermEntry) = .empty;
                    try terms.appendSlice(gpa, raw);

                    if (cause == .derived and terms.items.len > 1) {
                        var kept: std.ArrayList(TermEntry) = .empty;
                        for (terms.items) |e| {
                            if (e.term == .positive and P.eql(e.package, self.root)) continue;
                            try kept.append(gpa, e);
                        }
                        terms = kept;
                    }

                    // Fast paths matching upstream pub.
                    if (terms.items.len <= 1 or
                        (terms.items.len == 2 and
                            !P.eql(terms.items[0].package, terms.items[1].package)))
                    {
                        return .{ .terms = terms.items, .cause = cause, .indexed = false };
                    }

                    var merged: std.ArrayList(TermEntry) = .empty;
                    for (terms.items) |e| {
                        var found = false;
                        for (merged.items) |*m| {
                            if (P.eql(m.package, e.package)) {
                                m.term = try m.term.intersect(e.term, gpa);
                                found = true;
                                break;
                            }
                        }
                        if (!found) try merged.append(gpa, e);
                    }
                    return .{ .terms = merged.items, .cause = cause, .indexed = false };
                }

                fn singleTerm(self: *Sess, pkg: P, term: T) ![]TermEntry {
                    const t = try self.gpa.alloc(TermEntry, 1);
                    t[0] = .{ .package = pkg, .term = term };
                    return t;
                }
            };
        }

        fn indexOfVersion(versions: []const V, v: V) ?usize {
            // `versions` is sorted: binary search.
            var lo: usize = 0;
            var hi: usize = versions.len;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                switch (V.cmp(versions[mid], v)) {
                    .lt => lo = mid + 1,
                    .gt => hi = mid,
                    .eq => return mid,
                }
            }
            return null;
        }

        fn sortDeps(deps: []Dependency) void {
            const C = struct {
                fn lt(_: void, a: Dependency, b: Dependency) bool {
                    if (comptime @hasDecl(P, "lessThan")) return P.lessThan(a.package, b.package);
                    if (comptime @hasDecl(P, "cmp")) return P.cmp(a.package, b.package) == .lt;
                    return false; // keep provider order when P is unordered
                }
            };
            if (comptime @hasDecl(P, "lessThan") or @hasDecl(P, "cmp"))
                std.mem.sort(Dependency, deps, {}, C.lt);
        }

        // ------------------------------------------------------------------
        // Public entry point
        // ------------------------------------------------------------------

        /// Run version solving. `provider` is usually a pointer to the
        /// caller's metadata source; see the `Solver` docs for the interface.
        pub fn solve(
            gpa: Allocator,
            provider: anytype,
            root: P,
            root_version: V,
            root_deps: []const Dependency,
            opts: Options,
        ) !Outcome {
            const PT = @TypeOf(provider);
            comptime validateProvider(PT);

            var arena = std.heap.ArenaAllocator.init(gpa);
            errdefer arena.deinit();
            const a = arena.allocator();

            var sess = try Session(PT).init(a, provider, root, root_version, root_deps, opts);
            sess.run() catch |e| switch (e) {
                error.VersionConflict => {
                    var rep = Session(PT).Reporter{
                        .gpa = a,
                        .store = sess.store.items,
                        .root_pkg = root,
                        .failure_id = sess.failure.?,
                    };
                    const msg = try rep.write();
                    return .{
                        .arena = arena,
                        .attempted_solutions = sess.attempted_solutions,
                        .result = .{ .failed = .{
                            .message = msg,
                            .root_incompatibility = sess.failure.?,
                            .store = sess.store.items,
                        } },
                    };
                },
                else => return e,
            };

            var selections: std.ArrayList(Selection) = .empty;
            for (sess.solution.assignments.items) |asg| {
                if (asg.cause == null)
                    try selections.append(a, .{ .package = asg.package, .version = asg.version() });
            }
            return .{
                .arena = arena,
                .attempted_solutions = sess.attempted_solutions,
                .result = .{ .resolved = .{ .selections = selections.items } },
            };
        }

        fn validateProvider(comptime PT: type) void {
            const C = if (@typeInfo(PT) == .pointer) std.meta.Child(PT) else PT;
            if (!@hasDecl(C, "listVersions"))
                @compileError("provider must implement `fn listVersions(self, gpa, package) ![]Version`");
            if (!@hasDecl(C, "dependencies"))
                @compileError("provider must implement `fn dependencies(self, gpa, package, version) !DepResult`");
        }
    };
}

const std = @import("std");
const pubgrub = @import("pubgrub");

test {
    // Pull in the library's unit tests and the integration suites.
    std.testing.refAllDecls(pubgrub);
    _ = @import("solver_tests.zig");
    _ = @import("oracle_tests.zig");
}

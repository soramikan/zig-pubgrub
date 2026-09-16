const std = @import("std");
const pubgrub = @import("pubgrub");

test {
    // `refAllDecls` compiles the library declarations but does NOT execute the
    // test blocks inside a dependency module. The build runs those through a
    // separate `lib_tests` artifact rooted at `src/pubgrub.zig`.
    std.testing.refAllDecls(pubgrub);
    _ = @import("solver_tests.zig");
    _ = @import("oracle_tests.zig");
}

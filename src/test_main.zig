comptime {
    // Modules whose internal helpers carry tests (private — kept inline).
    _ = @import("config.zig");
    _ = @import("service/ws.zig");
    _ = @import("auth/gateway_login.zig");
    _ = @import("auth/portal_config.zig");

    // Pure black-box tests of public APIs.
    _ = @import("cli_test.zig");
    _ = @import("ui/state_test.zig");
    _ = @import("service/protocol_test.zig");
    _ = @import("service/lockfile_test.zig");
    _ = @import("service/client_test.zig");
    _ = @import("service/crypto_test.zig");
    _ = @import("auth/cookie_cache_test.zig");
    _ = @import("auth/gpauth_test.zig");
    _ = @import("auth/portal_config_test.zig");
}

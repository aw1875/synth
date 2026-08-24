//! An MCP client: connect to a server, ask what it offers, call it.
//!
//! Depends on `std` and nothing else. That is enforced rather than intended -
//! this is its own Zig module, and Zig refuses an `@import` of any path outside
//! a module's root directory, so a reach into the program using this would not
//! compile. Lifting the directory out into a package is adding a `build.zig`
//! and a `build.zig.zon`, with no edits to the code.
//!
//! Two protocol revisions are spoken: `2026-07-28`, which is stateless, and
//! `2025-11-25`, which is what most deployed servers still expect. Which one a
//! server gets is settled per connection.

const std = @import("std");

pub const jsonrpc = @import("jsonrpc.zig");
pub const protocol = @import("protocol.zig");
pub const Transport = @import("transport/transport.zig");
pub const Client = @import("client.zig");
pub const Auth = @import("oauth/auth.zig");
pub const Callback = @import("oauth/callback.zig");
pub const Browser = @import("oauth/browser.zig");
pub const discovery = @import("oauth/discovery.zig");
pub const registration = @import("oauth/registration.zig");
pub const flow = @import("oauth/flow.zig");

pub const Revision = protocol.Revision;
pub const Implementation = protocol.Implementation;
pub const Tool = protocol.Tool;
pub const CallResult = protocol.CallResult;
pub const ResultType = protocol.ResultType;

test {
    std.testing.refAllDecls(@This());
}

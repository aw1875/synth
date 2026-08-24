//! The seam every MCP transport plugs into, and the one place that names them.
//!
//! One wire shape, several backends: the stdio child process every test uses,
//! and the Streamable HTTP transport that talks to a remote server behind
//! OAuth. `Client` only sees this struct; the differences - a child process
//! versus a `std.http.Client`, a framed stream versus POST/response - are
//! hidden behind `send`, `receive`, and `deinit`.
//!
//! `receive` returns a borrowed slice. It points into the transport's own
//! storage and is only valid until the next call, which is the contract stdio
//! has always had. A caller that needs to keep a message copies it.
//!
//! ## Vtable shape
//!
//! Each concrete backend - `Stdio`, `Http` - is a plain struct that knows
//! nothing about the others. It embeds a `Transport` at a known offset inside
//! itself; the erased fn pointers receive `*Transport` and recover the parent
//! via `@fieldParentPtr`. This matches the `std.Io.Reader` pattern: the
//! userdata is the `*Transport` itself, not a second opaque field.
//!
//! `start` is the only place that switches on which backend is wanted, and
//! `deinit` goes back out through the vtable, so nothing above this file ever
//! holds a concrete transport pointer. That is why there is no union over the
//! backends: it would be a second erasure of the same thing, and a second
//! allocation to free alongside this one.

const std = @import("std");

const Http = @import("http.zig");
const Stdio = @import("stdio.zig");

const Transport = @This();

pub const Error = error{
    /// The transport closed its side of the wire. For stdio that means the
    /// child process exited; for HTTP it means the stream ended before a reply
    /// arrived. Either way, no further calls can be made.
    ServerClosed,
    /// A single message ran past the transport's maximum size. Almost always a
    /// broken peer rather than a big one.
    MessageTooLong,
    /// The transport could not be reached at all: DNS, TLS, connect, or a
    /// request that never got as far as a status line.
    ConnectionFailed,
    /// The server demands credentials this transport does not have, or the
    /// ones it has are no longer good. `Http.challenge` carries what the
    /// server said to do about it.
    Unauthorized,
    /// The server refused the request itself - a 4xx that is not a 401. For a
    /// probe this means "not this way", which is worth trying differently; for
    /// anything else it is the server saying no.
    RequestRejected,
    /// The server failed to handle the request - a 5xx.
    ServerError,
    /// A reply arrived with a status this transport does not know how to
    /// interpret.
    UnexpectedStatus,
    /// A reply arrived in a content type MCP does not define over this wire.
    UnsupportedResponse,
};

/// Which wire a server is on.
pub const Kind = enum { stdio, http };

/// What a caller hands to `start` to describe which wire to use and how to set
/// it up. The tag names the variant; each variant carries the configuration
/// that backend needs.
pub const Options = union(Kind) {
    stdio: Stdio.Options,
    http: Http.Options,
};

/// Where a stdio server's own logging goes. Aliased here so callers naming it
/// in a config struct do not have to reach past the seam for it.
pub const Stderr = Stdio.Stderr;

vtable: *const VTable,

pub const VTable = struct {
    /// Send one framed message.
    send: *const fn (self: *Transport, message: []const u8) Error!void,
    /// Block until one framed message arrives, then return a slice into the
    /// transport's own storage, valid until the next call.
    receive: *const fn (self: *Transport) Error![]const u8,
    /// Release whatever the transport holds, including the concrete struct
    /// this `Transport` is embedded in. Safe to call once; calling it twice is
    /// a use-after-free.
    deinit: *const fn (self: *Transport) void,
    /// Replace the credentials sent with each request, for a transport that
    /// has any. Null on transports where authorization is not a concept, which
    /// is how `setBearer` answers whether it did anything.
    set_bearer: ?*const fn (self: *Transport, token: ?[]const u8) std.mem.Allocator.Error!void = null,
    /// What the server said when it last refused for want of credentials.
    /// Null on transports that cannot be refused that way.
    challenge: ?*const fn (self: *Transport) []const u8 = null,
    /// Name the protocol revision in force on each request. Null on transports
    /// with nowhere to put it.
    set_protocol_version: ?*const fn (self: *Transport, version: []const u8) std.mem.Allocator.Error!void = null,
};

/// Start the chosen backend and return the seam into it. The concrete
/// transports are heap-allocated - their buffers and their embedded vtable
/// pointer must outlive this call - and `deinit` frees them.
pub fn start(allocator: std.mem.Allocator, io: std.Io, options: Options) !*Transport {
    switch (options) {
        .stdio => |stdio| return &(try Stdio.start(allocator, io, stdio)).transport,
        .http => |http| return &(try Http.start(allocator, io, http)).transport,
    }
}

/// Send one framed message. Forwards through the vtable; the `*Transport`
/// itself is what the erased fn uses to recover the concrete backend.
pub fn send(self: *Transport, message: []const u8) Error!void {
    return self.vtable.send(self, message);
}

/// Block until one framed message arrives.
pub fn receive(self: *Transport) Error![]const u8 {
    return self.vtable.receive(self);
}

/// Release whatever the transport holds.
pub fn deinit(self: *Transport) void {
    self.vtable.deinit(self);
}

/// Replace the bearer token sent with each request. Returns false on a
/// transport with no notion of credentials, so a caller refreshing an expired
/// token can tell "nothing to do here" from "done".
/// What the server said the last time it answered `Unauthorized`, or empty
/// when it has not. This is where RFC 9728 puts the pointer to the metadata an
/// OAuth flow starts from.
pub fn challenge(self: *Transport) []const u8 {
    const read = self.vtable.challenge orelse return "";
    return read(self);
}

pub fn setBearer(self: *Transport, token: ?[]const u8) std.mem.Allocator.Error!bool {
    const set = self.vtable.set_bearer orelse return false;
    try set(self, token);
    return true;
}

/// Name the revision both ends settled on, so every later request carries it.
/// False on a transport that has no headers to carry it in - stdio settles the
/// version in the handshake and never mentions it again.
pub fn setProtocolVersion(self: *Transport, version: []const u8) std.mem.Allocator.Error!bool {
    const set = self.vtable.set_protocol_version orelse return false;
    try set(self, version);
    return true;
}

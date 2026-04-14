//! Proxy command — manage HTTP/HTTPS proxy for downloads.
//! Allows users to set a proxy URL (e.g., http://127.0.0.1:7890) for all
//! network operations. When set to empty/default, zvm auto-detects proxy
//! from environment variables (http_proxy, https_proxy).

const std = @import("std");
const zvm_mod = @import("zvm.zig");

/// Set or display the HTTP/HTTPS proxy.
/// "default" clears the proxy (auto-detect from env vars).
/// With no argument, displays the current proxy setting.
pub fn run(
    zvm: *zvm_mod.ZVM,
    allocator: std.mem.Allocator,
    url: ?[]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    _ = stderr;

    if (url) |u| {
        if (std.mem.eql(u8, u, "default")) {
            try zvm.settings.setProxy(allocator, "");
            try stdout.print("Reset proxy to auto-detect (from environment).\n", .{});
        } else {
            try zvm.settings.setProxy(allocator, u);
            try stdout.print("Set proxy to {s}\n", .{u});
        }
    } else {
        if (zvm.settings.proxy.len > 0) {
            try stdout.print("Current proxy: {s}\n", .{zvm.settings.proxy});
        } else {
            try stdout.print("No proxy set (auto-detect from environment).\n", .{});
        }
    }
    try stdout.flush();
}

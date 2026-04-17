//! Proxy command — manage HTTP/HTTPS proxy for downloads.
//! Allows users to set a proxy URL (e.g., http://127.0.0.1:7890) for all
//! network operations. When set to empty/default, zvm auto-detects proxy
//! from environment variables (http_proxy, https_proxy).

const std = @import("std");
const zvm_mod = @import("../core/zvm.zig");
const Console = @import("../core/Console.zig");

/// Supported proxy schemes.
const valid_schemes = [_][]const u8{ "http://", "https://", "socks5://", "socks5h://", "socks4://", "socks4a://" };

/// Validate that a proxy URL has a supported scheme and a host component.
fn validateProxyUrl(url: []const u8) !void {
    // Must have a recognized scheme
    var has_scheme = false;
    for (valid_schemes) |scheme| {
        if (std.mem.startsWith(u8, url, scheme)) {
            has_scheme = true;
            break;
        }
    }
    if (!has_scheme) return error.InvalidUrl;

    // Must parse as a valid URI with a host
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    if (uri.host == null) return error.InvalidUrl;
}

/// Set or display the HTTP/HTTPS proxy.
/// "default" clears the proxy (auto-detect from env vars).
/// With no argument, displays the current proxy setting.
pub fn run(
    zvm: *zvm_mod.ZVM,
    allocator: std.mem.Allocator,
    url: ?[]const u8,
    console: Console,
) !void {
    if (url) |u| {
        if (std.mem.eql(u8, u, "default")) {
            try zvm.settings.setProxy(allocator, zvm.io, "");
            console.plain("Reset proxy to auto-detect (from environment).", .{});
        } else {
            validateProxyUrl(u) catch {
                console.colorize(.stderr, .red, "Invalid proxy URL", .{});
                console.newline(.stderr);
                console.println(.stderr,
                    \\Supported formats:
                    \\  http://host:port
                    \\  https://host:port
                    \\  socks5://host:port
                , .{});
                console.flush(.stderr);
                return;
            };
            try zvm.settings.setProxy(allocator, zvm.io, u);
            console.plain("Set proxy to {s}", .{u});
        }
    } else {
        if (zvm.settings.proxy.len > 0) {
            console.plain("Current proxy: {s}", .{zvm.settings.proxy});
        } else {
            console.plain("No proxy set (auto-detect from environment).", .{});
        }
    }
}

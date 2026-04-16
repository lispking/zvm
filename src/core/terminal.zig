//! ANSI terminal color helpers for formatted console output.
//! Provides colorized printing functions (error, success, info, warning)
//! that wrap text with ANSI escape codes.

const std = @import("std");

/// Supported ANSI color/style codes.
pub const AnsiColor = enum {
    reset,
    bold,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    dim,
};

/// Returns the ANSI escape sequence for the given color.
fn ansiCode(color: AnsiColor) []const u8 {
    return switch (color) {
        .reset => "\x1b[0m",
        .bold => "\x1b[1m",
        .dim => "\x1b[2m",
        .red => "\x1b[31m",
        .green => "\x1b[32m",
        .yellow => "\x1b[33m",
        .blue => "\x1b[34m",
        .magenta => "\x1b[35m",
        .cyan => "\x1b[36m",
        .white => "\x1b[37m",
    };
}

/// Write text wrapped in the specified ANSI color, then reset.
pub fn colorize(writer: *std.Io.Writer, comptime color: AnsiColor, text: []const u8) !void {
    try writer.print("{s}{s}{s}", .{ ansiCode(color), text, ansiCode(.reset) });
}

/// Print a formatted line in the specified color.
pub fn println(writer: *std.Io.Writer, comptime color: AnsiColor, comptime fmt: []const u8, args: anytype) !void {
    try writer.print("{s}" ++ fmt ++ "{s}\n", .{ansiCode(color)} ++ args ++ .{ansiCode(.reset)});
}

/// Print an error message in red with "error:" prefix.
pub fn printError(writer: *std.Io.Writer, msg: []const u8) !void {
    try writer.print("{s}error{s}: {s}\n", .{ ansiCode(.red), ansiCode(.reset), msg });
}

/// Print a success message in green.
pub fn printSuccess(writer: *std.Io.Writer, msg: []const u8) !void {
    try writer.print("{s}{s}{s}\n", .{ ansiCode(.green), msg, ansiCode(.reset) });
}

/// Print an informational message in cyan.
pub fn printInfo(writer: *std.Io.Writer, msg: []const u8) !void {
    try writer.print("{s}{s}{s}\n", .{ ansiCode(.cyan), msg, ansiCode(.reset) });
}

/// Print a warning message in yellow with "warning:" prefix.
pub fn printWarning(writer: *std.Io.Writer, msg: []const u8) !void {
    try writer.print("{s}warning{s}: {s}\n", .{ ansiCode(.yellow), ansiCode(.reset), msg });
}

const std = @import("std");

const Console = @This();

stdout: std.Io.Terminal,
stderr: std.Io.Terminal,

pub const Target = enum {
    stdout,
    stderr,
};

pub const Level = enum {
    err,
    warn,
    info,
    success,

    pub fn color(level: Level) ?std.Io.Terminal.Color {
        return switch (level) {
            .err => .red,
            .warn => .yellow,
            .info => .cyan,
            .success => .green,
        };
    }

    pub fn label(level: Level) ?[]const u8 {
        return switch (level) {
            .err => "error",
            .warn => "warning",
            .info, .success => null,
        };
    }

    pub fn target(level: Level) Target {
        return switch (level) {
            .err, .warn => .stderr,
            .info, .success => .stdout,
        };
    }
};

pub fn init(stdout: *std.Io.Writer, stderr: *std.Io.Writer, mode: ?std.Io.Terminal.Mode) Console {
    const m = mode orelse .no_color;
    return .{
        .stdout = .{ .writer = stdout, .mode = m },
        .stderr = .{ .writer = stderr, .mode = m },
    };
}

// --- High-level APIs for formatted logging with color, labels, and automatic flushing ---

pub fn log(self: Console, comptime level: Level, comptime fmt: []const u8, args: anytype) void {
    const target = comptime level.target();
    if (comptime level.label()) |lbl| {
        self.colorize(target, level.color(), lbl, .{});
        self.print(target, ": " ++ fmt, args);
    } else {
        self.colorize(target, level.color(), fmt, args);
    }
    self.newline(target);
    self.flush(target);
}

pub fn fatal(self: Console, comptime fmt: []const u8, args: anytype) noreturn {
    self.log(.err, fmt, args);
    std.process.exit(1);
}

pub fn err(self: Console, comptime fmt: []const u8, args: anytype) void {
    self.log(.err, fmt, args);
}

pub fn warn(self: Console, comptime fmt: []const u8, args: anytype) void {
    self.log(.warn, fmt, args);
}

pub fn info(self: Console, comptime fmt: []const u8, args: anytype) void {
    self.log(.info, fmt, args);
}

pub fn success(self: Console, comptime fmt: []const u8, args: anytype) void {
    self.log(.success, fmt, args);
}

pub fn plain(self: Console, comptime fmt: []const u8, args: anytype) void {
    self.println(.stdout, fmt, args);
    self.flush(.stdout);
}

// --- Low-level APIs for direct terminal access (no color, labels, or flushing) ---

pub fn newline(self: Console, comptime target: Target) void {
    const t = self.terminal(target);
    t.writer.writeAll("\n") catch {};
}

pub fn write(self: Console, comptime target: Target, data: []const u8) void {
    const t = self.terminal(target);
    t.writer.writeAll(data) catch {};
}

pub fn writeln(self: Console, comptime target: Target, data: []const u8) void {
    const t = self.terminal(target);
    t.writer.writeAll(data) catch {};
    t.writer.writeAll("\n") catch {};
}

pub fn print(self: Console, comptime target: Target, comptime fmt: []const u8, args: anytype) void {
    const t = self.terminal(target);
    t.writer.print(fmt, args) catch {};
}

pub fn println(self: Console, comptime target: Target, comptime fmt: []const u8, args: anytype) void {
    const t = self.terminal(target);
    t.writer.print(fmt ++ "\n", args) catch {};
}

pub fn colorize(
    self: Console,
    comptime target: Target,
    color: ?std.Io.Terminal.Color,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const t = self.terminal(target);
    if (color) |c| {
        t.setColor(c) catch {};
        t.writer.print(fmt, args) catch {};
        t.setColor(.reset) catch {};
    } else {
        t.writer.print(fmt, args) catch {};
    }
}

pub fn flush(self: Console, comptime target: Target) void {
    self.terminal(target).writer.flush() catch {};
}

inline fn terminal(self: Console, comptime target: Target) std.Io.Terminal {
    return if (target == .stdout) self.stdout else self.stderr;
}

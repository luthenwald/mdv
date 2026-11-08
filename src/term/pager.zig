//! Starting the pager that mdv writes into when the output is a terminal.

const std = @import("std");

pub const default_command = "less -RFX";

/// `MDV_PAGER`, then `PAGER`, then `less -RFX`. An empty variable counts as unset.
pub fn command(env: *const std.process.Environ.Map) []const u8 {
    for ([_][]const u8{ "MDV_PAGER", "PAGER" }) |name| {
        if (env.get(name)) |value| if (std.mem.trim(u8, value, " \t").len > 0) return value;
    }
    return default_command;
}

/// Runs `cmd` through `/bin/sh -c` with a pipe for its standard input.
/// Null when it cannot be started; the caller writes to stdout instead.
pub fn start(io: std.Io, cmd: []const u8) ?std.process.Child {
    return std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", cmd },
        .stdin = .pipe,
    }) catch null;
}

/// The shell's way of saying the command was not found or not executable.
pub fn notStarted(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 126 or code == 127,
        else => false,
    };
}

const testing = std.testing;

test "the pager variables in order, empty ones skipped" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try testing.expectEqualStrings(default_command, command(&env));
    try env.put("PAGER", "more");
    try testing.expectEqualStrings("more", command(&env));
    try env.put("MDV_PAGER", " ");
    try testing.expectEqualStrings("more", command(&env));
    try env.put("MDV_PAGER", "less -R");
    try testing.expectEqualStrings("less -R", command(&env));
}

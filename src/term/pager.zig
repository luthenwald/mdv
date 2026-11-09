//! Starting the pager that mdv writes into when the output is a terminal.

const std = @import("std");
const Environ = std.process.Environ;

pub const default_command = "less -RFX";

/// `MDV_PAGER`, then `PAGER`, then `less -RFX`. An empty variable counts as unset.
pub fn command(env: *const Environ.Map) []const u8 {
    for ([_][]const u8{ "MDV_PAGER", "PAGER" }) |name| {
        if (env.get(name)) |value| if (std.mem.trim(u8, value, " \t").len > 0) return value;
    }
    return default_command;
}

/// Runs `cmd` through `/bin/sh -c` with a pipe for its standard input.
/// Null when it cannot be started; the caller writes to stdout instead.
pub fn start(io: std.Io, arena: std.mem.Allocator, cmd: []const u8, env: *const Environ.Map) ?std.process.Child {
    const child_env = environment(arena, env) catch return null;
    return std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", cmd },
        .stdin = .pipe,
        .environ_map = child_env,
    }) catch null;
}

/// The environment for the pager: a copy of ours where `LESS` and `LV` are
/// set when they were missing, so that a bare `less` or `lv` in `PAGER`
/// shows the styles and quits on a short document, as git arranges. Null
/// when ours will do as it is.
pub fn environment(arena: std.mem.Allocator, env: *const Environ.Map) std.mem.Allocator.Error!?*const Environ.Map {
    const less = env.get("LESS") == null;
    const lv = env.get("LV") == null;
    if (!less and !lv) return null;
    const copy = try arena.create(Environ.Map);
    copy.* = .init(arena);
    for (env.keys(), env.values()) |key, value| try copy.put(key, value);
    if (less) try copy.put("LESS", "FRX");
    if (lv) try copy.put("LV", "-c");
    return copy;
}

/// The shell's way of saying the command was not found or not executable.
pub fn notStarted(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 126 or code == 127,
        else => false,
    };
}

/// What `Ctrl-C` and `Ctrl-\` did before the pager took them over.
pub const Interrupts = struct {
    int: std.posix.Sigaction,
    quit: std.posix.Sigaction,
};

/// Leaves interrupts to the pager while it runs. Set after the pager has
/// started, so that it keeps the default actions, mdv ignores them: a
/// `Ctrl-C` in less would otherwise end mdv and leave less holding the
/// terminal.
pub fn ignoreInterrupts() Interrupts {
    const ignore: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var before: Interrupts = undefined;
    std.posix.sigaction(.INT, &ignore, &before.int);
    std.posix.sigaction(.QUIT, &ignore, &before.quit);
    return before;
}

pub fn restoreInterrupts(before: Interrupts) void {
    std.posix.sigaction(.INT, &before.int, null);
    std.posix.sigaction(.QUIT, &before.quit, null);
}

const testing = std.testing;

test "the pager variables in order, empty ones skipped" {
    var env: Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try testing.expectEqualStrings(default_command, command(&env));
    try env.put("PAGER", "more");
    try testing.expectEqualStrings("more", command(&env));
    try env.put("MDV_PAGER", " ");
    try testing.expectEqualStrings("more", command(&env));
    try env.put("MDV_PAGER", "less -R");
    try testing.expectEqualStrings("less -R", command(&env));
}

test "LESS and LV are set for the pager only when missing" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env: Environ.Map = .init(arena);
    try env.put("PAGER", "less");
    const filled = (try environment(arena, &env)).?;
    try testing.expectEqualStrings("FRX", filled.get("LESS").?);
    try testing.expectEqualStrings("-c", filled.get("LV").?);
    try testing.expectEqualStrings("less", filled.get("PAGER").?);
    try testing.expectEqual(null, env.get("LESS"));
    try env.put("LESS", "-S");
    try testing.expectEqualStrings("-S", (try environment(arena, &env)).?.get("LESS").?);
    try env.put("LV", "");
    try testing.expectEqual(null, try environment(arena, &env));
}

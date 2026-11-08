const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const md = b.createModule(.{
        .root_source_file = b.path("src/md/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
    mod.addOptions("build_options", options);
    mod.addImport("md", md);

    const exe = b.addExecutable(.{
        .name = "mdv",
        .root_module = mod,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run mdv").dependOn(&run.step);

    const spec = b.addExecutable(.{
        .name = "spec",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/spec.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "md", .module = md }},
        }),
    });
    const spec_run = b.addRunArtifact(spec);
    spec_run.addFileArg(b.path("test/spec/spec.json"));
    spec_run.addPassthruArgs();
    b.step("spec", "Run the CommonMark examples").dependOn(&spec_run.step);

    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = md })).step);
}

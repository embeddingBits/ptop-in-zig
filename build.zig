const std = @import("std");

pub fn build(b: *std.Build) void {
    // Define the target (e.g., native system) and optimization mode
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create an executable
    const exe = b.addExecutable(.{
        .name = "ptop", // Output binary name
        .root_source_file = .{ .path = "src/ptop.zig" }, // Path to your main file
        .target = target,
        .optimize = optimize,
    });

    // Link against libc and ncurses (required for your project)
    exe.linkLibC();
    exe.linkSystemLibrary("ncurses");

    // Install the executable (e.g., to zig-out/bin/)
    b.installArtifact(exe);

    // Add a "run" command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Define the "run" step
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

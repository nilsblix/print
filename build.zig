const std = @import("std");

pub fn build(b: *std.Build) void {
    var exe = b.addExecutable(.{
        .name = "print",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.standardTargetOptions(.{}),
            .optimize = .Debug,
        }),
    });

    exe.root_module.addIncludePath(b.path("include"));
    exe.root_module.addCSourceFile(.{
        .file = b.path("./include/stb_image.c"),
    });
    exe.linkLibC();

    const clap = b.dependency("clap", .{});
    exe.root_module.addImport("clap", clap.module("clap"));

    b.installArtifact(exe);
}

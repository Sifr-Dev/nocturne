const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const framework = b.option([]const u8, "cipher-root", "Cipher framework checkout") orelse "../Cipher";
    const music_dir = b.option([]const u8, "music-dir", "Collection directory for probe/verify") orelse "/home/sifr/Music";

    const cipher = b.createModule(.{
        .root_source_file = .{ .cwd_relative = b.fmt("{s}/src/cipher.zig", .{framework}) },
        .target = target,
        .optimize = optimize,
    });
    cipher.link_libc = true;
    cipher.addAnonymousImport("resources", .{ .root_source_file = .{ .cwd_relative = b.fmt("{s}/resources.zig", .{framework}) } });

    const audio = b.createModule(.{
        .root_source_file = b.path("src/audio_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    audio.link_libc = true;

    const app = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    app.link_libc = true;
    app.addImport("cipher", cipher);
    app.addImport("audio", audio);
    const exe = b.addExecutable(.{ .name = "nocturne", .root_module = app });
    b.installArtifact(exe);

    const dist = b.step("dist", "Create the standalone release directory");
    const install_dist = b.addInstallBinFile(exe.getEmittedBin(), "nocturne");
    dist.dependOn(&install_dist.step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run Nocturne").dependOn(&run.step);

    const probe = b.addExecutable(.{
        .name = "nocturne-collection-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/collection_probe.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    probe.root_module.link_libc = true;
    probe.root_module.addImport("audio", audio);
    const run_probe = b.addRunArtifact(probe);
    run_probe.addArg(music_dir);
    b.step("probe", "Decode every FLAC in a collection directory").dependOn(&run_probe.step);

    const audio_tests = b.addTest(.{
        .name = "nocturne-audio-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/audio/audio_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    audio_tests.root_module.link_libc = true;
    const run_audio = b.addRunArtifact(audio_tests);
    b.step("test-audio", "Run the independent FLAC differential suite").dependOn(&run_audio.step);

    const playback_tests = b.addTest(.{
        .name = "nocturne-playback-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/playback_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    playback_tests.root_module.addAnonymousImport("app", .{ .root_source_file = b.path("src/main.zig") });
    playback_tests.root_module.addImport("cipher", cipher);
    playback_tests.root_module.addImport("audio", audio);
    playback_tests.root_module.link_libc = true;
    const run_playback = b.addRunArtifact(playback_tests);
    b.step("test-playback", "Verify bounded playback format conversion").dependOn(&run_playback.step);

    // verify — bit-exact comparison of the decoder against ffmpeg on real files.
    const verify = b.addExecutable(.{
        .name = "flac-verify",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/flac_verify.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    verify.root_module.link_libc = true;
    verify.root_module.addImport("audio", audio);
    const run_verify = b.addRunArtifact(verify);
    run_verify.addArg(music_dir);
    run_verify.addArg(b.option([]const u8, "filter", "Only verify files whose name contains this") orelse "");
    run_verify.addArg(b.option([]const u8, "limit", "Maximum number of files to verify (0 = all)") orelse "0");
    b.step("verify", "Bit-exact compare decoder output against ffmpeg for given files").dependOn(&run_verify.step);
}

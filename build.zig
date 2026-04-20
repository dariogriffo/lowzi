const std = @import("std");
const zunit_build = @import("zunit");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -------------------------------------------------------------------------
    // Build options
    // -------------------------------------------------------------------------
    const opt_mpris = b.option(bool, "mpris", "Enable MPRIS D-Bus integration (Linux only)") orelse false;
    const opt_scrape = b.option(bool, "scrape", "Enable chillhop.com scraper") orelse false;
    const opt_extra_audio = b.option(bool, "extra-audio-formats", "Enable FLAC/OGG/WAV support (v2)") orelse false;
    const opt_smoke = b.option(bool, "smoke", "Include smoke tests that require real audio hardware") orelse false;

    // -------------------------------------------------------------------------
    // Step 4: translate-c wiring for vendored audio headers.
    //
    // b.addTranslateC produces a Zig module from the umbrella header.
    // We expose it as "audio_c" so src/audio/c.zig can @import("audio_c").
    // No @cImport — deprecated in 0.16 (AGENTS.md §0.1).
    // -------------------------------------------------------------------------
    const audio_c_step = b.addTranslateC(.{
        .root_source_file = b.path("third_party/audio_umbrella.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // The umbrella header uses relative includes like "miniaudio/miniaudio.h",
    // so the include root must be third_party/.
    audio_c_step.addIncludePath(b.path("third_party"));
    const audio_c_mod = audio_c_step.createModule();

    // -------------------------------------------------------------------------
    // Step 3a: translate-c wiring for the SQLite amalgamation.
    //
    // Exposes "storage_c" so src/storage/c.zig can @import("storage_c").
    // sqlite3.c is compiled once and linked into every artifact that needs it.
    // -------------------------------------------------------------------------
    const storage_c_step = b.addTranslateC(.{
        .root_source_file = b.path("third_party/sqlite/sqlite3.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const storage_c_mod = storage_c_step.createModule();

    const sqlite3_c_flags = [_][]const u8{
        "-std=c99",
        "-DSQLITE_THREADSAFE=1",
        "-DSQLITE_DQS=0",
        "-DSQLITE_DEFAULT_FOREIGN_KEYS=1",
        "-DSQLITE_OMIT_DEPRECATED",
        "-DSQLITE_USE_ALLOCA",
        "-DSQLITE_ENABLE_FTS5=0",
    };

    // -------------------------------------------------------------------------
    // lowzi executable
    // -------------------------------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "lowzi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Expose build options to the executable as a comptime module.
    const build_options = b.addOptions();
    build_options.addOption(bool, "mpris", opt_mpris);
    build_options.addOption(bool, "scrape", opt_scrape);
    build_options.addOption(bool, "extra_audio_formats", opt_extra_audio);
    build_options.addOption(bool, "smoke", opt_smoke);
    exe.root_module.addOptions("build_options", build_options);

    exe.root_module.addImport("audio_c", audio_c_mod);
    exe.root_module.addImport("storage_c", storage_c_mod);

    // Note: sqlite3.c is compiled into storage_module below and linked
    // transitively into the exe through the "storage" import.

    // NOTE: The audio C implementation shims (miniaudio.c, dr_mp3.c) are
    // compiled inside audio_module (below) and linked transitively into the exe.
    // Do NOT add them here again or symbols will be duplicated at link time.

    // Link libc everywhere; link pthread/m/dl on Linux.
    // In Zig 0.16 these are set on the root module, not on the Compile step.
    exe.root_module.link_libc = true;
    if (target.result.os.tag == .linux) {
        exe.root_module.linkSystemLibrary("pthread", .{});
        exe.root_module.linkSystemLibrary("m", .{});
        exe.root_module.linkSystemLibrary("dl", .{});
    } else if (target.result.os.tag == .macos) {
        exe.root_module.linkFramework("CoreAudio", .{});
        exe.root_module.linkFramework("AudioToolbox", .{});
    } else if (target.result.os.tag == .windows) {
        exe.root_module.linkSystemLibrary("ole32", .{});
    }

    b.installArtifact(exe);

    // -------------------------------------------------------------------------
    // lowzi-basic executable — minimal smoke binary: plays the first track from
    // the existing catalog and exits. No UI, no sync, no queue.
    // -------------------------------------------------------------------------
    const exe_basic = b.addExecutable(.{
        .name = "lowzi-basic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/basic.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe_basic.root_module.addOptions("build_options", build_options);
    exe_basic.root_module.addImport("audio_c", audio_c_mod);
    exe_basic.root_module.addImport("storage_c", storage_c_mod);
    exe_basic.root_module.link_libc = true;
    if (target.result.os.tag == .linux) {
        exe_basic.root_module.linkSystemLibrary("pthread", .{});
        exe_basic.root_module.linkSystemLibrary("m", .{});
        exe_basic.root_module.linkSystemLibrary("dl", .{});
    } else if (target.result.os.tag == .macos) {
        exe_basic.root_module.linkFramework("CoreAudio", .{});
        exe_basic.root_module.linkFramework("AudioToolbox", .{});
    } else if (target.result.os.tag == .windows) {
        exe_basic.root_module.linkSystemLibrary("ole32", .{});
    }

    b.installArtifact(exe_basic);

    // -------------------------------------------------------------------------
    // `zig build run` step
    // -------------------------------------------------------------------------
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Build and run lowzi");
    run_step.dependOn(&run_cmd.step);

    // -------------------------------------------------------------------------
    // `zig build basic` step
    // -------------------------------------------------------------------------
    const basic_cmd = b.addRunArtifact(exe_basic);
    basic_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| basic_cmd.addArgs(args);

    const basic_step = b.step("basic", "Build and run lowzi-basic");
    basic_step.dependOn(&basic_cmd.step);

    // -------------------------------------------------------------------------
    // `zig build test` step (zunit runner)
    // -------------------------------------------------------------------------
    const zunit_dep = b.dependency("zunit", .{ .target = target, .optimize = optimize });

    // The core module — shared vocabulary, imported by tests as "core".
    const core_module = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_module.link_libc = true; // paths.zig uses std.c.getenv

    // The audio module — translate-c bindings + decoder + output + pipeline.
    const audio_module = b.createModule(.{
        .root_source_file = b.path("src/audio/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    audio_module.addImport("audio_c", audio_c_mod);
    audio_module.addImport("core", core_module);
    audio_module.link_libc = true;
    audio_module.addCSourceFiles(.{
        .files = &.{
            "third_party/miniaudio/miniaudio.c",
            "third_party/dr_libs/dr_mp3.c",
        },
        .flags = &.{ "-std=c99", "-pthread" },
    });
    audio_module.addIncludePath(b.path("third_party/miniaudio"));
    audio_module.addIncludePath(b.path("third_party/dr_libs"));
    if (target.result.os.tag == .linux) {
        audio_module.linkSystemLibrary("pthread", .{});
        audio_module.linkSystemLibrary("m", .{});
        audio_module.linkSystemLibrary("dl", .{});
    } else if (target.result.os.tag == .macos) {
        audio_module.linkFramework("CoreAudio", .{});
        audio_module.linkFramework("AudioToolbox", .{});
    } else if (target.result.os.tag == .windows) {
        audio_module.linkSystemLibrary("ole32", .{});
    }

    // The source module — manifest fetch, m3u8 parser, downloader.
    // root file: src/source/root.zig.  Imports only std and core.
    const source_module = b.createModule(.{
        .root_source_file = b.path("src/source/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    source_module.addImport("core", core_module);

    // The storage module — SQLite catalog, schema, queries.
    const storage_module = b.createModule(.{
        .root_source_file = b.path("src/storage/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    storage_module.addImport("storage_c", storage_c_mod);
    storage_module.addImport("core", core_module);
    storage_module.link_libc = true;
    storage_module.addCSourceFile(.{
        .file = b.path("third_party/sqlite/sqlite3.c"),
        .flags = &sqlite3_c_flags,
    });

    // sync.zig inside the source module imports storage, so wire it in.
    source_module.addImport("storage", storage_module);

    // The player module — state machine that owns playback.
    const player_module = b.createModule(.{
        .root_source_file = b.path("src/player/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    player_module.addImport("core", core_module);
    player_module.addImport("storage", storage_module);
    player_module.addImport("source", source_module);

    // The headless module — v0.1 non-TUI front end and permanent smoke fixture.
    const headless_module = b.createModule(.{
        .root_source_file = b.path("src/headless.zig"),
        .target = target,
        .optimize = optimize,
    });
    headless_module.addImport("core", core_module);

    // The platform module — OS signal handling, MPRIS, etc.
    const platform_module = b.createModule(.{
        .root_source_file = b.path("src/platform/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    platform_module.addImport("core", core_module);

    // Also wire storage_c and storage_module into the exe.
    exe.root_module.addImport("core", core_module);
    exe.root_module.addImport("storage", storage_module);
    exe.root_module.addImport("source", source_module);
    exe.root_module.addImport("audio", audio_module);
    exe.root_module.addImport("player", player_module);
    exe.root_module.addImport("headless", headless_module);
    exe.root_module.addImport("platform", platform_module);

    // Wire modules into lowzi-basic.
    exe_basic.root_module.addImport("core", core_module);
    exe_basic.root_module.addImport("storage", storage_module);
    exe_basic.root_module.addImport("source", source_module);
    exe_basic.root_module.addImport("audio", audio_module);

    // The lowzi module exposed to tests so they can @import("lowzi").
    const lowzi_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    lowzi_module.addOptions("build_options", build_options);
    lowzi_module.addImport("core", core_module);
    lowzi_module.addImport("storage", storage_module);
    lowzi_module.addImport("source", source_module);
    lowzi_module.addImport("audio", audio_module);
    lowzi_module.addImport("player", player_module);
    lowzi_module.addImport("headless", headless_module);
    lowzi_module.addImport("platform", platform_module);

    // Every test binary shares the same set of module imports — zunit's
    // testSuite helper applies them to each addFile() entry automatically.
    const shared_imports = [_]zunit_build.Import{
        .{ .name = "lowzi", .module = lowzi_module },
        .{ .name = "core", .module = core_module },
        .{ .name = "audio", .module = audio_module },
        .{ .name = "audio_c", .module = audio_c_mod },
        .{ .name = "source", .module = source_module },
        .{ .name = "storage", .module = storage_module },
        .{ .name = "storage_c", .module = storage_c_mod },
        .{ .name = "player", .module = player_module },
        .{ .name = "headless", .module = headless_module },
        .{ .name = "platform", .module = platform_module },
    };

    const suite = zunit_build.testSuite(b, zunit_dep, .{
        .target = target,
        .optimize = optimize,
        .output_file = "test-results.xml",
        .output_dir = "zig-out/test-fragments",
        .imports = &shared_imports,
    });

    // Explicit list of test files — add new entries here as steps land.
    // There is intentionally no glob discovery: every file must be named
    // so the test step dependency graph is deterministic.
    suite.addFile("tests/sanity_test.zig");
    // Step 2: core module tests.
    suite.addFile("tests/core_cli_test.zig");
    suite.addFile("tests/core_paths_test.zig");
    suite.addFile("tests/core_channel_test.zig");
    suite.addFile("tests/core_track_test.zig");
    suite.addFile("tests/core_message_test.zig");
    // Step 4: audio module tests.
    suite.addFile("tests/audio_decoder_test.zig");
    suite.addFile("tests/audio_output_test.zig");
    suite.addFile("tests/audio_pipeline_test.zig");
    // Step 3b: source/manifest tests.
    suite.addFile("tests/source_manifest_test.zig");
    // Step 3c: source/m3u8 tests.
    suite.addFile("tests/source_m3u8_test.zig");
    // Step 3a: storage module tests.
    suite.addFile("tests/storage_schema_test.zig");
    suite.addFile("tests/storage_queries_test.zig");
    suite.addFile("tests/storage_cascade_test.zig");
    suite.addFile("tests/storage_sync_tx_test.zig");
    // Step 5: source/downloader tests.
    suite.addFile("tests/source_downloader_test.zig");
    // Step 3d: source/sync tests.
    suite.addFile("tests/source_sync_test.zig");
    // Step 6: player module tests.
    suite.addFile("tests/player_state_test.zig");
    suite.addFile("tests/player_queue_test.zig");
    suite.addFile("tests/player_bookmark_test.zig");
    suite.addFile("tests/player_controller_test.zig");
    // Step 6h: headless harness tests.
    suite.addFile("tests/headless_test.zig");
    // Step 8: platform/signals tests.
    suite.addFile("tests/platform_signals_test.zig");
    // Step 8: integration smoke (non -Dsmoke variant).
    suite.addFile("tests/integration_smoke_test.zig");

    // Smoke test is appended only when -Dsmoke=true.
    // Gate it here rather than in the list above so the list stays clean.
    if (opt_smoke) {
        suite.addFile("tests/smoke_test.zig");
    }

    const test_step = b.step("test", "Run unit and integration tests via zunit");
    test_step.dependOn(suite.step());

    // -------------------------------------------------------------------------
    // `zig build lint` step (zlint — advisory in v0.1)
    //
    // In v0.1 the lint step is explicitly advisory: zlint's analyzer was last
    // released against Zig 0.15.x and may emit false positives on 0.16-only
    // syntax (@Int, @Enum, std.Io.*).  Rather than block builds and PRs on
    // phantom errors, we:
    //   1. Skip the step entirely (with a notice) if the `zlint` binary is absent.
    //   2. Run it but do not fail the build if it exits non-zero.
    //
    // When zlint ships a 0.16-aware release and a clean run on `src/` is
    // reproduced, remove the advisory wrapper: replace the LazyPath check with
    // a hard `b.findProgram` error and let the exit code propagate naturally.
    // -------------------------------------------------------------------------
    const lint_step = b.step("lint", "Run zlint on src/ and tests/ (advisory in v0.1)");

    const zlint_path: ?[]const u8 = b.findProgram(&.{"zlint"}, &.{}) catch null;

    if (zlint_path) |_| {
        // zlint is present — run it but treat any exit code as advisory.
        // We wrap via `sh -c` so a non-zero exit from zlint does not cause
        // `zig build lint` to fail.  The developer still sees all output.
        // Remove the `|| true` suffix once zlint ships a 0.16-aware release
        // and a clean run on `src/` has been reproduced (SPECIFICATION §9.4).
        const advisory_cmd = b.addSystemCommand(&.{
            "sh", "-c",
            "zlint src tests || echo 'lowzi: zlint exited non-zero (advisory in v0.1 — see SPECIFICATION §9.4)'",
        });
        if (b.args) |args| advisory_cmd.addArgs(args);
        lint_step.dependOn(&advisory_cmd.step);
    } else {
        // zlint binary not found — print a notice and continue.  Do not fail.
        // Install with:  bash tasks/install-zlint.sh
        const notice = b.addSystemCommand(&.{
            "sh", "-c",
            "echo 'lowzi: zlint not found — lint step skipped (advisory in v0.1). Install with: bash tasks/install-zlint.sh'",
        });
        lint_step.dependOn(&notice.step);
    }
}

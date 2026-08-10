const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_mod.linkSystemLibrary("SDL3", .{});
    // In-process Gemma via system libllama (ROCm/Vulkan backends in ggml).
    root_mod.linkSystemLibrary("llama", .{});
    root_mod.linkSystemLibrary("ggml", .{});
    root_mod.link_libcpp = true;

    // blargg snes_spc (C++ with C API). Disable UBSan: the core uses
    // intentional bit tricks (signed shifts, etc.) that Zig Debug traps on.
    const spc_flags = [_][]const u8{
        "-std=c++11",
        "-fno-exceptions",
        "-fno-rtti",
        "-DNDEBUG",
        "-fno-sanitize=undefined",
    };
    const spc_sources = [_][]const u8{
        "vendor/snes_spc/spc.cpp",
        "vendor/snes_spc/SNES_SPC.cpp",
        "vendor/snes_spc/SNES_SPC_misc.cpp",
        "vendor/snes_spc/SNES_SPC_state.cpp",
        "vendor/snes_spc/SPC_DSP.cpp",
        "vendor/snes_spc/SPC_Filter.cpp",
        "vendor/snes_spc/dsp.cpp",
    };
    for (spc_sources) |src| {
        root_mod.addCSourceFile(.{
            .file = b.path(src),
            .flags = &spc_flags,
        });
    }
    root_mod.addIncludePath(b.path("vendor"));
    root_mod.addIncludePath(b.path("src"));

    // FF4 APU host (C)
    root_mod.addCSourceFile(.{
        .file = b.path("src/audio/host.c"),
        .flags = &.{"-std=c11"},
    });

    // In-process LLM host (libllama C API)
    root_mod.addCSourceFile(.{
        .file = b.path("src/ai/llm_host.c"),
        .flags = &.{ "-std=c11", "-fno-sanitize=undefined" },
    });

    // Kokoro TTS host — spawns warm PyTorch ROCm worker (scripts/kokoro_rocm_worker.py)
    root_mod.addCSourceFile(.{
        .file = b.path("src/ai/tts_host.c"),
        .flags = &.{ "-std=c11", "-fno-sanitize=undefined" },
    });

    const exe = b.addExecutable(.{
        .name = "ff4",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run ff4");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = root_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}

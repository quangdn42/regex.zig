const std = @import("std");

pub fn build(b: *std.Build) void {
    // Shared build options.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const install_demo = b.option(
        bool,
        "install-demo",
        "Install regex-demo to zig-out/bin",
    ) orelse false;

    // Public package module (what downstream users import as "regex").
    const regex_mod = b.addModule("regex", .{
        .root_source_file = b.path("src/Regex.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Demo executable. Built by default (`zig build`) but not installed.
    const demo_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_mod.addImport("regex", regex_mod);

    const demo_exe = b.addExecutable(.{
        .name = "regex-demo",
        .root_module = demo_mod,
    });
    if (install_demo) {
        const install_demo_exe = b.addInstallArtifact(demo_exe, .{});
        b.getInstallStep().dependOn(&install_demo_exe.step);
    } else {
        b.getInstallStep().dependOn(&demo_exe.step);
    }

    const regex_lib_check = b.addLibrary(.{
        .name = "regex",
        .root_module = regex_mod,
        .linkage = .static,
    });

    const run_demo = b.addRunArtifact(demo_exe);
    run_demo.addPassthruArgs();
    const run_step = b.step("run", "Run regex demo");
    run_step.dependOn(&run_demo.step);

    // Build-on-save check step.
    const check = b.step("check", "Compile demo and library module");
    check.dependOn(&regex_lib_check.step);
    check.dependOn(&demo_exe.step);

    // Export Regex internal for integration tests
    const export_test_mod = b.createModule(.{
        .root_source_file = b.path("src/export_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests rooted at `src/Regex.zig`.
    const unit_tests = b.addTest(.{
        .root_module = regex_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const api_tests = b.addTest(.{
        .name = "api-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/api_integration.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    api_tests.root_module.addImport("export_test", export_test_mod);
    const run_api_tests = b.addRunArtifact(api_tests);

    // Suite tests
    const suite_tests = b.addExecutable(.{
        .name = "suite-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    suite_tests.root_module.addImport("export_test", export_test_mod);
    const run_suite_tests = b.addRunArtifact(suite_tests);
    run_suite_tests.addPassthruArgs();

    const test_unit_step = b.step("test-unit", "Run unit tests");
    test_unit_step.dependOn(&run_unit_tests.step);
    test_unit_step.dependOn(&run_api_tests.step);

    const test_suite_step = b.step("test-suite", "Run suite-backed tests");
    test_suite_step.dependOn(&run_suite_tests.step);

    const suite_test_bin = b.addInstallArtifact(suite_tests, .{
        .dest_sub_path = "suite-tests",
    });
    const test_bin_step = b.step(
        "test-bin",
        "Build the suite test binary for debugger use",
    );
    test_bin_step.dependOn(&suite_test_bin.step);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_api_tests.step);
    test_step.dependOn(&run_suite_tests.step);
}

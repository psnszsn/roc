//! Make-phase filesystem and reporting actions used by build.zig.

const std = @import("std");
const builtin = @import("builtin");

/// Dispatch one serialized make-phase action selected by build.zig.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena_impl = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) return error.MissingAction;
    const action = args[1];
    if (std.mem.eql(u8, action, "print-success")) {
        std.debug.print("Build succeeded!\n", .{});
    } else if (std.mem.eql(u8, action, "tests-summary")) {
        std.debug.print("All Zig test suites passed.\n", .{});
    } else if (std.mem.eql(u8, action, "remove-dir")) {
        if (args.len != 3) return error.InvalidArguments;
        try std.Io.Dir.cwd().deleteTree(io, args[2]);
    } else if (std.mem.eql(u8, action, "fix-archive-padding")) {
        if (args.len != 3) return error.InvalidArguments;
        try fixArchivePadding(io, args[2]);
    } else if (std.mem.eql(u8, action, "clear-roc-cache")) {
        try clearRocCache(io, arena, init.environ_map);
    } else if (std.mem.eql(u8, action, "snapshot-diff")) {
        try checkSnapshotDiff(io, arena, init.environ_map);
    } else if (std.mem.eql(u8, action, "check-type-checker-patterns")) {
        try checkTypeCheckerPatterns(io, arena);
    } else if (std.mem.eql(u8, action, "check-enum-from-int-zero")) {
        try checkEnumFromIntZero(io, arena);
    } else if (std.mem.eql(u8, action, "check-unused-suppression")) {
        try checkUnusedSuppression(io, arena);
    } else if (std.mem.eql(u8, action, "check-panic-usage")) {
        try checkPanicUsage(io, arena);
    } else if (std.mem.eql(u8, action, "check-cli-global-stdio")) {
        try checkCliGlobalStdio(io, arena);
    } else if (std.mem.eql(u8, action, "check-test-asset-coverage")) {
        try checkTestAssetCoverage(io, arena);
    } else if (std.mem.eql(u8, action, "coverage-summary")) {
        if (args.len != 6) return error.InvalidArguments;
        try coverageSummary(io, arena, args[2], args[3], args[4], try std.fmt.parseFloat(f64, args[5]));
    } else if (std.mem.eql(u8, action, "coverage-unsupported")) {
        printCoverageUnsupported();
    } else {
        std.debug.print("unknown build action: {s}\n", .{action});
        return error.UnknownAction;
    }
}

fn fixArchivePadding(io: std.Io, archive_path: []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(io, archive_path, .{ .mode = .read_write });
    defer file.close(io);

    const stat = try file.stat(io);
    var file_size = stat.size;
    if (file_size % 2 == 1) {
        try file.writePositionalAll(io, "\n", file_size);
        file_size += 1;
    }

    var header_buf: [8]u8 = undefined;
    if (try file.readPositionalAll(io, &header_buf, 0) != header_buf.len or
        !std.mem.eql(u8, &header_buf, "!<arch>\n"))
    {
        return error.InvalidArchiveMagic;
    }

    var offset: u64 = 8;
    while (offset + 60 <= file_size) {
        var size_buf: [10]u8 = undefined;
        if (try file.readPositionalAll(io, &size_buf, offset + 48) != size_buf.len) {
            return error.TruncatedArchiveHeader;
        }

        var size: u64 = 0;
        for (size_buf) |byte| {
            if (byte < '0' or byte > '9') break;
            size = try std.math.mul(u64, size, 10);
            size = try std.math.add(u64, size, byte - '0');
        }

        offset = try std.math.add(u64, offset, 60 + size + size % 2);
        if (offset == file_size) return;
        if (offset > file_size) {
            if (offset - file_size != 1) return error.TruncatedArchive;
            try file.writePositionalAll(io, "\n", file_size);
            return;
        }
    }

    if (offset != file_size) return error.TruncatedArchive;
}

fn clearRocCache(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) !void {
    const cache_dir_name = if (builtin.os.tag == .windows) "Roc" else "roc";
    const cache_dir = if (environ_map.get("XDG_CACHE_HOME")) |xdg_cache|
        try std.fs.path.join(allocator, &.{ xdg_cache, cache_dir_name })
    else blk: {
        const home_name = if (builtin.os.tag == .windows) "APPDATA" else "HOME";
        const home_dir = environ_map.get(home_name) orelse return error.NoHomeDirectory;
        if (builtin.os.tag == .macos) {
            break :blk try std.fs.path.join(allocator, &.{ home_dir, "Library", "Caches", cache_dir_name });
        }
        if (builtin.os.tag == .windows) {
            break :blk try std.fs.path.join(allocator, &.{ home_dir, cache_dir_name });
        }
        break :blk try std.fs.path.join(allocator, &.{ home_dir, ".cache", cache_dir_name });
    };

    try std.Io.Dir.cwd().deleteTree(io, cache_dir);
    std.debug.print("Cleared roc cache at {s}\n", .{cache_dir});
}

fn checkSnapshotDiff(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) !void {
    if (try commandSucceeds(io, allocator, environ_map, &.{ "git", "rev-parse", "--is-inside-work-tree" })) {
        if (!try commandSucceeds(io, allocator, environ_map, &.{ "git", "diff", "--quiet", "--", "test/snapshots" })) {
            std.debug.print("Tracked snapshots changed. Run 'zig build run-snapshot-tool' and commit the result.\n", .{});
            return error.SnapshotDiff;
        }
        return;
    }

    if (try commandSucceeds(io, allocator, environ_map, &.{ "jj", "root" })) {
        if (!try commandSucceeds(io, allocator, environ_map, &.{ "jj", "diff", "--quiet", "test/snapshots" })) {
            std.debug.print("Tracked snapshots changed. Run 'zig build run-snapshot-tool' and commit the result.\n", .{});
            return error.SnapshotDiff;
        }
        return;
    }

    return error.NoVersionControlWorktree;
}

fn commandSucceeds(
    io: std.Io,
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    argv: []const []const u8,
) !bool {
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .environ_map = environ_map,
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return result.term == .exited and result.term.exited == 0;
}

fn printCoverageUnsupported() void {
    const separator: [60]u8 = @splat('=');
    std.debug.print("\n" ++ separator ++ "\n", .{});
    std.debug.print("COVERAGE NOT SUPPORTED\n", .{});
    std.debug.print(separator ++ "\n\n", .{});
    std.debug.print("kcov parser coverage is currently enabled only on Linux ARM64.\n", .{});
    std.debug.print("Current platform: {s}\n\n", .{@tagName(builtin.target.os.tag)});
    std.debug.print(separator ++ "\n", .{});
}

const Violation = struct {
    file_path: []const u8,
    line_number: usize,
    line_content: []const u8,
    pattern: []const u8 = "",
};

const ExcludedRange = struct {
    file: []const u8,
    start: usize,
    end: usize,
};

fn inExcludedRange(file_path: []const u8, line_number: usize, ranges: []const ExcludedRange) bool {
    for (ranges) |range| {
        if (std.mem.endsWith(u8, file_path, range.file) and
            line_number >= range.start and line_number <= range.end)
        {
            return true;
        }
    }
    return false;
}

fn printViolations(title: []const u8, violations: []const Violation) void {
    const separator: [80]u8 = @splat('=');
    std.debug.print("\n" ++ separator ++ "\n{s}\n" ++ separator ++ "\n\n", .{title});
    for (violations) |violation| {
        if (violation.pattern.len == 0) {
            std.debug.print("  {s}:{d}: {s}\n", .{
                violation.file_path,
                violation.line_number,
                violation.line_content,
            });
        } else {
            std.debug.print("  {s}:{d}: found `{s}` in: {s}\n", .{
                violation.file_path,
                violation.line_number,
                violation.pattern,
                violation.line_content,
            });
        }
    }
    std.debug.print("\n" ++ separator ++ "\n", .{});
}

fn checkTypeCheckerPatterns(io: std.Io, allocator: std.mem.Allocator) !void {
    var violations: std.ArrayList(Violation) = .empty;
    const roots = [_][]const u8{ "src/check", "src/layout", "src/eval" };
    for (roots) |root| {
        var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
            if (std.mem.endsWith(u8, entry.path, "_test.zig") or
                std.mem.find(u8, entry.path, "test/") != null or
                std.mem.startsWith(u8, entry.path, "test")) continue;

            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, entry.path });
            const content = try dir.readFileAlloc(io, entry.path, allocator, .limited(10 * 1024 * 1024));
            try scanTypeCheckerFile(allocator, full_path, content, &violations);
        }
    }
    if (violations.items.len != 0) {
        printViolations("FORBIDDEN TYPE-CHECKER STRING/BYTE PATTERN", violations.items);
        return error.CheckFailed;
    }
}

fn scanTypeCheckerFile(
    allocator: std.mem.Allocator,
    full_path: []const u8,
    content: []const u8,
    violations: *std.ArrayList(Violation),
) !void {
    const excluded_ranges = [_]ExcludedRange{
        .{ .file = "Check.zig", .start = 5530, .end = 5547 },
        .{ .file = "store.zig", .start = 340, .end = 355 },
        .{ .file = "cir_to_lir.zig", .start = 110, .end = 115 },
        .{ .file = "inspected.zig", .start = 226, .end = 232 },
        .{ .file = "inspected.zig", .start = 2211, .end = 2211 },
        .{ .file = "inspected.zig", .start = 3000, .end = 3004 },
        .{ .file = "inspected_run.zig", .start = 107, .end = 107 },
    };
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_number: usize = 1;
    while (lines.next()) |line| : (line_number += 1) {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        if (inExcludedRange(full_path, line_number, &excluded_ranges)) continue;

        var forbidden = false;
        if (std.mem.find(u8, line, "std.mem.")) |index| {
            const suffix = line[index + "std.mem.".len ..];
            forbidden = !(std.mem.startsWith(u8, suffix, "Allocator") or
                std.mem.startsWith(u8, suffix, "Alignment") or
                std.mem.startsWith(u8, suffix, "sort") or
                std.mem.startsWith(u8, suffix, "asBytes") or
                std.mem.startsWith(u8, suffix, "reverse") or
                std.mem.startsWith(u8, suffix, "alignForward") or
                std.mem.startsWith(u8, suffix, "order") or
                std.mem.startsWith(u8, suffix, "copyForwards"));
        }
        forbidden = forbidden or std.mem.find(u8, line, "findByString") != null;
        forbidden = forbidden or std.mem.find(u8, line, "findIdent") != null;
        forbidden = forbidden or std.mem.find(u8, line, "getMethodIdent") != null;
        if (forbidden) try violations.append(allocator, .{
            .file_path = full_path,
            .line_number = line_number,
            .line_content = try allocator.dupe(u8, trimmed),
        });
    }
}

const vendored_zig_marker = "Adapted from the Zig compiler";

fn checkEnumFromIntZero(io: std.Io, allocator: std.mem.Allocator) !void {
    var violations: std.ArrayList(Violation) = .empty;
    var dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    const pattern = "@enumFrom" ++ "Int(0)";
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const content = try dir.readFileAlloc(io, entry.path, allocator, .limited(10 * 1024 * 1024));
        if (std.mem.find(u8, content, vendored_zig_marker) != null) continue;
        const full_path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        var lines = std.mem.splitScalar(u8, content, '\n');
        var line_number: usize = 1;
        while (lines.next()) |line| : (line_number += 1) {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, trimmed, "//")) continue;
            if (std.mem.find(u8, line, pattern) != null) try violations.append(allocator, .{
                .file_path = full_path,
                .line_number = line_number,
                .line_content = try allocator.dupe(u8, trimmed),
            });
        }
    }
    if (violations.items.len != 0) {
        printViolations("FORBIDDEN ZERO-VALUED ENUM PLACEHOLDER", violations.items);
        return error.CheckFailed;
    }
}

fn checkUnusedSuppression(io: std.Io, allocator: std.mem.Allocator) !void {
    var violations: std.ArrayList(Violation) = .empty;
    var dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const content = try dir.readFileAlloc(io, entry.path, allocator, .limited(10 * 1024 * 1024));
        if (std.mem.find(u8, content, vendored_zig_marker) != null) continue;
        const full_path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        var lines = std.mem.splitScalar(u8, content, '\n');
        var line_number: usize = 1;
        while (lines.next()) |line| : (line_number += 1) {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (isUnusedSuppression(trimmed)) try violations.append(allocator, .{
                .file_path = full_path,
                .line_number = line_number,
                .line_content = try allocator.dupe(u8, trimmed),
            });
        }
    }
    if (violations.items.len != 0) {
        printViolations("UNUSED VARIABLE SUPPRESSION DETECTED", violations.items);
        return error.CheckFailed;
    }
}

fn isUnusedSuppression(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "_ = ") or !std.mem.endsWith(u8, line, ";")) return false;
    const identifier = line[4 .. line.len - 1];
    if (identifier.len == 0) return false;
    for (identifier) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '_' and char != '.') return false;
    }
    return true;
}

fn checkPanicUsage(io: std.Io, allocator: std.mem.Allocator) !void {
    var violations: std.ArrayList(Violation) = .empty;
    try scanPanicFile(io, allocator, "src/eval/interpreter.zig", &violations);

    var builtins = try std.Io.Dir.cwd().openDir(io, "src/builtins", .{ .iterate = true });
    defer builtins.close(io);
    var iter = builtins.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        if (std.mem.eql(u8, entry.name, "fuzz_sort.zig")) continue;
        const path = try std.fmt.allocPrint(allocator, "src/builtins/{s}", .{entry.name});
        try scanPanicFile(io, allocator, path, &violations);
    }
    if (violations.items.len != 0) {
        printViolations("FORBIDDEN PANIC IN RUNTIME CODE", violations.items);
        return error.CheckFailed;
    }
}

fn scanPanicFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    file_path: []const u8,
    violations: *std.ArrayList(Violation),
) !void {
    const excluded_ranges = [_]ExcludedRange{
        .{ .file = "utils.zig", .start = 60, .end = 214 },
        .{ .file = "Check.zig", .start = 5530, .end = 5547 },
    };
    const content = try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(50 * 1024 * 1024));
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_number: usize = 1;
    while (lines.next()) |line| : (line_number += 1) {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        const has_panic = std.mem.find(u8, line, "@panic(") != null or
            std.mem.find(u8, line, "std.debug.panic") != null;
        if (has_panic and std.mem.find(u8, line, "trace_modules") == null and
            !inExcludedRange(file_path, line_number, &excluded_ranges))
        {
            try violations.append(allocator, .{
                .file_path = file_path,
                .line_number = line_number,
                .line_content = try allocator.dupe(u8, trimmed),
            });
        }
    }
}

fn checkCliGlobalStdio(io: std.Io, allocator: std.mem.Allocator) !void {
    const file_path = "src/cli/main.zig";
    const content = try std.Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(10 * 1024 * 1024));
    const forbidden = [_][]const u8{
        "std.io.getStdOut()",
        "std.io.getStdErr()",
        "std.fs.File.stdout()",
        "std.fs.File.stderr()",
    };
    var violations: std.ArrayList(Violation) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_number: usize = 1;
    while (lines.next()) |line| : (line_number += 1) {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        for (forbidden) |pattern| {
            if (std.mem.find(u8, trimmed, pattern) != null) try violations.append(allocator, .{
                .file_path = file_path,
                .line_number = line_number,
                .line_content = try allocator.dupe(u8, trimmed),
                .pattern = pattern,
            });
        }
    }
    if (violations.items.len != 0) {
        printViolations("GLOBAL STDIO USAGE DETECTED IN CLI", violations.items);
        return error.CheckFailed;
    }
}

const TestAssetCoverageDir = struct {
    dir: []const u8,
    spec_files: []const []const u8,
};

const test_asset_coverage_dirs = [_]TestAssetCoverageDir{
    .{ .dir = "test/fx", .spec_files = &.{ "src/cli/test/fx_platform_test.zig", "src/cli/test/fx_test_specs.zig", "src/cli/test/parallel_cli_runner.zig" } },
    .{ .dir = "test/fx-open", .spec_files = &.{ "src/cli/test/platform_config.zig", "src/cli/test/parallel_cli_runner.zig" } },
    .{ .dir = "test/cli", .spec_files = &.{ "src/cli/test/parallel_cli_runner.zig", "src/compile/test/embedding_smoke.zig" } },
    .{ .dir = "test/package-effect-boundary", .spec_files = &.{"src/cli/test/parallel_cli_runner.zig"} },
    .{ .dir = "test/str", .spec_files = &.{ "src/cli/test/platform_config.zig", "src/cli/test/parallel_cli_runner.zig", "src/compile/coordinator.zig" } },
    .{ .dir = "test/echo", .spec_files = &.{ "src/cli/test/parallel_cli_runner.zig", "src/eval/test/builtin_doc_tests.zig" } },
};

fn isRocAppFile(contents: []const u8) bool {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        return std.mem.startsWith(u8, line, "app");
    }
    return false;
}

fn checkTestAssetCoverage(io: std.Io, allocator: std.mem.Allocator) !void {
    std.debug.print("---- checking test asset coverage ----\n", .{});
    var total_missing: usize = 0;
    var total_checked: usize = 0;
    for (test_asset_coverage_dirs) |config| {
        var dir = try std.Io.Dir.cwd().openDir(io, config.dir, .{ .iterate = true });
        defer dir.close(io);
        var app_files: std.ArrayList([]const u8) = .empty;
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".roc")) continue;
            const contents = try entry.dir.readFileAlloc(io, entry.basename, allocator, .limited(1024 * 1024));
            if (!isRocAppFile(contents)) continue;
            const relative_path = try allocator.dupe(u8, entry.path);
            std.mem.replaceScalar(u8, relative_path, std.fs.path.sep, '/');
            try app_files.append(allocator, relative_path);
        }
        std.mem.sort([]const u8, app_files.items, {}, struct {
            fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.order(u8, lhs, rhs) == .lt;
            }
        }.lessThan);

        var tested_files = std.StringHashMap(void).init(allocator);
        const prefix = try std.fmt.allocPrint(allocator, "{s}/", .{config.dir});
        for (config.spec_files) |spec_path| {
            const contents = try std.Io.Dir.cwd().readFileAlloc(io, spec_path, allocator, .limited(4 * 1024 * 1024));
            var lines = std.mem.splitScalar(u8, contents, '\n');
            while (lines.next()) |full_line| {
                const line = if (std.mem.find(u8, full_line, "//")) |index| full_line[0..index] else full_line;
                var start: usize = 0;
                while (std.mem.findPos(u8, line, start, prefix)) |index| {
                    const rest = line[index..];
                    if (std.mem.find(u8, rest, ".roc")) |roc_index| {
                        const filename = rest[prefix.len .. roc_index + 4];
                        try tested_files.put(try allocator.dupe(u8, filename), {});
                    }
                    start = index + 1;
                }
            }
        }

        var missing: usize = 0;
        for (app_files.items) |app_file| {
            total_checked += 1;
            if (!tested_files.contains(app_file)) {
                std.debug.print("missing spec entry: {s}/{s}\n", .{ config.dir, app_file });
                missing += 1;
            }
        }
        total_missing += missing;
    }
    if (total_missing != 0) return error.CheckFailed;
    std.debug.print("All {d} app .roc files across {d} asset directories are covered.\n", .{
        total_checked,
        test_asset_coverage_dirs.len,
    });
}

fn coverageSummary(
    io: std.Io,
    allocator: std.mem.Allocator,
    coverage_dir: []const u8,
    exe_name: []const u8,
    label: []const u8,
    min_coverage: f64,
) !void {
    const json_path = try std.fmt.allocPrint(allocator, "{s}/{s}/coverage.json", .{ coverage_dir, exe_name });
    const json_content = std.Io.Dir.cwd().readFileAlloc(io, json_path, allocator, .limited(10 * 1024 * 1024)) catch |err| {
        std.debug.print("Could not open coverage JSON at {s}: {}\n", .{ json_path, err });
        return;
    };
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidCoverageJson;
    const total_lines = jsonInteger(root, "total_lines");
    const covered_lines = jsonInteger(root, "covered_lines");
    if (total_lines == 0) return error.NoCoverageData;
    const percent = @as(f64, @floatFromInt(covered_lines)) /
        @as(f64, @floatFromInt(total_lines)) * 100.0;
    std.debug.print("{s} coverage: {d:.2}% ({d}/{d} lines)\n", .{
        label,
        percent,
        covered_lines,
        total_lines,
    });
    if (percent < min_coverage) return error.CoverageBelowMinimum;
}

fn jsonInteger(root: std.json.Value, key: []const u8) u64 {
    const value = root.object.get(key) orelse return 0;
    if (value != .integer or value.integer < 0) return 0;
    return @intCast(value.integer);
}

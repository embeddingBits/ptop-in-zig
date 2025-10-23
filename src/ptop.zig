const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const time = std.time;
const thread = std.Thread;
const fs = std.fs;

const REFRESH_RATE_MS = 100;
const TERM_WIDTH = 80;
const TERM_HEIGHT = 24;

var prev_cpu_total: u64 = 0;
var prev_cpu_non_idle: u64 = 0;

const SystemInfo = struct {
    cpu_usage: f64,
    memory_total: u64,
    memory_used: u64,
    memory_free: u64,
    processes: std.ArrayList(ProcessInfo),
};

const ProcessInfo = struct {
    pid: u32,
    name: []const u8,
    cpu_usage: f64,
    memory_usage: u64,
    state: []const u8,
    user: []const u8,
};

fn clearScreen() void {
    const stdout = std.io.getStdOut().writer();
    stdout.print("\x1B[2J\x1B[H", .{}) catch {};
}

fn getCpuUsage() !f64 {
    const file = try fs.openFileAbsolute("/proc/stat", .{});
    defer file.close();

    var buffer: [1024]u8 = undefined;
    const bytes_read = try file.readAll(&buffer);
    const content = buffer[0..bytes_read];

    if (mem.indexOf(u8, content, "cpu ") == null) {
        return error.InvalidProcStat;
    }

    var line_it = std.mem.splitIterator(u8, content, .{"\n"});
    const cpu_line = line_it.next() orelse return error.InvalidProcStat;

    var values_it = std.mem.splitIterator(u8, cpu_line, .{" "});
    _ = values_it.next() orelse return error.InvalidProcStat; // Skip "cpu "

    const user_str = values_it.next() orelse "0";
    const nice_str = values_it.next() orelse "0";
    const system_str = values_it.next() orelse "0";
    const idle_str = values_it.next() orelse "0";
    const iowait_str = values_it.next() orelse "0";
    const irq_str = values_it.next() orelse "0";
    const softirq_str = values_it.next() orelse "0";
    const steal_str = values_it.next() orelse "0";

    const user = try std.fmt.parseInt(u64, user_str, 10);
    const nice = try std.fmt.parseInt(u64, nice_str, 10);
    const system = try std.fmt.parseInt(u64, system_str, 10);
    const idle = try std.fmt.parseInt(u64, idle_str, 10);
    const iowait = try std.fmt.parseInt(u64, iowait_str, 10);
    const irq = try std.fmt.parseInt(u64, irq_str, 10);
    const softirq = try std.fmt.parseInt(u64, softirq_str, 10);
    const steal = try std.fmt.parseInt(u64, steal_str, 10);

    const total = user + nice + system + idle + iowait + irq + softirq + steal;
    const idle_total = idle + iowait;
    const non_idle = total - idle_total;

    const cpu_usage: f64 = if (prev_cpu_total == 0) 0.0 else blk: {
        const delta_total = total - prev_cpu_total;
        const delta_non_idle = non_idle - prev_cpu_non_idle;
        break :blk @as(f64, @floatFromInt(delta_non_idle)) / @as(f64, @floatFromInt(delta_total)) * 100.0;
    };

    prev_cpu_total = total;
    prev_cpu_non_idle = non_idle;

    return cpu_usage;
}

fn getMemoryInfo() !struct { total: u64, used: u64, free: u64 } {
    const file = try fs.openFileAbsolute("/proc/meminfo", .{});
    defer file.close();

    var buffer: [4096]u8 = undefined;
    const bytes_read = try file.readAll(&buffer);
    const content = buffer[0..bytes_read];

    var total: u64 = 0;
    var free: u64 = 0;
    var available: u64 = 0;

    var lines_it = std.mem.splitIterator(u8, content, .{"\n"});
    while (lines_it.next()) |line| {
        if (mem.startsWith(u8, line, "MemTotal:")) {
            var tokens = std.mem.splitIterator(u8, line, .{ " ", "\t" });
            _ = tokens.next(); // Skip "MemTotal:"
            const val_str = tokens.next() orelse "0";
            total = try std.fmt.parseInt(u64, val_str, 10);
        } else if (mem.startsWith(u8, line, "MemFree:")) {
            var tokens = std.mem.splitIterator(u8, line, .{ " ", "\t" });
            _ = tokens.next(); // Skip "MemFree:"
            const val_str = tokens.next() orelse "0";
            free = try std.fmt.parseInt(u64, val_str, 10);
        } else if (mem.startsWith(u8, line, "MemAvailable:")) {
            var tokens = std.mem.splitIterator(u8, line, .{ " ", "\t" });
            _ = tokens.next(); // Skip "MemAvailable:"
            const val_str = tokens.next() orelse "0";
            available = try std.fmt.parseInt(u64, val_str, 10);
        }
    }

    // Convert from KB to bytes
    total *= 1024;
    free *= 1024;
    available *= 1024;

    return .{
        .total = total,
        .free = available, // Use available as "free" since it's more representative
        .used = total - available,
    };
}

fn getProcessList(allocator: mem.Allocator) !std.ArrayList(ProcessInfo) {
    var processes = std.ArrayList(ProcessInfo).init(allocator);

    var proc_dir = try fs.openDirAbsolute("/proc", .{ .iterate = true });
    defer proc_dir.close();

    var iter = proc_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        // Check if directory name is a number (PID)
        const pid = std.fmt.parseInt(u32, entry.name, 10) catch continue;

        // Read process name from /proc/[pid]/comm
        var path_buf: [100]u8 = undefined;
        const comm_path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid});

        const comm_file = fs.openFileAbsolute(comm_path, .{}) catch continue;
        defer comm_file.close();

        var name_buf: [100]u8 = undefined;
        const read_len = try comm_file.reader().readUntilDelimiterOrEof(&name_buf, '\n');
        const name_slice = name_buf[0 .. (read_len orelse name_buf.len)];
        if (name_slice.len == 0) continue;

        // In a real implementation, we'd read CPU and memory usage from /proc/[pid]/stat
        // and other files. For this demo, we'll generate synthetic values.
        const process_info = ProcessInfo{
            .pid = pid,
            .name = try allocator.dupe(u8, name_slice),
            .cpu_usage = @mod(@as(f64, @floatFromInt(pid)), 10.0),
            .memory_usage = @as(u64, pid) * 1024 * 1024,
            .state = "R",
            .user = "user",
        };

        try processes.append(process_info);

        // Limit to 20 processes for the demo
        if (processes.items.len >= 20) break;
    }

    return processes;
}

fn getSystemInfo(allocator: mem.Allocator) !SystemInfo {
    const cpu_usage = try getCpuUsage();
    const memory = try getMemoryInfo();
    const processes = try getProcessList(allocator);

    return SystemInfo{
        .cpu_usage = cpu_usage,
        .memory_total = memory.total,
        .memory_used = memory.used,
        .memory_free = memory.free,
        .processes = processes,
    };
}

fn formatBytes(bytes: u64) [20]u8 {
    var buf: [20]u8 = undefined;
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var size: f64 = @floatFromInt(bytes);
    var unit_index: usize = 0;

    while (size > 1024 and unit_index < units.len - 1) {
        size /= 1024;
        unit_index += 1;
    }

    _ = std.fmt.bufPrint(&buf, "{d:.2} {s}", .{ size, units[unit_index] }) catch unreachable;
    return buf;
}

fn drawProgressBar(value: f64, width: usize, writer: anytype) !void {
    const filled_width = @as(usize, @intFromFloat(value / 100.0 * @as(f64, @floatFromInt(width))));
    const empty_width = width - filled_width;

    try writer.writeAll("[");

    // Select color based on value
    if (value < 60) {
        try writer.writeAll("\x1B[32m"); // Green
    } else if (value < 85) {
        try writer.writeAll("\x1B[33m"); // Yellow
    } else {
        try writer.writeAll("\x1B[31m"); // Red
    }

    var i: usize = 0;
    while (i < filled_width) : (i += 1) {
        try writer.writeAll("■");
    }

    try writer.writeAll("\x1B[0m"); // Reset color

    i = 0;
    while (i < empty_width) : (i += 1) {
        try writer.writeAll("□");
    }

    try writer.writeAll("]");
}

fn drawUI(info: SystemInfo) !void {
    clearScreen();

    const stdout = std.io.getStdOut().writer();

    // Header with system info
    try stdout.print("\x1B[1;36m╔══════════════════ ZigTop System Monitor ═══════════════════╗\x1B[0m\n", .{});

    // CPU usage
    try stdout.print("\x1B[1;32m CPU Usage: {d:.1}%\x1B[0m ", .{info.cpu_usage});
    try drawProgressBar(info.cpu_usage, 40, stdout);
    try stdout.print("\n", .{});

    // Memory usage
    const mem_percent = @as(f64, @floatFromInt(info.memory_used)) / @as(f64, @floatFromInt(info.memory_total)) * 100.0;
    const mem_used_fmt = formatBytes(info.memory_used);
    const mem_total_fmt = formatBytes(info.memory_total);

    try stdout.print("\x1B[1;34m Memory: {s}/{s} ({d:.1}%)\x1B[0m ", .{ mem_used_fmt, mem_total_fmt, mem_percent });
    try drawProgressBar(mem_percent, 40, stdout);
    try stdout.print("\n", .{});

    // Process list header
    try stdout.print("\x1B[1;36m╠═════ Processes ═════════════════════════════════════════════╣\x1B[0m\n", .{});
    try stdout.print("\x1B[1m PID USER CPU%% MEM STATE NAME\x1B[0m\n", .{});

    // Process list
    for (info.processes.items) |proc| {
        const mem_usage_fmt = formatBytes(proc.memory_usage);
        try stdout.print(" {d:<6} {s:<8} {d:>5.1}% {s:<7} {s:<5} {s}\n",
            .{ proc.pid, proc.user, proc.cpu_usage, mem_usage_fmt, proc.state, proc.name });
    }

    // Footer
    try stdout.print("\x1B[1;36m╚═══════════════════════════════════════════════════════════╝\x1B[0m\n", .{});
    try stdout.print(" Press Ctrl+C to quit\n", .{});
}

fn freeSystemInfo(info: *SystemInfo, allocator: mem.Allocator) void {
    for (info.processes.items) |proc| {
        allocator.free(proc.name);
    }
    info.processes.deinit();
}

pub fn main() !void {
    // Setup terminal for raw mode if needed
    // In a real implementation, we'd use a terminal library like ncurses or termion

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Starting ZigTop System Monitor... (Press Ctrl+C to exit)\n", .{});
    thread.sleep(1 * time.ns_per_s); // Give user a moment to read

    // Main loop
    while (true) {
        var info = try getSystemInfo(allocator);
        defer freeSystemInfo(&info, allocator);

        try drawUI(info);

        // Wait for refresh
        thread.sleep(REFRESH_RATE_MS * time.ns_per_ms);
    }
}

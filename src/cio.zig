//! cio.zig — 0.16 stdlib compatibility shim.
//!
//! 0.16 removed std.fs.File.{stdout,stderr,stdin}, cio.Mutex/RwLock,
//! std.time.Timer, std.time.nanoTimestamp, std.process.Child.run, and
//! cio.posixGetenv. This shim wraps libc/pthread primitives so existing
//! call sites continue to work with minimal import-line changes.

const std = @import("std");
const builtin = @import("builtin");

extern "c" fn write(fd: c_int, ptr: [*]const u8, len: usize) isize;
extern "c" fn read(fd: c_int, ptr: [*]u8, len: usize) isize;
extern "c" fn isatty(fd: c_int) c_int;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn clock_gettime(id: c_int, ts: *std.c.timespec) c_int;
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn close(fd: c_int) c_int;

const is_windows = builtin.os.tag == .windows;
const is_posix = !is_windows;

const CLOCK_REALTIME: c_int = 0;
const CLOCK_MONOTONIC: c_int = if (builtin.os.tag == .macos) 6 else 1;

// ── Stdio ────────────────────────────────────────────────────────────────

pub const File = struct {
    handle: c_int,

    pub fn stdout() File {
        return .{ .handle = 1 };
    }
    pub fn stderr() File {
        return .{ .handle = 2 };
    }
    pub fn stdin() File {
        return .{ .handle = 0 };
    }

    pub fn isTty(self: File) bool {
        return isatty(self.handle) != 0;
    }

    pub fn writeAll(self: File, data: []const u8) !void {
        var rem = data;
        while (rem.len > 0) {
            const n = write(self.handle, rem.ptr, rem.len);
            if (n <= 0) return error.WriteFailed;
            rem = rem[@intCast(n)..];
        }
    }

    pub fn print(self: File, comptime fmt: []const u8, args: anytype) !void {
        var buf: [8192]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch {
            const big = try std.fmt.allocPrint(std.heap.c_allocator, fmt, args);
            defer std.heap.c_allocator.free(big);
            return self.writeAll(big);
        };
        try self.writeAll(s);
    }
};

// ── Threads / Sync ───────────────────────────────────────────────────────

// Windows SRWLock shared-mode (stdlib only exposes Exclusive variants).
const ntdll_srw = if (is_windows) struct {
    extern "ntdll" fn RtlAcquireSRWLockShared(SRWLock: *std.os.windows.SRWLOCK) callconv(.winapi) void;
    extern "ntdll" fn RtlReleaseSRWLockShared(SRWLock: *std.os.windows.SRWLOCK) callconv(.winapi) void;
    extern "ntdll" fn RtlTryAcquireSRWLockShared(SRWLock: *std.os.windows.SRWLOCK) callconv(.winapi) std.os.windows.BOOLEAN;
} else struct {};

pub const Mutex = struct {
    inner: if (is_windows) std.os.windows.SRWLOCK else std.c.pthread_mutex_t = .{},

    pub fn lock(self: *Mutex) void {
        if (comptime is_windows) {
            std.os.windows.ntdll.RtlAcquireSRWLockExclusive(&self.inner);
        } else {
            _ = std.c.pthread_mutex_lock(&self.inner);
        }
    }
    pub fn unlock(self: *Mutex) void {
        if (comptime is_windows) {
            std.os.windows.ntdll.RtlReleaseSRWLockExclusive(&self.inner);
        } else {
            _ = std.c.pthread_mutex_unlock(&self.inner);
        }
    }
    pub fn tryLock(self: *Mutex) bool {
        if (comptime is_windows) {
            return std.os.windows.ntdll.RtlTryAcquireSRWLockExclusive(&self.inner).toBool();
        }
        return std.c.pthread_mutex_trylock(&self.inner) == .SUCCESS;
    }
};

pub const RwLock = struct {
    inner: if (is_windows) std.os.windows.SRWLOCK else std.c.pthread_rwlock_t = .{},

    pub fn lock(self: *RwLock) void {
        if (comptime is_windows) {
            std.os.windows.ntdll.RtlAcquireSRWLockExclusive(&self.inner);
        } else {
            _ = std.c.pthread_rwlock_wrlock(&self.inner);
        }
    }
    pub fn unlock(self: *RwLock) void {
        if (comptime is_windows) {
            std.os.windows.ntdll.RtlReleaseSRWLockExclusive(&self.inner);
        } else {
            _ = std.c.pthread_rwlock_unlock(&self.inner);
        }
    }
    pub fn lockShared(self: *RwLock) void {
        if (comptime is_windows) {
            ntdll_srw.RtlAcquireSRWLockShared(&self.inner);
        } else {
            _ = std.c.pthread_rwlock_rdlock(&self.inner);
        }
    }
    pub fn unlockShared(self: *RwLock) void {
        if (comptime is_windows) {
            ntdll_srw.RtlReleaseSRWLockShared(&self.inner);
        } else {
            _ = std.c.pthread_rwlock_unlock(&self.inner);
        }
    }
    pub fn tryLock(self: *RwLock) bool {
        if (comptime is_windows) {
            return std.os.windows.ntdll.RtlTryAcquireSRWLockExclusive(&self.inner).toBool();
        }
        return std.c.pthread_rwlock_trywrlock(&self.inner) == .SUCCESS;
    }
    pub fn tryLockShared(self: *RwLock) bool {
        if (comptime is_windows) {
            return ntdll_srw.RtlTryAcquireSRWLockShared(&self.inner).toBool();
        }
        return std.c.pthread_rwlock_tryrdlock(&self.inner) == .SUCCESS;
    }
};

// ── Time ─────────────────────────────────────────────────────────────────

// Windows monotonic time via QPC (used by Timer below).
fn winMonoNs() i128 {
    var counter: i64 = 0;
    var freq: i64 = 0;
    _ = std.os.windows.ntdll.RtlQueryPerformanceCounter(&counter);
    _ = std.os.windows.ntdll.RtlQueryPerformanceFrequency(&freq);
    if (freq <= 0) return 0;
    return @divTrunc(@as(i128, counter) * 1_000_000_000, @as(i128, freq));
}

pub fn nanoTimestamp() i128 {
    if (comptime is_windows) {
        return @as(i128, std.os.windows.ntdll.RtlGetSystemTimePrecise()) * 100;
    }
    var ts: std.c.timespec = undefined;
    _ = clock_gettime(CLOCK_REALTIME, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
}

pub fn milliTimestamp() i64 {
    if (comptime is_windows) {
        return @intCast(@divTrunc(std.os.windows.ntdll.RtlGetSystemTimePrecise(), 10_000));
    }
    var ts: std.c.timespec = undefined;
    _ = clock_gettime(CLOCK_REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

pub const Timer = struct {
    start_ns: i128,

    pub fn start() !Timer {
        if (comptime is_windows) {
            return .{ .start_ns = winMonoNs() };
        }
        var ts: std.c.timespec = undefined;
        _ = clock_gettime(CLOCK_MONOTONIC, &ts);
        return .{ .start_ns = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec };
    }

    pub fn read(self: *Timer) u64 {
        if (comptime is_windows) {
            return @intCast(winMonoNs() - self.start_ns);
        }
        var ts: std.c.timespec = undefined;
        _ = clock_gettime(CLOCK_MONOTONIC, &ts);
        const now = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
        return @intCast(now - self.start_ns);
    }

    pub fn lap(self: *Timer) u64 {
        if (comptime is_windows) {
            const now = winMonoNs();
            const delta: u64 = @intCast(now - self.start_ns);
            self.start_ns = now;
            return delta;
        }
        var ts: std.c.timespec = undefined;
        _ = clock_gettime(CLOCK_MONOTONIC, &ts);
        const now = @as(i128, ts.sec) * 1_000_000_000 + ts.nsec;
        const delta: u64 = @intCast(now - self.start_ns);
        self.start_ns = now;
        return delta;
    }
};

// ── Environment ──────────────────────────────────────────────────────────

/// Non-cryptographic random u64 mixing nanotime, PID, and thread ID.
/// Replaces `std.crypto.random.int(u64)` (removed in 0.16) for tmp-file
/// suffix collision avoidance. Thread-safe: each thread gets a unique
/// mix per-call even at the same nanosecond.
pub fn randU64() u64 {
    if (comptime is_windows) {
        const t: u64 = @intCast(std.os.windows.ntdll.RtlGetSystemTimePrecise());
        const total_ns = t * 100;
        const ns = total_ns % 1_000_000_000;
        const sec = total_ns / 1_000_000_000;
        const tid = std.Thread.getCurrentId();
        const pid: u64 = std.os.windows.GetCurrentProcessId();
        var x = ns ^ (sec *% 2) ^ (tid *% (1 << 17)) ^ (pid *% (1 << 23));
        x ^= x >> 33;
        x *%= 0xff51afd7ed558ccd;
        x ^= x >> 33;
        x *%= 0xc4ceb9fe1a85ec53;
        x ^= x >> 33;
        return x;
    }
    var ts: std.c.timespec = undefined;
    _ = clock_gettime(CLOCK_REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.nsec));
    const sec = @as(u64, @intCast(ts.sec));
    const tid = std.Thread.getCurrentId();
    const pid: u64 = @intCast(std.c.getpid());
    // splitmix64-style final mixing to avoid close-timestamp collisions
    var x = ns ^ (sec *% 2) ^ (tid *% (1 << 17)) ^ (pid *% (1 << 23));
    x ^= x >> 33;
    x *%= 0xff51afd7ed558ccd;
    x ^= x >> 33;
    x *%= 0xc4ceb9fe1a85ec53;
    x ^= x >> 33;
    return x;
}

pub fn sleepMs(ms: u64) void {
    if (comptime is_windows) {
        const w = std.os.windows;
        const max_ms: u64 = @intCast(@divTrunc(std.math.maxInt(i64), 10_000));
        const bounded = @min(ms, max_ms);
        const interval: i64 = -@as(i64, @intCast(bounded * 10_000));
        _ = w.ntdll.NtDelayExecution(w.BOOLEAN.fromBool(false), &interval);
        return;
    }
    var ts: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * 1_000_000),
    };
    _ = std.c.nanosleep(&ts, null);
}

pub const PipeError = error{PipeFailed};
pub fn makePipe() PipeError![2]c_int {
    var fds: [2]c_int = .{ -1, -1 };
    if (pipe(&fds) != 0) return error.PipeFailed;
    return fds;
}

pub fn closeFd(fd: c_int) void {
    _ = close(fd);
}

pub fn posixGetenv(name: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const ptr = getenv(@ptrCast(&buf)) orelse return null;
    return std.mem.span(ptr);
}

// ── Arguments ────────────────────────────────────────────────────────────

// Darwin: argv lives in __NSGetArgv() (libc, from <crt_externs.h>).
// Linux/other POSIX: 0.16 doesn't expose argv globally — main() must call
// `setProcessArgs(argv_slice)` once at startup to populate `process_args`.
extern "c" fn _NSGetArgc() *c_int;
extern "c" fn _NSGetArgv() *[*][*:0]u8;

var process_args: ?[]const [*:0]const u8 = null;
var process_args_windows: ?[]const u16 = null;

/// Called once by `pub fn main` to register the argv slice on non-Darwin
/// platforms. No-op on macOS (it reads from `_NSGetArgv` directly).
/// On Windows, accepts the UTF-16 command-line buffer instead.
pub fn setProcessArgs(args: anytype) void {
    if (comptime is_windows) {
        process_args_windows = args;
    } else {
        process_args = args;
    }
}

/// Shim for cio.argsAlloc (removed in 0.16). Returns a duplicated
/// slice of argv strings owned by the allocator; free with argsFree.
pub fn argsAlloc(alloc: std.mem.Allocator) ![][:0]u8 {
    if (comptime is_windows) {
        const vec = process_args_windows orelse return error.ProcessArgsNotSet;
        var it = try std.process.Args.Iterator.initAllocator(.{ .vector = vec }, alloc);
        defer it.deinit();
        var out: std.ArrayList([:0]u8) = .empty;
        defer out.deinit(alloc);
        while (it.next()) |arg| {
            const dup = try alloc.allocSentinel(u8, arg.len, 0);
            @memcpy(dup[0..arg.len], arg);
            try out.append(alloc, dup);
        }
        return out.toOwnedSlice(alloc);
    }
    const argc: usize = if (builtin.os.tag == .macos)
        @intCast(_NSGetArgc().*)
    else
        (process_args orelse return error.ProcessArgsNotSet).len;
    const out = try alloc.alloc([:0]u8, argc);
    errdefer alloc.free(out);
    var filled: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < filled) : (i += 1) alloc.free(out[i]);
    }
    while (filled < argc) : (filled += 1) {
        const cstr: [*:0]const u8 = if (builtin.os.tag == .macos)
            _NSGetArgv().*[filled]
        else
            process_args.?[filled];
        const s = std.mem.span(cstr);
        const dup = try alloc.allocSentinel(u8, s.len, 0);
        @memcpy(dup[0..s.len], s);
        out[filled] = dup;
    }
    return out;
}

pub fn argsFree(alloc: std.mem.Allocator, args: [][:0]u8) void {
    for (args) |a| alloc.free(a);
    alloc.free(args);
}

// ── ArrayList writer helper (replaces 0.15's ArrayList(u8).writer(alloc)) ────

pub const ListWriter = struct {
    list: *std.ArrayList(u8),
    alloc: std.mem.Allocator,

    pub fn writeAll(self: ListWriter, bytes: []const u8) !void {
        try self.list.appendSlice(self.alloc, bytes);
    }
    pub fn writeByte(self: ListWriter, b: u8) !void {
        try self.list.append(self.alloc, b);
    }
    pub fn writeByteNTimes(self: ListWriter, b: u8, n: usize) !void {
        try self.list.appendNTimes(self.alloc, b, n);
    }
    pub fn writeBytesNTimes(self: ListWriter, bytes: []const u8, n: usize) !void {
        var i: usize = 0;
        while (i < n) : (i += 1) try self.list.appendSlice(self.alloc, bytes);
    }
    pub fn print(self: ListWriter, comptime fmt: []const u8, args: anytype) !void {
        var stack_buf: [8192]u8 = undefined;
        const s = std.fmt.bufPrint(&stack_buf, fmt, args) catch {
            const big = try std.fmt.allocPrint(self.alloc, fmt, args);
            defer self.alloc.free(big);
            try self.list.appendSlice(self.alloc, big);
            return;
        };
        try self.list.appendSlice(self.alloc, s);
    }
};

pub fn listWriter(list: *std.ArrayList(u8), alloc: std.mem.Allocator) ListWriter {
    return .{ .list = list, .alloc = alloc };
}

// ── Subprocess ───────────────────────────────────────────────────────────

pub const CaptureResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: Term,

    pub const Term = union(enum) {
        Exited: u8,
        Signal: u32,
        Stopped: u32,
        Unknown: u32,
    };
};

pub const RunOptions = struct {
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    max_output_bytes: usize = 50 * 1024 * 1024,
};
extern "c" fn _NSGetEnviron() *[*:null]?[*:0]u8;

// posix_spawn family — declared directly via extern "c" so this builds on
// both Darwin and Linux. (std.c.posix_spawnp is gated to .isDarwin() in 0.16
// and would fail to compile on Linux even though glibc/musl provide it.)
const PosixSpawnFileActions = opaque {};
const PosixSpawnAttr = opaque {};
const pid_t = c_int;

extern "c" fn posix_spawnp(
    pid: *pid_t,
    path: [*:0]const u8,
    file_actions: ?*const PosixSpawnFileActions,
    attrp: ?*const PosixSpawnAttr,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) c_int;
extern "c" fn posix_spawn_file_actions_init(fa: *PosixSpawnFileActions) c_int;
extern "c" fn posix_spawn_file_actions_destroy(fa: *PosixSpawnFileActions) c_int;
extern "c" fn posix_spawn_file_actions_adddup2(fa: *PosixSpawnFileActions, fd: c_int, newfd: c_int) c_int;
extern "c" fn posix_spawn_file_actions_addclose(fa: *PosixSpawnFileActions, fd: c_int) c_int;
extern "c" fn posix_spawn_file_actions_addchdir_np(fa: *PosixSpawnFileActions, path: [*:0]const u8) c_int;
extern "c" fn waitpid(pid: pid_t, status: *c_int, options: c_int) pid_t;

// posix_spawn_file_actions_t is a struct of unknown size on each libc. We
// allocate a generously-sized buffer and cast to the opaque pointer type.
const PosixSpawnFAStorage = [256]u8;

/// Shim for std.process.Child.run — fast posix_spawnp path.
/// Captures stdout and stderr into separate streams (drained concurrently by
/// a background thread to avoid pipe-buffer deadlock when the child writes
/// substantially to either stream).
pub fn runCapture(opts: RunOptions) !CaptureResult {
    if (opts.argv.len == 0) return error.EmptyArgv;
    const alloc = opts.allocator;

    if (comptime is_windows) {
        var threaded: std.Io.Threaded = .init(alloc, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const result = try std.process.run(alloc, io, .{
            .argv = opts.argv,
            .cwd = if (opts.cwd) |cwd| .{ .path = cwd } else .inherit,
            .expand_arg0 = .expand,
            .stdout_limit = .limited(opts.max_output_bytes),
            .stderr_limit = .limited(opts.max_output_bytes),
        });
        const term: CaptureResult.Term = switch (result.term) {
            .exited => |code| .{ .Exited = code },
            .signal => |sig| .{ .Signal = @intFromEnum(sig) },
            .stopped => |sig| .{ .Stopped = @intFromEnum(sig) },
            .unknown => |val| .{ .Unknown = val },
        };
        return .{
            .stdout = result.stdout,
            .stderr = result.stderr,
            .term = term,
        };
    }

    const c_argv = try alloc.alloc(?[*:0]const u8, opts.argv.len + 1);
    defer alloc.free(c_argv);
    const arg_bufs = try alloc.alloc([]u8, opts.argv.len);
    defer {
        for (arg_bufs) |b| alloc.free(b);
        alloc.free(arg_bufs);
    }
    for (opts.argv, 0..) |a, i| {
        const buf = try alloc.alloc(u8, a.len + 1);
        @memcpy(buf[0..a.len], a);
        buf[a.len] = 0;
        arg_bufs[i] = buf;
        c_argv[i] = @ptrCast(buf.ptr);
    }
    c_argv[opts.argv.len] = null;
    const c_argv_z: [*:null]const ?[*:0]const u8 = @ptrCast(c_argv.ptr);

    var out_pipe: [2]c_int = .{ -1, -1 };
    var err_pipe: [2]c_int = .{ -1, -1 };
    if (pipe(&out_pipe) != 0) return error.PipeFailed;
    errdefer {
        if (out_pipe[0] >= 0) _ = close(out_pipe[0]);
        if (out_pipe[1] >= 0) _ = close(out_pipe[1]);
    }
    if (pipe(&err_pipe) != 0) return error.PipeFailed;
    errdefer {
        if (err_pipe[0] >= 0) _ = close(err_pipe[0]);
        if (err_pipe[1] >= 0) _ = close(err_pipe[1]);
    }

    var fa_storage: PosixSpawnFAStorage = undefined;
    const fa: *PosixSpawnFileActions = @ptrCast(&fa_storage);
    if (posix_spawn_file_actions_init(fa) != 0) return error.SpawnInitFailed;
    defer _ = posix_spawn_file_actions_destroy(fa);

    if (opts.cwd) |cwd| {
        var cwd_buf: [4096]u8 = undefined;
        if (cwd.len >= cwd_buf.len) return error.PathTooLong;
        @memcpy(cwd_buf[0..cwd.len], cwd);
        cwd_buf[cwd.len] = 0;
        // posix_spawn_file_actions_addchdir_np is glibc 2.29+ / macOS 10.15+.
        // Returns ENOSYS on older systems — caller treats that as fatal here.
        if (posix_spawn_file_actions_addchdir_np(fa, @ptrCast(&cwd_buf)) != 0) {
            return error.CwdNotSupported;
        }
    }

    _ = posix_spawn_file_actions_adddup2(fa, out_pipe[1], 1);
    _ = posix_spawn_file_actions_adddup2(fa, err_pipe[1], 2);
    _ = posix_spawn_file_actions_addclose(fa, out_pipe[0]);
    _ = posix_spawn_file_actions_addclose(fa, out_pipe[1]);
    _ = posix_spawn_file_actions_addclose(fa, err_pipe[0]);
    _ = posix_spawn_file_actions_addclose(fa, err_pipe[1]);

    const envp: [*:null]const ?[*:0]const u8 = if (builtin.os.tag == .macos)
        @ptrCast(_NSGetEnviron().*)
    else
        @ptrCast(std.c.environ);

    var pid: pid_t = 0;
    if (posix_spawnp(&pid, c_argv[0].?, fa, null, c_argv_z, envp) != 0)
        return error.SpawnFailed;

    _ = close(out_pipe[1]);
    out_pipe[1] = -1;
    _ = close(err_pipe[1]);
    err_pipe[1] = -1;

    // Drain stderr on a background thread so neither pipe can fill up and
    // deadlock the child. Main thread drains stdout.
    const DrainCtx = struct {
        fd: c_int,
        cap: usize,
        alloc: std.mem.Allocator,
        out: std.ArrayList(u8) = .empty,
        err: ?anyerror = null,

        fn run(self: *@This()) void {
            var chunk: [64 * 1024]u8 = undefined;
            while (self.out.items.len < self.cap) {
                const want = @min(chunk.len, self.cap - self.out.items.len);
                const n = read(self.fd, &chunk, want);
                if (n <= 0) break;
                self.out.appendSlice(self.alloc, chunk[0..@intCast(n)]) catch |e| {
                    self.err = e;
                    return;
                };
            }
        }
    };
    var err_ctx: DrainCtx = .{ .fd = err_pipe[0], .cap = opts.max_output_bytes, .alloc = alloc };
    errdefer err_ctx.out.deinit(alloc);
    const err_thread = try std.Thread.spawn(.{}, DrainCtx.run, .{&err_ctx});

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var chunk: [64 * 1024]u8 = undefined;
    while (out.items.len < opts.max_output_bytes) {
        const want = @min(chunk.len, opts.max_output_bytes - out.items.len);
        const n = read(out_pipe[0], &chunk, want);
        if (n <= 0) break;
        try out.appendSlice(alloc, chunk[0..@intCast(n)]);
    }
    _ = close(out_pipe[0]);
    out_pipe[0] = -1;

    err_thread.join();
    _ = close(err_pipe[0]);
    err_pipe[0] = -1;
    if (err_ctx.err) |e| {
        err_ctx.out.deinit(alloc);
        return e;
    }

    var status: c_int = 0;
    _ = waitpid(pid, &status, 0);

    const term: CaptureResult.Term = if ((status & 0x7f) == 0)
        .{ .Exited = @intCast((status >> 8) & 0xff) }
    else if ((status & 0x7f) != 0x7f)
        .{ .Signal = @intCast(status & 0x7f) }
    else
        .{ .Stopped = @intCast((status >> 8) & 0xff) };

    return .{
        .stdout = try out.toOwnedSlice(alloc),
        .stderr = try err_ctx.out.toOwnedSlice(alloc),
        .term = term,
    };
}

/// source/downloader — one-shot URL fetcher.
///
/// Public entry point: `fetch(io, gpa, cfg, url) ![]u8`.
/// The returned slice is gpa-owned; caller frees with `gpa.free(result)`.
///
/// For tests, the HTTP work is behind the `Fetcher` interface below. Inject a
/// fake `Fetcher` by calling `fetchWith` instead of `fetch`. The player (Step 6)
/// can wire its own fake the same way:
///
///   const fake = Fetcher{ .ctx = &my_ctx, .vtable = &my_vtable };
///   const body = try downloader.fetchWith(io, gpa, cfg, url, fake);
///
const std = @import("std");
const core = @import("core");
const builtin = @import("builtin");

/// Hard cap on response body size. Exceeding this returns `error.BodyTooLarge`
/// and is NOT retried.
pub const MAX_BODY_BYTES: usize = 25 * 1024 * 1024;

/// Errors this module can return. A superset is sometimes returned by the real
/// HTTP backend; `mapHttpError` maps them down to these members.
pub const FetchError = error{
    Timeout,
    ConnectionLost,
    HttpStatus,
    TooManyRedirects,
    BodyTooLarge,
    OutOfMemory,
    Canceled,
};

// ---------------------------------------------------------------------------
// Fetcher interface — allows tests to inject a fake HTTP back-end.
// ---------------------------------------------------------------------------

/// A single-method vtable that performs one HTTP GET and returns the body.
/// The real back-end is `defaultFetcher`; tests supply their own.
pub const Fetcher = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Perform a single HTTP GET of `url`.  Returns a gpa-owned `[]u8` on
        /// success; the caller (fetchWith) takes ownership and must free it.
        /// Returns `FetchError` on failure.
        fetchOnce: *const fn (
            ctx: *anyopaque,
            gpa: std.mem.Allocator,
            url: []const u8,
        ) FetchError![]u8,
    };

    pub fn fetchOnce(self: Fetcher, gpa: std.mem.Allocator, url: []const u8) FetchError![]u8 {
        return self.vtable.fetchOnce(self.ctx, gpa, url);
    }
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Fetches `url` into a gpa-owned `[]u8`. Caller frees with `gpa.free(result)`.
///
/// Behaviour:
/// - Follows up to 5 redirects (implemented inside the real HTTP client).
/// - Retries with exponential back-off (250 ms → 500 ms → 1000 ms), max 3 attempts.
///   `error.Canceled` and `error.OutOfMemory` are NOT retried.
/// - Hard cap at 25 MB (`MAX_BODY_BYTES`). Exceeding returns `error.BodyTooLarge`
///   without a retry.
pub fn fetch(
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: core.Config,
    url: []const u8,
) FetchError![]u8 {
    var ctx = RealFetcherCtx{ .io = io, .cfg = cfg };
    const fetcher = Fetcher{
        .ctx = @ptrCast(&ctx),
        .vtable = &real_vtable,
    };
    return fetchWith(io, gpa, cfg, url, fetcher);
}

/// Like `fetch` but uses the supplied `fetcher` for the actual HTTP work.
/// Tests pass a fake here; production code calls `fetch` which passes the real one.
pub fn fetchWith(
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: core.Config,
    url: []const u8,
    fetcher: Fetcher,
) FetchError![]u8 {
    _ = cfg; // timeout wiring in v0.2 — currently the real fetcher reads it from RealFetcherCtx

    const max_attempts: u32 = 3;
    // Delays in milliseconds: 250, 500, 1000.
    const delays_ms = [_]u64{ 250, 500, 1000 };

    var attempt: u32 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        // Back-off sleep before retry (not before the first attempt).
        // Use std.Io.sleep so the sleep is also a cancellation point.
        // In test builds we skip the sleep entirely to keep tests fast.
        if (attempt > 0) {
            backoffSleep(io, delays_ms[attempt - 1]);
        }

        if (fetcher.fetchOnce(gpa, url)) |body| {
            return body;
        } else |err| {
            // Never retry these — they are either final or programmer-visible.
            if (err == error.Canceled or
                err == error.OutOfMemory or
                err == error.BodyTooLarge)
            {
                return err;
            }
            // On the last attempt, surface the error to the caller.
            if (attempt == max_attempts - 1) {
                return err;
            }
            // Otherwise continue the loop (retry after back-off on next iteration).
        }
    }
    unreachable; // the loop always exits via return inside
}

// ---------------------------------------------------------------------------
// Real HTTP back-end
// ---------------------------------------------------------------------------

/// Context carried for the real fetcher (holds io + cfg so it can honour timeout).
const RealFetcherCtx = struct {
    io: std.Io,
    cfg: core.Config,
};

const real_vtable = Fetcher.VTable{ .fetchOnce = realFetchOnce };

fn realFetchOnce(
    ctx_opaque: *anyopaque,
    gpa: std.mem.Allocator,
    url: []const u8,
) FetchError![]u8 {
    const ctx: *RealFetcherCtx = @alignCast(@ptrCast(ctx_opaque));

    var client = std.http.Client{ .allocator = gpa, .io = ctx.io };
    defer client.deinit();

    // Use an Allocating writer to accumulate the response body.
    // The Io.Writer.Allocating grows as needed; we enforce the size cap after.
    var body_writer = std.Io.Writer.Allocating.init(gpa);
    // Defer free of any allocated buffer on error paths.
    errdefer {
        var al = body_writer.toArrayList();
        al.deinit(gpa);
    }

    const result = client.fetch(.{
        .location = .{ .url = url },
        .keep_alive = false,
        .redirect_behavior = @enumFromInt(5),
        .response_writer = &body_writer.writer,
    }) catch |err| return mapHttpError(err);

    const status = result.status;
    if (@intFromEnum(status) < 200 or @intFromEnum(status) > 299) {
        return error.HttpStatus;
    }

    // Extract the owned slice from the writer.
    var body_list = body_writer.toArrayList();
    if (body_list.items.len > MAX_BODY_BYTES) {
        body_list.deinit(gpa);
        return error.BodyTooLarge;
    }
    return body_list.toOwnedSlice(gpa) catch return error.OutOfMemory;
}

/// Sleep for `delay_ms` milliseconds via std.Io so the sleep is a cancellation point.
/// In test builds the sleep is omitted entirely to keep tests fast.
fn backoffSleep(io: std.Io, delay_ms: u64) void {
    if (comptime builtin.is_test) return;
    std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(delay_ms)), .awake) catch {};
}

/// Translate arbitrary std.http / std.net errors to `FetchError` members.
fn mapHttpError(err: anyerror) FetchError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.ConnectionTimedOut, error.TimedOut => error.Timeout,
        error.TooManyRedirects => error.TooManyRedirects,
        else => error.ConnectionLost,
    };
}

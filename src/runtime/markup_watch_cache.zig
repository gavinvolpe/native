//! Content-only precheck for a fragment's last attempted import closure.
//! The resolver still owns import discovery, diagnostics and adoption.
const std = @import("std");

pub const max_file_bytes = 256 * 1024;

pub const Cache = struct {
    const Fingerprint = struct { len: usize, hash: u64 };
    const Entry = struct { path: []const u8, fingerprint: ?Fingerprint };

    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    buffer: []u8 = &.{},
    complete: bool = false,

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Cache) void {
        self.clear();
        self.entries.deinit(self.allocator);
        self.allocator.free(self.buffer);
    }

    fn clear(self: *Cache) void {
        for (self.entries.items) |entry| self.allocator.free(entry.path);
        self.entries.clearRetainingCapacity();
    }

    /// Start a fresh observation independently of the last-good document.
    pub fn begin(self: *Cache) void {
        self.clear();
        self.complete = true;
    }

    pub fn invalidate(self: *Cache) void {
        self.complete = false;
    }

    /// Include failed loads: creation of a missing import must retry resolve.
    /// Paths are owned in full and never borrowed from rotating document arenas.
    pub fn observe(self: *Cache, path: []const u8, source: ?[]const u8, max_files: usize) void {
        if (!self.complete) return;
        if (self.entries.items.len >= max_files) {
            self.invalidate();
            return;
        }
        const owned = self.allocator.dupe(u8, path) catch {
            self.invalidate();
            return;
        };
        self.entries.append(self.allocator, .{ .path = owned, .fingerprint = fingerprint(source) }) catch {
            self.allocator.free(owned);
            self.invalidate();
        };
    }

    /// Read content rather than metadata: same-size edits, restored timestamps
    /// and atomic replacements all have the same semantics as the resolver.
    pub fn changed(self: *Cache, io: std.Io) bool {
        if (!self.complete or self.entries.items.len == 0) return true;
        if (self.buffer.len == 0) {
            self.buffer = self.allocator.alloc(u8, 16 * 1024) catch return true;
        }
        for (self.entries.items) |entry| {
            const current = self.readFingerprint(io, entry.path);
            if (!std.meta.eql(current, entry.fingerprint)) return true;
        }
        return false;
    }

    fn readFingerprint(self: *Cache, io: std.Io, path: []const u8) ?Fingerprint {
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
        defer file.close(io);
        var hasher = std.hash.Wyhash.init(0);
        var total: usize = 0;
        while (total < max_file_bytes) {
            const available = @min(self.buffer.len, max_file_bytes - total);
            const len = file.readPositionalAll(io, self.buffer[0..available], total) catch return null;
            hasher.update(self.buffer[0..len]);
            total += len;
            if (len < available) break;
        }
        return .{ .len = total, .hash = hasher.final() };
    }

    fn fingerprint(source: ?[]const u8) ?Fingerprint {
        const bytes = source orelse return null;
        return .{ .len = bytes.len, .hash = std.hash.Wyhash.hash(0, bytes) };
    }
};

test "watch observations own full paths and fail open on incomplete discovery" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    var path: [400]u8 = @splat('p');
    cache.begin();
    cache.observe(&path, "bytes", 33);
    path[0] = 'q';
    try std.testing.expectEqual(@as(usize, 400), cache.entries.items[0].path.len);
    try std.testing.expectEqual(@as(u8, 'p'), cache.entries.items[0].path[0]);
    cache.observe("another", null, 1);
    try std.testing.expect(cache.changed(std.testing.io));
    cache.begin();
    cache.observe("missing", null, 33);
    cache.invalidate();
    try std.testing.expect(cache.changed(std.testing.io));
}

test "watch cache content checks stream through reusable storage and retry allocation failure" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const name = "content.native";
    const bytes = try std.testing.allocator.alloc(u8, 40 * 1024);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'a');
    try temporary.dir.writeFile(io, .{ .sub_path = name, .data = bytes });
    const path = try temporary.dir.realPathFileAlloc(io, name, std.testing.allocator);
    defer std.testing.allocator.free(path);
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    cache.begin();
    cache.observe(path, bytes, 33);
    try std.testing.expect(!cache.changed(io));
    const buffer = cache.buffer.ptr;
    try std.testing.expect(!cache.changed(io));
    try std.testing.expectEqual(buffer, cache.buffer.ptr);
    bytes[35 * 1024] = 'b';
    try temporary.dir.writeFile(io, .{ .sub_path = name, .data = bytes });
    try std.testing.expect(cache.changed(io));

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var unavailable = Cache.init(failing.allocator());
    defer unavailable.deinit();
    unavailable.begin();
    unavailable.observe(path, bytes, 33);
    try std.testing.expect(unavailable.changed(io));
}

const std = @import("std");
const builtin = @import("builtin");
const plan_key_index = @import("plan_key_index.zig");
const compiled_cache = @import("render_cache_policy.zig");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");
const equality_model = @import("equality.zig");
const fingerprints = @import("render_fingerprints.zig");

const Error = canvas.Error;
const ObjectId = canvas.ObjectId;
const Affine = drawing_model.Affine;
const optionalRectsEqual = equality_model.optionalRectsEqual;

const affinesEqual = fingerprints.affinesEqual;
const renderLayerFingerprint = fingerprints.renderLayerFingerprint;
const renderLayerFingerprintAppend = fingerprints.renderLayerFingerprintAppend;

pub const RenderLayer = struct {
    command_start: usize = 0,
    command_count: usize = 0,
    id: ?ObjectId = null,
    bounds: geometry.RectF = .{},
    opacity: f32 = 1,
    clip: ?geometry.RectF = null,
    transform: Affine = .{},
    fingerprint: u64 = 0,
};

pub const RenderLayerPlan = struct {
    layers: []const RenderLayer = &.{},

    pub fn layerCount(self: RenderLayerPlan) usize {
        return self.layers.len;
    }

    pub fn opacityLayerCount(self: RenderLayerPlan) usize {
        var count: usize = 0;
        for (self.layers) |layer| {
            if (layer.opacity != 1) count += 1;
        }
        return count;
    }

    pub fn clipLayerCount(self: RenderLayerPlan) usize {
        var count: usize = 0;
        for (self.layers) |layer| {
            if (layer.clip != null) count += 1;
        }
        return count;
    }

    pub fn transformLayerCount(self: RenderLayerPlan) usize {
        var count: usize = 0;
        for (self.layers) |layer| {
            if (!affinesEqual(layer.transform, Affine.identity())) count += 1;
        }
        return count;
    }

    pub fn cachePlan(self: RenderLayerPlan, previous: []const RenderLayerCacheEntry, frame_index: u64, entries: []RenderLayerCacheEntry, actions: []RenderLayerCacheAction) Error!RenderLayerCachePlan {
        var planner = RenderLayerCachePlanner.init(entries, actions);
        return planner.build(self, previous, frame_index);
    }
    pub fn cachePlanWithWorkspace(self: RenderLayerPlan, workspace: ?*compiled_cache.Workspace, previous: []const RenderLayerCacheEntry, frame_index: u64, entries: []RenderLayerCacheEntry, actions: []RenderLayerCacheAction) Error!RenderLayerCachePlan {
        var planner = RenderLayerCachePlanner.init(entries, actions);
        if (workspace) |owner| return planner.buildCompiled(self, previous, frame_index, owner);
        return planner.build(self, previous, frame_index);
    }
};

pub const RenderLayerPlanner = struct {
    layers: []RenderLayer,
    len: usize = 0,

    pub fn init(layers: []RenderLayer) RenderLayerPlanner {
        return .{ .layers = layers };
    }

    pub fn reset(self: *RenderLayerPlanner) void {
        self.len = 0;
    }

    pub fn buildCompiled(self: *RenderLayerPlanner, plan: anytype, policy: @import("render_resource_policy.zig").Policy) Error!RenderLayerPlan {
        return @import("render_resource_policy.zig").layers(self, plan, policy);
    }

    pub fn build(self: *RenderLayerPlanner, render_plan: anytype) Error!RenderLayerPlan {
        self.reset();
        for (render_plan.commands, 0..) |command, index| {
            try self.consume(command, index);
        }
        return .{ .layers = self.layers[0..self.len] };
    }

    fn consume(self: *RenderLayerPlanner, command: anytype, index: usize) Error!void {
        if (!renderCommandNeedsLayer(command)) return;

        if (self.len > 0 and renderLayerCanExtend(self.layers[self.len - 1], command, index)) {
            const layer = &self.layers[self.len - 1];
            layer.command_count += 1;
            layer.id = if (layer.id == command.id) layer.id else null;
            layer.bounds = geometry.RectF.unionWith(layer.bounds.normalized(), command.bounds.normalized());
            layer.fingerprint = renderLayerFingerprintAppend(layer.fingerprint, command);
            return;
        }

        if (self.len >= self.layers.len) return error.LayerListFull;
        self.layers[self.len] = .{
            .command_start = index,
            .command_count = 1,
            .id = command.id,
            .bounds = command.bounds,
            .opacity = command.opacity,
            .clip = command.clip,
            .transform = command.transform,
            .fingerprint = renderLayerFingerprint(command),
        };
        self.len += 1;
    }
};

pub const RenderLayerKey = struct {
    id: ?ObjectId = null,
    command_start: usize = 0,
    fingerprint: u64 = 0,
};

pub const RenderLayerCacheEntry = struct {
    key: RenderLayerKey,
    last_used_frame: u64 = 0,
};

pub const RenderLayerCacheActionKind = enum {
    upload,
    retain,
    evict,
};

pub const RenderLayerCacheAction = struct {
    kind: RenderLayerCacheActionKind,
    key: RenderLayerKey,
    layer_index: ?usize = null,
    cache_index: ?usize = null,
};

pub const RenderLayerCachePlan = struct {
    entries: []const RenderLayerCacheEntry = &.{},
    actions: []const RenderLayerCacheAction = &.{},

    pub fn entryCount(self: RenderLayerCachePlan) usize {
        return self.entries.len;
    }

    pub fn actionCount(self: RenderLayerCachePlan) usize {
        return self.actions.len;
    }

    pub fn uploadCount(self: RenderLayerCachePlan) usize {
        return self.actionCountByKind(.upload);
    }

    pub fn retainCount(self: RenderLayerCachePlan) usize {
        return self.actionCountByKind(.retain);
    }

    pub fn evictCount(self: RenderLayerCachePlan) usize {
        return self.actionCountByKind(.evict);
    }

    fn actionCountByKind(self: RenderLayerCachePlan, kind: RenderLayerCacheActionKind) usize {
        var count: usize = 0;
        for (self.actions) |action| {
            if (action.kind == kind) count += 1;
        }
        return count;
    }
};

pub const RenderLayerCachePlanner = struct {
    entries: []RenderLayerCacheEntry,
    actions: []RenderLayerCacheAction,
    entry_len: usize = 0,
    action_len: usize = 0,

    pub fn init(entries: []RenderLayerCacheEntry, actions: []RenderLayerCacheAction) RenderLayerCachePlanner {
        return .{ .entries = entries, .actions = actions };
    }

    pub fn reset(self: *RenderLayerCachePlanner) void {
        self.entry_len = 0;
        self.action_len = 0;
    }

    pub fn buildCompiled(self: *RenderLayerCachePlanner, plan: RenderLayerPlan, previous: []const RenderLayerCacheEntry, frame_index: u64, workspace: *compiled_cache.Workspace) Error!RenderLayerCachePlan {
        return compiled_cache.build(.layer, RenderLayerCachePlan, self, plan.layers, previous, frame_index, workspace, renderLayerKey, null, error.LayerCacheListFull);
    }

    pub fn build(self: *RenderLayerCachePlanner, layer_plan: RenderLayerPlan, previous: []const RenderLayerCacheEntry, frame_index: u64) Error!RenderLayerCachePlan {
        self.reset();
        // Keyed lookups ride the probe-table index whenever the inputs
        // fit its half-full bound (the runtime budgets always do);
        // oversized library inputs keep the linear scans. Same outputs
        // either way — the index resolves to the lowest-index equal
        // entry exactly like the scans it replaces.
        const use_index = (layer_plan.layers.len >= plan_key_index.min_entries_for_index or
            previous.len >= plan_key_index.min_entries_for_index) and
            plan_key_index.fitsHashSlots(layer_cache_index_slots, previous.len) and
            plan_key_index.fitsHashSlots(layer_cache_index_slots, layer_plan.layers.len) and
            !cacheEntrySlicesOverlap(self.entries, previous);
        const index_scratch: ?*LayerCacheIndexScratch = if (use_index) layer_cache_index_scratch.get() else null;
        if (index_scratch) |scratch| {
            scratch.previous.reset();
            for (previous, 0..) |entry, index| {
                var p = LayerCacheIndex.probe(renderLayerKeyHash(entry.key));
                while (scratch.previous.next(&p)) |_| {}
                scratch.previous.insert(p, @intCast(index));
            }
            scratch.entry.reset();
        }

        for (layer_plan.layers, 0..) |layer, layer_index| {
            const key = renderLayerKey(layer);
            const key_hash = if (use_index) renderLayerKeyHash(key) else 0;
            if (index_scratch) |scratch| {
                var p = LayerCacheIndex.probe(key_hash);
                var duplicate = false;
                while (scratch.entry.next(&p)) |candidate| {
                    if (renderLayerKeysEqual(self.entries[candidate].key, key)) {
                        duplicate = true;
                        break;
                    }
                }
                if (duplicate) continue;
                const previous_index = findRenderLayerCacheEntryIndexed(&scratch.previous, previous, key, key_hash);
                try self.appendAction(.{
                    .kind = if (previous_index == null) .upload else .retain,
                    .key = key,
                    .layer_index = layer_index,
                    .cache_index = previous_index,
                });
                try self.appendEntry(.{
                    .key = key,
                    .last_used_frame = frame_index,
                });
                scratch.entry.insert(p, @intCast(self.entry_len - 1));
                continue;
            }
            if (findRenderLayerCacheEntry(self.entries[0..self.entry_len], key) != null) continue;

            const previous_index = findRenderLayerCacheEntry(previous, key);
            try self.appendAction(.{
                .kind = if (previous_index == null) .upload else .retain,
                .key = key,
                .layer_index = layer_index,
                .cache_index = previous_index,
            });
            try self.appendEntry(.{
                .key = key,
                .last_used_frame = frame_index,
            });
        }

        for (previous, 0..) |entry, cache_index| {
            if (index_scratch) |scratch| {
                var p = LayerCacheIndex.probe(renderLayerKeyHash(entry.key));
                var kept = false;
                while (scratch.entry.next(&p)) |candidate| {
                    if (renderLayerKeysEqual(self.entries[candidate].key, entry.key)) {
                        kept = true;
                        break;
                    }
                }
                if (kept) continue;
            } else if (findRenderLayerCacheEntry(self.entries[0..self.entry_len], entry.key) != null) {
                continue;
            }
            try self.appendAction(.{
                .kind = .evict,
                .key = entry.key,
                .cache_index = cache_index,
            });
        }

        return .{
            .entries = self.entries[0..self.entry_len],
            .actions = self.actions[0..self.action_len],
        };
    }

    fn appendEntry(self: *RenderLayerCachePlanner, entry: RenderLayerCacheEntry) Error!void {
        if (self.entry_len >= self.entries.len) return error.LayerCacheListFull;
        self.entries[self.entry_len] = entry;
        self.entry_len += 1;
    }

    fn appendAction(self: *RenderLayerCachePlanner, action: RenderLayerCacheAction) Error!void {
        if (self.action_len >= self.actions.len) return error.LayerCacheListFull;
        self.actions[self.action_len] = action;
        self.action_len += 1;
    }
};

fn renderCommandNeedsLayer(command: anytype) bool {
    return command.opacity != 1 or command.clip != null or !affinesEqual(command.transform, Affine.identity());
}

fn renderLayerCanExtend(layer: RenderLayer, command: anytype, index: usize) bool {
    return layer.command_start + layer.command_count == index and
        layer.opacity == command.opacity and
        optionalRectsEqual(layer.clip, command.clip) and
        affinesEqual(layer.transform, command.transform);
}

fn renderLayerKey(layer: RenderLayer) RenderLayerKey {
    return .{
        .id = layer.id,
        .command_start = if (layer.id == null) layer.command_start else 0,
        .fingerprint = layer.fingerprint,
    };
}

fn findRenderLayerCacheEntry(entries: []const RenderLayerCacheEntry, key: RenderLayerKey) ?usize {
    for (entries, 0..) |entry, index| {
        if (renderLayerKeysEqual(entry.key, key)) return index;
    }
    return null;
}

// Match the resource planner's half-full 2048-entry runtime budget.
// Small and oversized library inputs retain the original scans.
const layer_cache_index_slots = 4096;
const LayerCacheIndex = plan_key_index.HashSlots(layer_cache_index_slots);
const LayerCacheIndexScratch = struct {
    previous: LayerCacheIndex = .{},
    entry: LayerCacheIndex = .{},
};
const layer_cache_index_scratch = @import("lazy_tls.zig").LazyTls(LayerCacheIndexScratch);

fn findRenderLayerCacheEntryIndexed(previous_index: *const LayerCacheIndex, previous: []const RenderLayerCacheEntry, key: RenderLayerKey, key_hash: u64) ?usize {
    var p = LayerCacheIndex.probe(key_hash);
    while (previous_index.next(&p)) |candidate| {
        if (renderLayerKeysEqual(previous[candidate].key, key)) return candidate;
    }
    return null;
}

fn renderLayerKeyHash(key: RenderLayerKey) u64 {
    var hash = plan_key_index.mixHash(key.fingerprint);
    hash = plan_key_index.mixHash(hash ^ @as(u64, key.id orelse 0) ^ @as(u64, @intCast(key.command_start)));
    return plan_key_index.mixHash(hash ^ @as(u64, @intFromBool(key.id != null)));
}

// Preserve the scan path for callers reusing their previous-entry buffer.
fn cacheEntrySlicesOverlap(a: []const RenderLayerCacheEntry, b: []const RenderLayerCacheEntry) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    return if (a_start <= b_start)
        b_start - a_start < a.len * @sizeOf(RenderLayerCacheEntry)
    else
        a_start - b_start < b.len * @sizeOf(RenderLayerCacheEntry);
}

// Deterministic regression evidence; no counter or increment in application builds.
threadlocal var cache_key_comparisons: if (builtin.is_test) usize else void = if (builtin.is_test) 0 else {};

fn renderLayerKeysEqual(a: RenderLayerKey, b: RenderLayerKey) bool {
    if (comptime builtin.is_test) cache_key_comparisons += 1;
    return a.id == b.id and
        a.command_start == b.command_start and
        a.fingerprint == b.fingerprint;
}

fn cacheTestItem(index: usize) RenderLayer {
    return .{ .command_start = index, .id = @intCast(index + 1), .fingerprint = @intCast(index * 11) };
}

test "indexed layer cache preserves collisions first matches order and partial failure" {
    var previous: [64]RenderLayerCacheEntry = undefined;
    for (&previous, 0..) |*entry, i| entry.* = .{ .key = renderLayerKey(cacheTestItem(i)), .last_used_frame = 1 };
    // Unequal keys deliberately share a probe bucket with the current mixer.
    previous[1].key.fingerprint = 6069;
    try std.testing.expectEqual(LayerCacheIndex.probe(renderLayerKeyHash(previous[0].key)).pos, LayerCacheIndex.probe(renderLayerKeyHash(previous[1].key)).pos);
    previous[2].key.id = null;
    previous[2].key.command_start = 9;
    previous[2].key.fingerprint = 333;
    previous[3].key.id = 0;
    previous[3].key.fingerprint = 333;
    previous[4].key = previous[0].key;
    previous[9].key.id = null;
    previous[9].key.command_start = 10;
    previous[9].key.fingerprint = 333;
    var current: [64]RenderLayer = undefined;
    for (&current, 0..) |*item, i| {
        const k = previous[i].key;
        item.* = .{ .id = k.id, .command_start = k.command_start, .fingerprint = k.fingerprint };
    }
    current[0] = cacheTestItem(63);
    current[1] = cacheTestItem(0);
    current[2] = .{ .id = 2, .fingerprint = 6069 };
    current[3] = .{ .id = null, .command_start = 9, .fingerprint = 333 };
    current[4] = .{ .id = 0, .fingerprint = 333 };
    current[5] = current[1];
    current[6] = .{ .id = 7, .fingerprint = 999 };
    var entries: [64]RenderLayerCacheEntry = undefined;
    var actions: [128]RenderLayerCacheAction = undefined;
    var planner = RenderLayerCachePlanner.init(&entries, &actions);
    const result = try planner.build(.{ .layers = &current }, &previous, 2);
    try std.testing.expectEqual(@as(usize, 62), result.entries.len);
    try std.testing.expectEqual(@as(usize, 64), result.actions.len);
    for ([_]usize{ 63, 0, 1, 2, 3 }, 0..) |old, i| {
        try std.testing.expectEqual(RenderLayerCacheActionKind.retain, result.actions[i].kind);
        try std.testing.expectEqual(@as(?usize, old), result.actions[i].cache_index);
        try std.testing.expectEqual(@as(?usize, i), result.actions[i].layer_index);
        try std.testing.expectEqualDeep(previous[old].key, result.entries[i].key);
    }
    try std.testing.expectEqual(RenderLayerCacheActionKind.upload, result.actions[5].kind);
    try std.testing.expectEqual(@as(?usize, 6), result.actions[5].layer_index);
    try std.testing.expectEqual(@as(?usize, null), result.actions[5].cache_index);
    for (7..63) |old| {
        const a = result.actions[old - 1];
        try std.testing.expectEqual(RenderLayerCacheActionKind.retain, a.kind);
        try std.testing.expectEqual(@as(?usize, old), a.cache_index);
        try std.testing.expectEqual(@as(?usize, old), a.layer_index);
    }
    for ([_]usize{ 5, 6 }, 62..) |old, i| {
        try std.testing.expectEqual(RenderLayerCacheActionKind.evict, result.actions[i].kind);
        try std.testing.expectEqual(@as(?usize, old), result.actions[i].cache_index);
        try std.testing.expectEqual(@as(?usize, null), result.actions[i].layer_index);
    }
    for (result.entries) |entry| try std.testing.expectEqual(@as(u64, 2), entry.last_used_frame);

    // Keep the original action-before-entry commit and eviction ordering.
    planner = RenderLayerCachePlanner.init(entries[0..0], actions[0..1]);
    try std.testing.expectError(error.LayerCacheListFull, planner.build(.{ .layers = &current }, &previous, 3));
    try std.testing.expectEqual(@as(usize, 1), planner.action_len);
    try std.testing.expectEqual(@as(usize, 0), planner.entry_len);
    try std.testing.expectEqual(@as(?usize, 63), planner.actions[0].cache_index);
    planner = RenderLayerCachePlanner.init(&entries, actions[0..0]);
    try std.testing.expectError(error.LayerCacheListFull, planner.build(.{ .layers = &current }, &previous, 3));
    try std.testing.expectEqual(@as(usize, 0), planner.entry_len);
    try std.testing.expectEqual(@as(usize, 0), planner.action_len);
    planner = RenderLayerCachePlanner.init(&entries, actions[0..63]);
    try std.testing.expectError(error.LayerCacheListFull, planner.build(.{ .layers = &current }, &previous, 3));
    try std.testing.expectEqual(@as(usize, 62), planner.entry_len);
    try std.testing.expectEqual(@as(usize, 63), planner.action_len);
    try std.testing.expectEqual(@as(?usize, 5), planner.actions[62].cache_index);
    // A successful build after those failures must reset scratch and output.
    planner = RenderLayerCachePlanner.init(&entries, &actions);
    const retry = try planner.build(.{ .layers = &current }, &previous, 4);
    try std.testing.expectEqual(@as(usize, 64), retry.actions.len);
}

test "indexed layer cache bounds dense retained lookup work and keeps oversized fallback" {
    const count = 1024;
    var current: [count]RenderLayer = undefined;
    var previous: [count]RenderLayerCacheEntry = undefined;
    var entries: [count]RenderLayerCacheEntry = undefined;
    var actions: [count]RenderLayerCacheAction = undefined;
    for (&current, &previous, 0..) |*item, *entry, i| {
        item.* = cacheTestItem(i);
        entry.* = .{ .key = renderLayerKey(item.*), .last_used_frame = 1 };
    }
    cache_key_comparisons = 0;
    const result = try (RenderLayerPlan{ .layers = &current }).cachePlan(&previous, 2, &entries, &actions);
    const comparisons = cache_key_comparisons;
    try std.testing.expectEqual(@as(usize, count), result.retainCount());
    try std.testing.expect(comparisons > 0);
    try std.testing.expect(comparisons < 16 * count);
    for (result.actions, 0..) |action, i| {
        try std.testing.expectEqual(@as(?usize, i), action.cache_index);
        try std.testing.expectEqual(@as(?usize, i), action.layer_index);
    }

    // Library callers can exceed the runtime index budget: no truncation.
    const oversized_count = LayerCacheIndex.max_entries + 1;
    var oversized: [oversized_count]RenderLayer = undefined;
    for (&oversized) |*item| item.* = cacheTestItem(0);
    oversized[oversized_count - 1] = cacheTestItem(1);
    const fallback = try (RenderLayerPlan{ .layers = &oversized }).cachePlan(&.{}, 3, entries[0..2], actions[0..2]);
    try std.testing.expectEqual(@as(usize, 2), fallback.entries.len);
    try std.testing.expectEqual(@as(usize, 2), fallback.actions.len);
    try std.testing.expectEqual(@as(usize, 2), fallback.uploadCount());
    try std.testing.expectEqual(@as(?usize, 0), fallback.actions[0].layer_index);
    try std.testing.expectEqual(@as(?usize, 2048), fallback.actions[1].layer_index);
    try std.testing.expectEqualDeep(renderLayerKey(cacheTestItem(1)), fallback.entries[1].key);
}

test "layer cache preserves in-place previous entry behavior" {
    var previous: [64]RenderLayerCacheEntry = undefined;
    var current: [64]RenderLayer = undefined;
    var actions: [128]RenderLayerCacheAction = undefined;
    for (&previous, &current, 0..) |*entry, *item, i| {
        entry.* = .{ .key = renderLayerKey(cacheTestItem(i)), .last_used_frame = 1 };
        item.* = cacheTestItem(63 - i);
    }
    try std.testing.expect(cacheEntrySlicesOverlap(&previous, previous[16..]));
    try std.testing.expect(!cacheEntrySlicesOverlap(previous[0..16], previous[16..]));
    const result = try (RenderLayerPlan{ .layers = &current }).cachePlan(&previous, 2, &previous, &actions);
    try std.testing.expectEqual(@as(usize, 64), result.entries.len);
    try std.testing.expectEqual(@as(usize, 64), result.actions.len);
    for (result.actions, 0..) |action, i| {
        try std.testing.expectEqual(@as(RenderLayerCacheActionKind, if (i < 32) .retain else .upload), action.kind);
        try std.testing.expectEqual(if (i < 32) @as(?usize, 63 - i) else null, action.cache_index);
    }
}

const std = @import("std");
const builtin = @import("builtin");
const plan_key_index = @import("plan_key_index.zig");
const compiled_cache = @import("render_cache_policy.zig");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const drawing_model = @import("drawing.zig");
const hash_model = @import("hash.zig");

const Error = canvas.Error;
const ObjectId = canvas.ObjectId;
const Affine = drawing_model.Affine;
const PathElement = drawing_model.PathElement;

const path_geometry_curve_segments: usize = 12;
const resourceHashTag = hash_model.resourceHashTag;
const resourceHashBytes = hash_model.resourceHashBytes;
const resourceHashF32 = hash_model.resourceHashF32;
const resourceHashAffine = hash_model.resourceHashAffine;
const resourceHashOptionalObjectId = hash_model.resourceHashOptionalObjectId;
const resourceHashPath = hash_model.resourceHashPath;

pub const RenderPathGeometryKind = enum {
    fill,
    stroke,
};

pub const RenderPathGeometry = struct {
    kind: RenderPathGeometryKind,
    command_index: usize = 0,
    id: ?ObjectId = null,
    bounds: geometry.RectF = .{},
    element_count: usize = 0,
    contour_count: usize = 0,
    line_segment_count: usize = 0,
    quadratic_segment_count: usize = 0,
    cubic_segment_count: usize = 0,
    flattened_segment_count: usize = 0,
    vertex_count: usize = 0,
    index_count: usize = 0,
    stroke_width: f32 = 0,
    fingerprint: u64 = 0,
};

pub const RenderPathGeometryPlan = struct {
    geometries: []const RenderPathGeometry = &.{},

    pub fn geometryCount(self: RenderPathGeometryPlan) usize {
        return self.geometries.len;
    }

    pub fn vertexCount(self: RenderPathGeometryPlan) usize {
        var count: usize = 0;
        for (self.geometries) |geometry_plan| count += geometry_plan.vertex_count;
        return count;
    }

    pub fn indexCount(self: RenderPathGeometryPlan) usize {
        var count: usize = 0;
        for (self.geometries) |geometry_plan| count += geometry_plan.index_count;
        return count;
    }

    pub fn cachePlan(self: RenderPathGeometryPlan, previous: []const RenderPathGeometryCacheEntry, frame_index: u64, entries: []RenderPathGeometryCacheEntry, actions: []RenderPathGeometryCacheAction) Error!RenderPathGeometryCachePlan {
        var planner = RenderPathGeometryCachePlanner.init(entries, actions);
        return planner.build(self, previous, frame_index);
    }
    pub fn cachePlanWithWorkspace(self: RenderPathGeometryPlan, workspace: ?*compiled_cache.Workspace, previous: []const RenderPathGeometryCacheEntry, frame_index: u64, entries: []RenderPathGeometryCacheEntry, actions: []RenderPathGeometryCacheAction) Error!RenderPathGeometryCachePlan {
        var planner = RenderPathGeometryCachePlanner.init(entries, actions);
        if (workspace) |owner| return planner.buildCompiled(self, previous, frame_index, owner);
        return planner.build(self, previous, frame_index);
    }
};

pub const RenderPathGeometryPlanner = struct {
    geometries: []RenderPathGeometry,
    len: usize = 0,

    pub fn init(geometries: []RenderPathGeometry) RenderPathGeometryPlanner {
        return .{ .geometries = geometries };
    }

    pub fn reset(self: *RenderPathGeometryPlanner) void {
        self.len = 0;
    }

    pub fn build(self: *RenderPathGeometryPlanner, render_plan: anytype) Error!RenderPathGeometryPlan {
        self.reset();
        for (render_plan.commands, 0..) |command, index| {
            try self.consume(command, index);
        }
        return .{ .geometries = self.geometries[0..self.len] };
    }

    pub fn buildCompiled(self: *RenderPathGeometryPlanner, plan: anytype, policy: compiled_cache.Policy) Error!RenderPathGeometryPlan {
        return @import("vector_effect_policy.zig").paths(self, plan, policy);
    }

    fn consume(self: *RenderPathGeometryPlanner, command: anytype, index: usize) Error!void {
        switch (command.command) {
            .fill_path => |value| try self.consumePath(.fill, command, index, value.elements, 0),
            .stroke_path => |value| {
                const stroke_width = nonNegative(value.stroke.width) * referenceTransformScale(command.transform);
                if (stroke_width <= 0) return;
                try self.consumePath(.stroke, command, index, value.elements, stroke_width);
            },
            else => {},
        }
    }

    fn consumePath(self: *RenderPathGeometryPlanner, kind: RenderPathGeometryKind, command: anytype, index: usize, elements: []const PathElement, stroke_width: f32) Error!void {
        const counts = analyzePathGeometry(elements, kind);
        if (counts.vertex_count == 0 or counts.index_count == 0) return;
        if (self.len >= self.geometries.len) return error.PathGeometryListFull;
        self.geometries[self.len] = .{
            .kind = kind,
            .command_index = index,
            .id = command.id,
            .bounds = command.bounds,
            .element_count = elements.len,
            .contour_count = counts.contour_count,
            .line_segment_count = counts.line_segment_count,
            .quadratic_segment_count = counts.quadratic_segment_count,
            .cubic_segment_count = counts.cubic_segment_count,
            .flattened_segment_count = counts.flattened_segment_count,
            .vertex_count = counts.vertex_count,
            .index_count = counts.index_count,
            .stroke_width = stroke_width,
            .fingerprint = renderPathGeometryFingerprint(command, kind, elements, stroke_width),
        };
        self.len += 1;
    }
};

pub const PathGeometryCounts = struct {
    contour_count: usize = 0,
    line_segment_count: usize = 0,
    quadratic_segment_count: usize = 0,
    cubic_segment_count: usize = 0,
    flattened_segment_count: usize = 0,
    vertex_count: usize = 0,
    index_count: usize = 0,
};

pub fn analyzePathGeometry(elements: []const PathElement, kind: RenderPathGeometryKind) PathGeometryCounts {
    var counts = PathGeometryCounts{};
    var has_current = false;

    for (elements) |element| {
        switch (element.verb) {
            .move_to => {
                counts.contour_count += 1;
                counts.vertex_count += 1;
                has_current = true;
            },
            .line_to => {
                if (!has_current) {
                    counts.contour_count += 1;
                    counts.vertex_count += 1;
                    has_current = true;
                    continue;
                }
                counts.line_segment_count += 1;
                counts.flattened_segment_count += 1;
                counts.vertex_count += 1;
            },
            .quad_to => {
                if (!has_current) continue;
                counts.quadratic_segment_count += 1;
                counts.flattened_segment_count += path_geometry_curve_segments;
                counts.vertex_count += path_geometry_curve_segments;
            },
            .cubic_to => {
                if (!has_current) continue;
                counts.cubic_segment_count += 1;
                counts.flattened_segment_count += path_geometry_curve_segments;
                counts.vertex_count += path_geometry_curve_segments;
            },
            .close => {
                if (!has_current) continue;
                counts.line_segment_count += 1;
                counts.flattened_segment_count += 1;
            },
        }
    }

    switch (kind) {
        .fill => {
            counts.index_count = if (counts.vertex_count >= 3) (counts.vertex_count - 2) * 3 else 0;
        },
        .stroke => {
            counts.vertex_count = counts.flattened_segment_count * 4;
            counts.index_count = counts.flattened_segment_count * 6;
        },
    }
    return counts;
}

fn renderPathGeometryKey(geometry_plan: RenderPathGeometry) RenderPathGeometryKey {
    return .{
        .kind = geometry_plan.kind,
        .id = geometry_plan.id,
        .command_index = if (geometry_plan.id == null) geometry_plan.command_index else 0,
        .fingerprint = geometry_plan.fingerprint,
    };
}

fn findRenderPathGeometryCacheEntry(entries: []const RenderPathGeometryCacheEntry, key: RenderPathGeometryKey) ?usize {
    for (entries, 0..) |entry, index| {
        if (renderPathGeometryKeysEqual(entry.key, key)) return index;
    }
    return null;
}

// Match the resource planner's half-full 2048-entry runtime budget.
// Small and oversized library inputs retain the original scans.
const path_geometry_cache_index_slots = 4096;
const PathGeometryCacheIndex = plan_key_index.HashSlots(path_geometry_cache_index_slots);
const PathGeometryCacheIndexScratch = struct {
    previous: PathGeometryCacheIndex = .{},
    entry: PathGeometryCacheIndex = .{},
};
const path_geometry_cache_index_scratch = @import("lazy_tls.zig").LazyTls(PathGeometryCacheIndexScratch);

fn findRenderPathGeometryCacheEntryIndexed(previous_index: *const PathGeometryCacheIndex, previous: []const RenderPathGeometryCacheEntry, key: RenderPathGeometryKey, key_hash: u64) ?usize {
    var p = PathGeometryCacheIndex.probe(key_hash);
    while (previous_index.next(&p)) |candidate| {
        if (renderPathGeometryKeysEqual(previous[candidate].key, key)) return candidate;
    }
    return null;
}

fn renderPathGeometryKeyHash(key: RenderPathGeometryKey) u64 {
    var hash = plan_key_index.mixHash(key.fingerprint ^ @as(u64, @intFromEnum(key.kind)));
    hash = plan_key_index.mixHash(hash ^ @as(u64, key.id orelse 0) ^ @as(u64, @intCast(key.command_index)));
    return plan_key_index.mixHash(hash ^ @as(u64, @intFromBool(key.id != null)));
}

// Preserve the scan path for callers reusing their previous-entry buffer.
fn cacheEntrySlicesOverlap(a: []const RenderPathGeometryCacheEntry, b: []const RenderPathGeometryCacheEntry) bool {
    if (a.len == 0 or b.len == 0) return false;
    const a_start = @intFromPtr(a.ptr);
    const b_start = @intFromPtr(b.ptr);
    return if (a_start <= b_start)
        b_start - a_start < a.len * @sizeOf(RenderPathGeometryCacheEntry)
    else
        a_start - b_start < b.len * @sizeOf(RenderPathGeometryCacheEntry);
}

// Deterministic regression evidence; no counter or increment in application builds.
threadlocal var cache_key_comparisons: if (builtin.is_test) usize else void = if (builtin.is_test) 0 else {};

fn renderPathGeometryKeysEqual(a: RenderPathGeometryKey, b: RenderPathGeometryKey) bool {
    if (comptime builtin.is_test) cache_key_comparisons += 1;
    return a.kind == b.kind and
        a.id == b.id and
        a.command_index == b.command_index and
        a.fingerprint == b.fingerprint;
}

fn renderPathGeometryFingerprint(command: anytype, kind: RenderPathGeometryKind, elements: []const PathElement, stroke_width: f32) u64 {
    var hash = resourceHashTag("path_geometry");
    hash = resourceHashBytes(hash, @tagName(kind));
    hash = resourceHashOptionalObjectId(hash, command.id);
    hash = resourceHashAffine(hash, command.transform);
    hash = resourceHashPath(hash, elements);
    hash = resourceHashF32(hash, stroke_width);
    return hash;
}

pub const RenderPathGeometryKey = struct {
    kind: RenderPathGeometryKind,
    id: ?ObjectId = null,
    command_index: usize = 0,
    fingerprint: u64 = 0,
};

pub const RenderPathGeometryCacheEntry = struct {
    key: RenderPathGeometryKey,
    last_used_frame: u64 = 0,
};

pub const RenderPathGeometryCacheActionKind = enum {
    upload,
    retain,
    evict,
};

pub const RenderPathGeometryCacheAction = struct {
    kind: RenderPathGeometryCacheActionKind,
    key: RenderPathGeometryKey,
    geometry_index: ?usize = null,
    cache_index: ?usize = null,
};

pub const RenderPathGeometryCachePlan = struct {
    entries: []const RenderPathGeometryCacheEntry = &.{},
    actions: []const RenderPathGeometryCacheAction = &.{},

    pub fn entryCount(self: RenderPathGeometryCachePlan) usize {
        return self.entries.len;
    }

    pub fn actionCount(self: RenderPathGeometryCachePlan) usize {
        return self.actions.len;
    }

    pub fn uploadCount(self: RenderPathGeometryCachePlan) usize {
        return self.actionCountByKind(.upload);
    }

    pub fn retainCount(self: RenderPathGeometryCachePlan) usize {
        return self.actionCountByKind(.retain);
    }

    pub fn evictCount(self: RenderPathGeometryCachePlan) usize {
        return self.actionCountByKind(.evict);
    }

    fn actionCountByKind(self: RenderPathGeometryCachePlan, kind: RenderPathGeometryCacheActionKind) usize {
        var count: usize = 0;
        for (self.actions) |action| {
            if (action.kind == kind) count += 1;
        }
        return count;
    }
};

pub const RenderPathGeometryCachePlanner = struct {
    entries: []RenderPathGeometryCacheEntry,
    actions: []RenderPathGeometryCacheAction,
    entry_len: usize = 0,
    action_len: usize = 0,

    pub fn init(entries: []RenderPathGeometryCacheEntry, actions: []RenderPathGeometryCacheAction) RenderPathGeometryCachePlanner {
        return .{ .entries = entries, .actions = actions };
    }

    pub fn reset(self: *RenderPathGeometryCachePlanner) void {
        self.entry_len = 0;
        self.action_len = 0;
    }

    pub fn buildCompiled(self: *RenderPathGeometryCachePlanner, plan: RenderPathGeometryPlan, previous: []const RenderPathGeometryCacheEntry, frame_index: u64, workspace: *compiled_cache.Workspace) Error!RenderPathGeometryCachePlan {
        return compiled_cache.build(.path, RenderPathGeometryCachePlan, self, plan.geometries, previous, frame_index, workspace, renderPathGeometryKey, null, error.PathGeometryCacheListFull);
    }

    pub fn build(self: *RenderPathGeometryCachePlanner, geometry_plan: RenderPathGeometryPlan, previous: []const RenderPathGeometryCacheEntry, frame_index: u64) Error!RenderPathGeometryCachePlan {
        self.reset();
        // Keyed lookups ride the probe-table index whenever the inputs
        // fit its half-full bound (the runtime budgets always do);
        // oversized library inputs keep the linear scans. Same outputs
        // either way — the index resolves to the lowest-index equal
        // entry exactly like the scans it replaces.
        const use_index = (geometry_plan.geometries.len >= plan_key_index.min_entries_for_index or
            previous.len >= plan_key_index.min_entries_for_index) and
            plan_key_index.fitsHashSlots(path_geometry_cache_index_slots, previous.len) and
            plan_key_index.fitsHashSlots(path_geometry_cache_index_slots, geometry_plan.geometries.len) and
            !cacheEntrySlicesOverlap(self.entries, previous);
        const index_scratch: ?*PathGeometryCacheIndexScratch = if (use_index) path_geometry_cache_index_scratch.get() else null;
        if (index_scratch) |scratch| {
            scratch.previous.reset();
            for (previous, 0..) |entry, index| {
                var p = PathGeometryCacheIndex.probe(renderPathGeometryKeyHash(entry.key));
                while (scratch.previous.next(&p)) |_| {}
                scratch.previous.insert(p, @intCast(index));
            }
            scratch.entry.reset();
        }

        for (geometry_plan.geometries, 0..) |geometry_plan_item, geometry_index| {
            const key = renderPathGeometryKey(geometry_plan_item);
            const key_hash = if (use_index) renderPathGeometryKeyHash(key) else 0;
            if (index_scratch) |scratch| {
                var p = PathGeometryCacheIndex.probe(key_hash);
                var duplicate = false;
                while (scratch.entry.next(&p)) |candidate| {
                    if (renderPathGeometryKeysEqual(self.entries[candidate].key, key)) {
                        duplicate = true;
                        break;
                    }
                }
                if (duplicate) continue;
                const previous_index = findRenderPathGeometryCacheEntryIndexed(&scratch.previous, previous, key, key_hash);
                try self.appendAction(.{
                    .kind = if (previous_index == null) .upload else .retain,
                    .key = key,
                    .geometry_index = geometry_index,
                    .cache_index = previous_index,
                });
                try self.appendEntry(.{
                    .key = key,
                    .last_used_frame = frame_index,
                });
                scratch.entry.insert(p, @intCast(self.entry_len - 1));
                continue;
            }
            if (findRenderPathGeometryCacheEntry(self.entries[0..self.entry_len], key) != null) continue;

            const previous_index = findRenderPathGeometryCacheEntry(previous, key);
            try self.appendAction(.{
                .kind = if (previous_index == null) .upload else .retain,
                .key = key,
                .geometry_index = geometry_index,
                .cache_index = previous_index,
            });
            try self.appendEntry(.{
                .key = key,
                .last_used_frame = frame_index,
            });
        }

        for (previous, 0..) |entry, cache_index| {
            if (index_scratch) |scratch| {
                var p = PathGeometryCacheIndex.probe(renderPathGeometryKeyHash(entry.key));
                var kept = false;
                while (scratch.entry.next(&p)) |candidate| {
                    if (renderPathGeometryKeysEqual(self.entries[candidate].key, entry.key)) {
                        kept = true;
                        break;
                    }
                }
                if (kept) continue;
            } else if (findRenderPathGeometryCacheEntry(self.entries[0..self.entry_len], entry.key) != null) {
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

    fn appendEntry(self: *RenderPathGeometryCachePlanner, entry: RenderPathGeometryCacheEntry) Error!void {
        if (self.entry_len >= self.entries.len) return error.PathGeometryCacheListFull;
        self.entries[self.entry_len] = entry;
        self.entry_len += 1;
    }

    fn appendAction(self: *RenderPathGeometryCachePlanner, action: RenderPathGeometryCacheAction) Error!void {
        if (self.action_len >= self.actions.len) return error.PathGeometryCacheListFull;
        self.actions[self.action_len] = action;
        self.action_len += 1;
    }
};

fn referenceTransformScale(transform: Affine) f32 {
    const x_scale = @sqrt(transform.a * transform.a + transform.b * transform.b);
    const y_scale = @sqrt(transform.c * transform.c + transform.d * transform.d);
    return @max(0.0001, @max(x_scale, y_scale));
}

fn nonNegative(value: f32) f32 {
    return @max(0, value);
}

fn cacheTestItem(index: usize) RenderPathGeometry {
    return .{ .kind = .fill, .command_index = index, .id = @intCast(index + 1), .fingerprint = @intCast(index * 11) };
}

test "indexed path geometry cache preserves collisions first matches order and partial failure" {
    var previous: [64]RenderPathGeometryCacheEntry = undefined;
    for (&previous, 0..) |*entry, i| entry.* = .{ .key = renderPathGeometryKey(cacheTestItem(i)), .last_used_frame = 1 };
    // Unequal keys deliberately share a probe bucket with the current mixer.
    previous[1].key.fingerprint = 6069;
    try std.testing.expectEqual(PathGeometryCacheIndex.probe(renderPathGeometryKeyHash(previous[0].key)).pos, PathGeometryCacheIndex.probe(renderPathGeometryKeyHash(previous[1].key)).pos);
    previous[2].key.id = null;
    previous[2].key.command_index = 9;
    previous[2].key.fingerprint = 333;
    previous[3].key.id = 0;
    previous[3].key.fingerprint = 333;
    previous[4].key = previous[0].key;
    previous[9].key.id = null;
    previous[9].key.command_index = 10;
    previous[9].key.fingerprint = 333;
    previous[7].key.kind = .stroke;
    previous[8].key = previous[7].key;
    previous[8].key.kind = .fill;
    var current: [64]RenderPathGeometry = undefined;
    for (&current, 0..) |*item, i| {
        const k = previous[i].key;
        item.* = .{ .kind = k.kind, .id = k.id, .command_index = k.command_index, .fingerprint = k.fingerprint };
    }
    current[0] = cacheTestItem(63);
    current[1] = cacheTestItem(0);
    current[2] = .{ .kind = .fill, .id = 2, .fingerprint = 6069 };
    current[3] = .{ .kind = .fill, .id = null, .command_index = 9, .fingerprint = 333 };
    current[4] = .{ .kind = .fill, .id = 0, .fingerprint = 333 };
    current[5] = current[1];
    current[6] = .{ .kind = .fill, .id = 7, .fingerprint = 999 };
    var entries: [64]RenderPathGeometryCacheEntry = undefined;
    var actions: [128]RenderPathGeometryCacheAction = undefined;
    var planner = RenderPathGeometryCachePlanner.init(&entries, &actions);
    const result = try planner.build(.{ .geometries = &current }, &previous, 2);
    try std.testing.expectEqual(@as(usize, 62), result.entries.len);
    try std.testing.expectEqual(@as(usize, 64), result.actions.len);
    for ([_]usize{ 63, 0, 1, 2, 3 }, 0..) |old, i| {
        try std.testing.expectEqual(RenderPathGeometryCacheActionKind.retain, result.actions[i].kind);
        try std.testing.expectEqual(@as(?usize, old), result.actions[i].cache_index);
        try std.testing.expectEqual(@as(?usize, i), result.actions[i].geometry_index);
        try std.testing.expectEqualDeep(previous[old].key, result.entries[i].key);
    }
    try std.testing.expectEqual(RenderPathGeometryCacheActionKind.upload, result.actions[5].kind);
    try std.testing.expectEqual(@as(?usize, 6), result.actions[5].geometry_index);
    try std.testing.expectEqual(@as(?usize, null), result.actions[5].cache_index);
    for (7..63) |old| {
        const a = result.actions[old - 1];
        try std.testing.expectEqual(RenderPathGeometryCacheActionKind.retain, a.kind);
        try std.testing.expectEqual(@as(?usize, old), a.cache_index);
        try std.testing.expectEqual(@as(?usize, old), a.geometry_index);
    }
    for ([_]usize{ 5, 6 }, 62..) |old, i| {
        try std.testing.expectEqual(RenderPathGeometryCacheActionKind.evict, result.actions[i].kind);
        try std.testing.expectEqual(@as(?usize, old), result.actions[i].cache_index);
        try std.testing.expectEqual(@as(?usize, null), result.actions[i].geometry_index);
    }
    for (result.entries) |entry| try std.testing.expectEqual(@as(u64, 2), entry.last_used_frame);

    // Keep the original action-before-entry commit and eviction ordering.
    planner = RenderPathGeometryCachePlanner.init(entries[0..0], actions[0..1]);
    try std.testing.expectError(error.PathGeometryCacheListFull, planner.build(.{ .geometries = &current }, &previous, 3));
    try std.testing.expectEqual(@as(usize, 1), planner.action_len);
    try std.testing.expectEqual(@as(usize, 0), planner.entry_len);
    try std.testing.expectEqual(@as(?usize, 63), planner.actions[0].cache_index);
    planner = RenderPathGeometryCachePlanner.init(&entries, actions[0..0]);
    try std.testing.expectError(error.PathGeometryCacheListFull, planner.build(.{ .geometries = &current }, &previous, 3));
    try std.testing.expectEqual(@as(usize, 0), planner.entry_len);
    try std.testing.expectEqual(@as(usize, 0), planner.action_len);
    planner = RenderPathGeometryCachePlanner.init(&entries, actions[0..63]);
    try std.testing.expectError(error.PathGeometryCacheListFull, planner.build(.{ .geometries = &current }, &previous, 3));
    try std.testing.expectEqual(@as(usize, 62), planner.entry_len);
    try std.testing.expectEqual(@as(usize, 63), planner.action_len);
    try std.testing.expectEqual(@as(?usize, 5), planner.actions[62].cache_index);
    // A successful build after those failures must reset scratch and output.
    planner = RenderPathGeometryCachePlanner.init(&entries, &actions);
    const retry = try planner.build(.{ .geometries = &current }, &previous, 4);
    try std.testing.expectEqual(@as(usize, 64), retry.actions.len);
}

test "indexed path geometry cache bounds dense retained lookup work and keeps oversized fallback" {
    const count = 1024;
    var current: [count]RenderPathGeometry = undefined;
    var previous: [count]RenderPathGeometryCacheEntry = undefined;
    var entries: [count]RenderPathGeometryCacheEntry = undefined;
    var actions: [count]RenderPathGeometryCacheAction = undefined;
    for (&current, &previous, 0..) |*item, *entry, i| {
        item.* = cacheTestItem(i);
        entry.* = .{ .key = renderPathGeometryKey(item.*), .last_used_frame = 1 };
    }
    cache_key_comparisons = 0;
    const result = try (RenderPathGeometryPlan{ .geometries = &current }).cachePlan(&previous, 2, &entries, &actions);
    const comparisons = cache_key_comparisons;
    try std.testing.expectEqual(@as(usize, count), result.retainCount());
    try std.testing.expect(comparisons > 0);
    try std.testing.expect(comparisons < 16 * count);
    for (result.actions, 0..) |action, i| {
        try std.testing.expectEqual(@as(?usize, i), action.cache_index);
        try std.testing.expectEqual(@as(?usize, i), action.geometry_index);
    }

    // Library callers can exceed the runtime index budget: no truncation.
    const oversized_count = PathGeometryCacheIndex.max_entries + 1;
    var oversized: [oversized_count]RenderPathGeometry = undefined;
    for (&oversized) |*item| item.* = cacheTestItem(0);
    oversized[oversized_count - 1] = cacheTestItem(1);
    const fallback = try (RenderPathGeometryPlan{ .geometries = &oversized }).cachePlan(&.{}, 3, entries[0..2], actions[0..2]);
    try std.testing.expectEqual(@as(usize, 2), fallback.entries.len);
    try std.testing.expectEqual(@as(usize, 2), fallback.actions.len);
    try std.testing.expectEqual(@as(usize, 2), fallback.uploadCount());
    try std.testing.expectEqual(@as(?usize, 0), fallback.actions[0].geometry_index);
    try std.testing.expectEqual(@as(?usize, 2048), fallback.actions[1].geometry_index);
    try std.testing.expectEqualDeep(renderPathGeometryKey(cacheTestItem(1)), fallback.entries[1].key);
}

test "path geometry cache preserves in-place previous entry behavior" {
    var previous: [64]RenderPathGeometryCacheEntry = undefined;
    var current: [64]RenderPathGeometry = undefined;
    var actions: [128]RenderPathGeometryCacheAction = undefined;
    for (&previous, &current, 0..) |*entry, *item, i| {
        entry.* = .{ .key = renderPathGeometryKey(cacheTestItem(i)), .last_used_frame = 1 };
        item.* = cacheTestItem(63 - i);
    }
    try std.testing.expect(cacheEntrySlicesOverlap(&previous, previous[16..]));
    try std.testing.expect(!cacheEntrySlicesOverlap(previous[0..16], previous[16..]));
    const result = try (RenderPathGeometryPlan{ .geometries = &current }).cachePlan(&previous, 2, &previous, &actions);
    try std.testing.expectEqual(@as(usize, 64), result.entries.len);
    try std.testing.expectEqual(@as(usize, 64), result.actions.len);
    for (result.actions, 0..) |action, i| {
        try std.testing.expectEqual(@as(RenderPathGeometryCacheActionKind, if (i < 32) .retain else .upload), action.kind);
        try std.testing.expectEqual(if (i < 32) @as(?usize, 63 - i) else null, action.cache_index);
    }
}

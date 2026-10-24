//! Stack-bound guard for the runtime markup interpreter. An app-sized
//! message union (hundreds of arms, several carrying multi-kilobyte
//! records) and realistically deep nesting must build on a bounded
//! thread stack. The interpreter recurses once per element, so every
//! frame on that path has to stay independent of the union's arm count
//! and of the message's size; before per-tag constructors and the split
//! element builder, Debug frames grew with both and a hot-reloaded app
//! view exhausted the 16 MiB main-thread stack.

const std = @import("std");
const canvas = @import("root.zig");
const markup_view = @import("ui_markup_view.zig");

/// A payload as large as the heaviest records production apps carry in
/// their messages (bounded text buffers, field edits).
const Bulk = struct {
    bytes: [6144]u8 = @splat(0),
    len: usize = 0,
};

const WideMsg = union(enum) {
    tag0,
    tag1,
    tag2,
    tag3,
    tag4,
    tag5,
    tag6,
    tag7,
    tag8,
    tag9,
    tag10,
    tag11,
    tag12,
    tag13,
    tag14,
    tag15,
    tag16,
    tag17,
    tag18,
    tag19,
    tag20,
    tag21,
    tag22,
    tag23,
    tag24,
    tag25,
    tag26,
    tag27,
    tag28,
    tag29,
    tag30,
    tag31,
    tag32,
    tag33,
    tag34,
    tag35,
    tag36,
    tag37,
    tag38,
    tag39,
    tag40,
    tag41,
    tag42,
    tag43,
    tag44,
    tag45,
    tag46,
    tag47,
    tag48,
    tag49,
    tag50,
    tag51,
    tag52,
    tag53,
    tag54,
    tag55,
    tag56,
    tag57,
    tag58,
    tag59,
    tag60,
    tag61,
    tag62,
    tag63,
    tag64,
    tag65,
    tag66,
    tag67,
    tag68,
    tag69,
    tag70,
    tag71,
    tag72,
    tag73,
    tag74,
    tag75,
    tag76,
    tag77,
    tag78,
    tag79,
    tag80,
    tag81,
    tag82,
    tag83,
    tag84,
    tag85,
    tag86,
    tag87,
    tag88,
    tag89,
    tag90,
    tag91,
    tag92,
    tag93,
    tag94,
    tag95,
    tag96,
    tag97,
    tag98,
    tag99,
    tag100,
    tag101,
    tag102,
    tag103,
    tag104,
    tag105,
    tag106,
    tag107,
    tag108,
    tag109,
    tag110,
    tag111,
    tag112,
    tag113,
    tag114,
    tag115,
    tag116,
    tag117,
    tag118,
    tag119,
    tag120,
    tag121,
    tag122,
    tag123,
    tag124,
    tag125,
    tag126,
    tag127,
    tag128,
    tag129,
    tag130,
    tag131,
    tag132,
    tag133,
    tag134,
    tag135,
    tag136,
    tag137,
    tag138,
    tag139,
    tag140,
    tag141,
    tag142,
    tag143,
    tag144,
    tag145,
    tag146,
    tag147,
    tag148,
    tag149,
    tag150,
    tag151,
    tag152,
    tag153,
    tag154,
    tag155,
    tag156,
    tag157,
    tag158,
    tag159,
    pick0: u32,
    pick1: u32,
    pick2: u32,
    pick3: u32,
    pick4: u32,
    pick5: u32,
    pick6: u32,
    pick7: u32,
    pick8: u32,
    pick9: u32,
    pick10: u32,
    pick11: u32,
    pick12: u32,
    pick13: u32,
    pick14: u32,
    pick15: u32,
    pick16: u32,
    pick17: u32,
    pick18: u32,
    pick19: u32,
    pick20: u32,
    pick21: u32,
    pick22: u32,
    pick23: u32,
    name0: []const u8,
    name1: []const u8,
    name2: []const u8,
    name3: []const u8,
    name4: []const u8,
    name5: []const u8,
    name6: []const u8,
    name7: []const u8,
    name8: []const u8,
    name9: []const u8,
    name10: []const u8,
    name11: []const u8,
    bulk0: Bulk,
    bulk1: Bulk,
    bulk2: Bulk,
    bulk3: Bulk,
    bulk4: Bulk,
    bulk5: Bulk,
};

const Model = struct {
    title: []const u8 = "deep",
    index: u32 = 3,
};

/// Alternating elements and template expansions, as app views nest
/// shared templates inside their own containers.
const deep_source =
    \\<template name="frame" args="title">
    \\  <column gap="2" label="{title}">
    \\    <slot/>
    \\  </column>
    \\</template>
    \\<column gap="2">
    \\  <button on-press="tag0" label="Level 0">L0</button>
    \\  <button on-press="pick0:{index}" label="Pick 0">P0</button>
    \\  <use template="frame" title="Frame 1">
    \\    <button on-press="tag7" label="Level 1">L1</button>
    \\    <button on-press="pick1:{index}" label="Pick 1">P1</button>
    \\    <column gap="2">
    \\      <button on-press="tag14" label="Level 2">L2</button>
    \\      <button on-press="pick2:{index}" label="Pick 2">P2</button>
    \\      <use template="frame" title="Frame 3">
    \\        <button on-press="tag21" label="Level 3">L3</button>
    \\        <button on-press="pick3:{index}" label="Pick 3">P3</button>
    \\        <column gap="2">
    \\          <button on-press="tag28" label="Level 4">L4</button>
    \\          <button on-press="pick4:{index}" label="Pick 4">P4</button>
    \\          <use template="frame" title="Frame 5">
    \\            <button on-press="tag35" label="Level 5">L5</button>
    \\            <button on-press="pick5:{index}" label="Pick 5">P5</button>
    \\            <column gap="2">
    \\              <button on-press="tag42" label="Level 6">L6</button>
    \\              <button on-press="pick6:{index}" label="Pick 6">P6</button>
    \\              <use template="frame" title="Frame 7">
    \\                <button on-press="tag49" label="Level 7">L7</button>
    \\                <button on-press="pick7:{index}" label="Pick 7">P7</button>
    \\                <column gap="2">
    \\                  <button on-press="tag56" label="Level 8">L8</button>
    \\                  <button on-press="pick8:{index}" label="Pick 8">P8</button>
    \\                  <use template="frame" title="Frame 9">
    \\                    <button on-press="tag63" label="Level 9">L9</button>
    \\                    <button on-press="pick9:{index}" label="Pick 9">P9</button>
    \\                    <column gap="2">
    \\                      <button on-press="tag70" label="Level 10">L10</button>
    \\                      <button on-press="pick10:{index}" label="Pick 10">P10</button>
    \\                      <use template="frame" title="Frame 11">
    \\                        <button on-press="tag77" label="Level 11">L11</button>
    \\                        <button on-press="pick11:{index}" label="Pick 11">P11</button>
    \\                        <column gap="2">
    \\                          <button on-press="tag84" label="Level 12">L12</button>
    \\                          <button on-press="pick12:{index}" label="Pick 12">P12</button>
    \\                          <use template="frame" title="Frame 13">
    \\                            <button on-press="tag91" label="Level 13">L13</button>
    \\                            <button on-press="pick13:{index}" label="Pick 13">P13</button>
    \\                            <column gap="2">
    \\                              <button on-press="tag98" label="Level 14">L14</button>
    \\                              <button on-press="pick14:{index}" label="Pick 14">P14</button>
    \\                              <use template="frame" title="Frame 15">
    \\                                <button on-press="tag105" label="Level 15">L15</button>
    \\                                <button on-press="pick15:{index}" label="Pick 15">P15</button>
    \\                                <column gap="2">
    \\                                  <button on-press="tag112" label="Level 16">L16</button>
    \\                                  <button on-press="pick16:{index}" label="Pick 16">P16</button>
    \\                                  <use template="frame" title="Frame 17">
    \\                                    <button on-press="tag119" label="Level 17">L17</button>
    \\                                    <button on-press="pick17:{index}" label="Pick 17">P17</button>
    \\                                    <column gap="2">
    \\                                      <button on-press="tag126" label="Level 18">L18</button>
    \\                                      <button on-press="pick18:{index}" label="Pick 18">P18</button>
    \\                                      <use template="frame" title="Frame 19">
    \\                                        <button on-press="tag133" label="Level 19">L19</button>
    \\                                        <button on-press="pick19:{index}" label="Pick 19">P19</button>
    \\                                        <column gap="2">
    \\                                          <button on-press="tag140" label="Level 20">L20</button>
    \\                                          <button on-press="pick20:{index}" label="Pick 20">P20</button>
    \\                                          <use template="frame" title="Frame 21">
    \\                                            <button on-press="tag147" label="Level 21">L21</button>
    \\                                            <button on-press="pick21:{index}" label="Pick 21">P21</button>
    \\                                            <column gap="2">
    \\                                              <button on-press="tag154" label="Level 22">L22</button>
    \\                                              <button on-press="pick22:{index}" label="Pick 22">P22</button>
    \\                                              <use template="frame" title="Frame 23">
    \\                                                <button on-press="tag1" label="Level 23">L23</button>
    \\                                                <button on-press="pick23:{index}" label="Pick 23">P23</button>
    \\                                                <text>{title}</text>
    \\                                              </use>
    \\                                            </column>
    \\                                          </use>
    \\                                        </column>
    \\                                      </use>
    \\                                    </column>
    \\                                  </use>
    \\                                </column>
    \\                              </use>
    \\                            </column>
    \\                          </use>
    \\                        </column>
    \\                      </use>
    \\                    </column>
    \\                  </use>
    \\                </column>
    \\              </use>
    \\            </column>
    \\          </use>
    \\        </column>
    \\      </use>
    \\    </column>
    \\  </use>
    \\</column>
;

const invalid_source =
    \\<column gap="2">
    \\  <button on-press="no_such_tag" label="Broken">B</button>
    \\</column>
;

/// Comfortably below the 16 MiB main-thread stack the failure exhausted,
/// so the bound also covers the frames an app's own view code adds.
const bounded_stack_bytes = 4 * 1024 * 1024;

const Outcome = struct {
    built: bool = false,
    nodes: usize = 0,
    failure: ?anyerror = null,
    /// The press messages of the innermost level's two buttons, read back
    /// from the built nodes: splitting the element builder must keep each
    /// nested binding dispatching its own arm and model argument. The
    /// finalized handler count comes from `Ui.finalize` on the same
    /// thread: the app's hot-reload rebuild runs finalize over the same
    /// deep tree, so its per-element frames are bounded here too.
    deepest_level_press: ?WideMsg = null,
    deepest_pick_press: ?WideMsg = null,
    finalized_handlers: usize = 0,
};

fn countNodes(node: *const canvas.Ui(WideMsg).Node) usize {
    var total: usize = 1;
    for (node.nodes) |*child| total += countNodes(child);
    return total;
}

fn findLabel(node: *const canvas.Ui(WideMsg).Node, label: []const u8) ?*const canvas.Ui(WideMsg).Node {
    if (std.mem.eql(u8, node.widget.semantics.label, label)) return node;
    for (node.nodes) |*child| if (findLabel(child, label)) |found| return found;
    return null;
}

fn buildDeep(source: []const u8, outcome: *Outcome) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var view = markup_view.MarkupView(Model, WideMsg).init(arena, source) catch |err| {
        outcome.failure = err;
        return;
    };
    var ui = canvas.Ui(WideMsg).init(arena);
    const model: Model = .{};
    const node = view.build(&ui, &model) catch |err| {
        outcome.failure = err;
        return;
    };
    outcome.built = true;
    outcome.nodes = countNodes(&node);
    if (findLabel(&node, "Level 23")) |level| outcome.deepest_level_press = level.on_press;
    if (findLabel(&node, "Pick 23")) |pick| outcome.deepest_pick_press = pick.on_press;
    const tree = ui.finalize(node) catch |err| {
        outcome.failure = err;
        return;
    };
    outcome.finalized_handlers = tree.handlers.len;
}

fn buildOnBoundedStack(source: []const u8) !Outcome {
    var outcome: Outcome = .{};
    const thread = try std.Thread.spawn(.{ .stack_size = bounded_stack_bytes }, buildDeep, .{ source, &outcome });
    thread.join();
    return outcome;
}

test "an app-sized message union builds deep runtime markup on a bounded stack" {
    try std.testing.expect(@sizeOf(WideMsg) > 6144);
    const outcome = try buildOnBoundedStack(deep_source);
    try std.testing.expect(outcome.failure == null);
    try std.testing.expect(outcome.built);
    try std.testing.expect(outcome.nodes > 3 * 24);
    // Finalize — the app rebuild's own traversal over the same deep tree —
    // runs on the same bounded thread and collects all 48 press handlers
    // the deep levels bound (two buttons per level).
    try std.testing.expectEqual(@as(usize, 48), outcome.finalized_handlers);
    // Level 23 presses tag((23 * 7) % 160) = tag1; Pick 23 carries the
    // bound model index into pick23.
    try std.testing.expectEqual(std.meta.Tag(WideMsg).tag1, std.meta.activeTag(outcome.deepest_level_press orelse return error.TestUnexpectedResult));
    const pick = outcome.deepest_pick_press orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(std.meta.Tag(WideMsg).pick23, std.meta.activeTag(pick));
    try std.testing.expectEqual(@as(u32, 3), pick.pick23);
}

test "a failed runtime markup build on the bounded stack is followed by a valid one" {
    const broken = try buildOnBoundedStack(invalid_source);
    try std.testing.expect(!broken.built);
    try std.testing.expect(broken.failure != null);
    const recovered = try buildOnBoundedStack(deep_source);
    try std.testing.expect(recovered.failure == null);
    try std.testing.expect(recovered.built);
}

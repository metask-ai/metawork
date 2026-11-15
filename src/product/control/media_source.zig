//! Registry of the media Product may show the user, and the two tiers that
//! deliver it.
//!
//! Three producers mint their own identities and authority today: Run file
//! references, Host-generated media, and user attachments. The File Preview
//! target key assumes a Run produced the bytes and that they live inside an
//! authorized Workspace, which is why an attachment cannot enter it: its bytes
//! live in the Product-private store, or in memory while the draft still holds
//! them, so Workspace id/epoch/root are facts that simply do not exist for it.
//! This module keeps "which identity, which authority, which bytes, which tier"
//! in one place instead of letting each call site decide.
//!
//! Registered kinds are the ones that are actually served. Adding the reference
//! sources later is a change here plus their own authority, not a change to the
//! target shape.

const std = @import("std");
const attachment = @import("metawork_product_attachment");

pub const Kind = enum {
    /// A staged image in the Composer draft. Authority is the Bridge grant that
    /// issued its token: connection- and window-bound, one shot. No Task
    /// identity is involved, which is what lets New Task serve a draft chip.
    draft_attachment,
    /// An image a Run took as its input. Authority is that this window may read
    /// this Task and that the Run record still carries the identity Product
    /// persisted for it, not a draft grant: that grant was consumed when the
    /// message was sent.
    run_attachment,
    /// The same, for a message that was accepted but is still waiting for its
    /// turn. It is addressed by its submission rather than by a Run, because it
    /// does not have one yet.
    submission_attachment,

    pub fn fromWire(text: []const u8) ?Kind {
        if (std.mem.eql(u8, text, "draftAttachment")) return .draft_attachment;
        if (std.mem.eql(u8, text, "runAttachment")) return .run_attachment;
        if (std.mem.eql(u8, text, "submissionAttachment")) return .submission_attachment;
        return null;
    }
};

/// Highest position an attachment can occupy inside the message that owns it.
/// A message record is immutable once accepted, so the position is a stable
/// identity for the attachment at it.
pub const max_index: u32 = attachment.max_files_per_message - 1;

pub const Target = union(Kind) {
    draft_attachment: u64,
    run_attachment: struct { task_id: u64, run_id: u64, index: u32 },
    submission_attachment: struct { task_id: u64, operation_id: []const u8, index: u32 },
};

/// What a Task-owned target resolved to: the identity history persisted for an
/// accepted image, plus the facts that name its stored original. The owner of
/// the message record looks this up and hands it in, so this registry never
/// reaches into Task state itself.
pub const Accepted = struct {
    task_id: u64,
    media: attachment.Media,
    format: attachment.Format,
    size_bytes: u64,
};

/// Everything a resolution may read from, injected by Product Control.
pub const Sources = struct {
    staging: *attachment.Runtime,
    /// The record a Task-owned target named, or null when there is none to
    /// serve: a Task that is gone or being deleted, a message or position that
    /// is not there, an attachment that is not an image, a redacted record, or
    /// an image sent before this identity was persisted.
    accepted: ?Accepted = null,
    /// Scratch for one bounded derivative read. A Task-owned thumbnail needs
    /// `attachment.max_image_thumbnail_bytes` of it.
    thumbnail_buffer: []u8 = &.{},
};

pub const Tier = enum {
    /// Many at once, each tiny, loaded by viewport. Derived pixels only.
    thumbnail,
    /// One at a time, the original, on the existing bounded-read slot model.
    viewer,
};

/// Exactly the non-ready outcomes a resolution can produce. Control maps these
/// onto the File Preview states the Renderer already knows.
pub const Availability = enum { missing, restricted, unsupported };

/// The derived image is PNG because the Application image capability only
/// encodes PNG; a tier must not promise a media type the encoder cannot make.
pub const thumbnail_media_type = "image/png";

/// What each tier is allowed to do. These are the facts the two tiers differ
/// on; everything else (authority re-check before delivery, security epoch,
/// no body on a non-ready state) is shared.
pub const Policy = struct {
    /// Whether the tier hands out bytes read from the user's original file.
    delivers_original: bool,
    /// Whether the tier reserves one of the bounded original-image slots.
    reserves_image_slot: bool,
    /// Whether the credential gate scans the bytes being delivered. Derived
    /// pixels carry no container metadata from the original, so for them the
    /// delivered bytes are the only bytes worth scanning; scanning an original
    /// that never leaves Product would protect nothing.
    scans_delivered_bytes: bool,
    /// Whether the credential gate scans the complete original. Only the tier
    /// that delivers it needs this, and it keeps the existing chunked scan.
    scans_complete_original: bool,
    /// Upper bound on one delivered item, when this registry owns it. The
    /// viewer tier is null: its original-image ceiling belongs to Product's
    /// bounded read lane, and a second copy of that number here would be one
    /// more place to keep in sync.
    max_delivered_bytes: ?usize,
};

pub fn policy(tier: Tier) Policy {
    return switch (tier) {
        .thumbnail => .{
            .delivers_original = false,
            .reserves_image_slot = false,
            .scans_delivered_bytes = true,
            .scans_complete_original = false,
            .max_delivered_bytes = attachment.max_image_thumbnail_bytes,
        },
        .viewer => .{
            .delivers_original = true,
            .reserves_image_slot = true,
            .scans_delivered_bytes = false,
            .scans_complete_original = true,
            .max_delivered_bytes = null,
        },
    };
}

/// Derived pixels already in memory. Borrowed from the owning aggregate for the
/// duration of one call; never retained, never written to disk.
pub const Derived = struct {
    bytes: []const u8,
    width: u32,
    height: u32,
    media_type: []const u8 = thumbnail_media_type,
};

/// A bounded read target inside a Product-owned store. The physical path stays
/// with the store: a caller receives the root plus the store-relative name and
/// opens it without following links.
pub const Stored = struct {
    directory: []const u8,
    relative: []const u8,
    size_bytes: usize,
};

pub const Resolution = union(enum) {
    derived: Derived,
    stored: Stored,
    unavailable: Availability,
};

/// Resolve a target for one tier. `relative_buffer` receives the store-relative
/// name for a viewer resolution and must be at least
/// `attachment.max_original_relative_bytes` long.
pub fn resolve(
    target: Target,
    tier: Tier,
    sources: Sources,
    relative_buffer: []u8,
) Resolution {
    switch (target) {
        .draft_attachment => |id| {
            if (id == 0) return .{ .unavailable = .missing };
            return switch (tier) {
                .thumbnail => if (sources.staging.thumbnailFor(id)) |thumbnail| .{ .derived = .{
                    .bytes = thumbnail.bytes,
                    .width = thumbnail.width,
                    .height = thumbnail.height,
                } } else .{ .unavailable = .missing },
                .viewer => if (sources.staging.originalFor(id, relative_buffer)) |original| .{ .stored = .{
                    .directory = original.directory,
                    .relative = original.relative,
                    .size_bytes = original.size_bytes,
                } } else .{ .unavailable = .missing },
            };
        },
        // The two Task-owned kinds differ only in which message record names
        // the identity; once its owner resolved that, the bytes are addressed
        // the same way. The derivative is read rather than re-derived: staging
        // encoded it when the message was sent, so a history chip never reads
        // an original and never decodes an image to show itself.
        .run_attachment, .submission_attachment => {
            const accepted = sources.accepted orelse return .{ .unavailable = .missing };
            return switch (tier) {
                .thumbnail => if (sources.staging.readAcceptedThumbnail(
                    accepted.media,
                    accepted.task_id,
                    sources.thumbnail_buffer,
                )) |thumbnail| .{ .derived = .{
                    .bytes = thumbnail.bytes,
                    .width = thumbnail.width,
                    .height = thumbnail.height,
                } } else .{ .unavailable = .missing },
                .viewer => if (sources.staging.acceptedOriginal(
                    accepted.media,
                    accepted.task_id,
                    accepted.format,
                    accepted.size_bytes,
                    relative_buffer,
                )) |original| .{ .stored = .{
                    .directory = original.directory,
                    .relative = original.relative,
                    .size_bytes = original.size_bytes,
                } } else .{ .unavailable = .missing },
            };
        },
    }
}

test "only registered wire kinds resolve to a target" {
    try std.testing.expectEqual(Kind.draft_attachment, Kind.fromWire("draftAttachment").?);
    try std.testing.expectEqual(Kind.run_attachment, Kind.fromWire("runAttachment").?);
    try std.testing.expectEqual(Kind.submission_attachment, Kind.fromWire("submissionAttachment").?);
    for ([_][]const u8{ "", "draft_attachment", "draftattachment", "run_attachment", "inputAttachment", "fileReference", "workspacePath" }) |text|
        try std.testing.expect(Kind.fromWire(text) == null);
}

test "the thumbnail tier never delivers an original and never holds a slot" {
    const thumbnail = policy(.thumbnail);
    try std.testing.expect(!thumbnail.delivers_original);
    try std.testing.expect(!thumbnail.reserves_image_slot);
    try std.testing.expect(thumbnail.scans_delivered_bytes and !thumbnail.scans_complete_original);
    try std.testing.expectEqual(attachment.max_image_thumbnail_bytes, thumbnail.max_delivered_bytes.?);
    const viewer = policy(.viewer);
    try std.testing.expect(viewer.delivers_original and viewer.reserves_image_slot);
    try std.testing.expect(viewer.scans_complete_original and !viewer.scans_delivered_bytes);
    // One response carries a whole derived item, so the thumbnail tier needs no
    // grant, no chunk reader and no held bytes between calls.
    try std.testing.expect(std.base64.standard.Encoder.calcSize(thumbnail.max_delivered_bytes.?) < 1024 * 1024);
    try std.testing.expect(viewer.max_delivered_bytes == null);
}

test "an unknown or unstaged draft identity resolves to missing in both tiers" {
    var staging = try attachment.Runtime.init(std.testing.allocator, .{
        .max_files = 2,
        .max_records = 2,
        .max_display_name_bytes = 32,
        .max_file_bytes = 1024,
        .max_staged_bytes = 2048,
    }, null, .{}, null);
    defer staging.deinit();
    var relative: [attachment.max_original_relative_bytes]u8 = undefined;
    var thumbnail: [attachment.max_image_thumbnail_bytes]u8 = undefined;
    const sources: Sources = .{ .staging = &staging, .thumbnail_buffer = &thumbnail };
    for ([_]Tier{ .thumbnail, .viewer }) |tier| {
        for ([_]u64{ 0, 1, 99 }) |id| {
            const resolution = resolve(.{ .draft_attachment = id }, tier, sources, &relative);
            try std.testing.expectEqual(Availability.missing, resolution.unavailable);
        }
    }
}

test "a Task-owned target with no record resolves to missing in both tiers" {
    var staging = try attachment.Runtime.init(std.testing.allocator, .{
        .max_files = 2,
        .max_records = 2,
        .max_display_name_bytes = 32,
        .max_file_bytes = 1024,
        .max_staged_bytes = 2048,
    }, null, .{}, null);
    defer staging.deinit();
    var relative: [attachment.max_original_relative_bytes]u8 = undefined;
    var thumbnail: [attachment.max_image_thumbnail_bytes]u8 = undefined;
    // A deleted Task, a message that is not there, a position that is not an
    // image, a redacted record and an image sent before the identity existed
    // all arrive here as the same absent record.
    const sources: Sources = .{ .staging = &staging, .thumbnail_buffer = &thumbnail };
    for ([_]Target{
        .{ .run_attachment = .{ .task_id = 3, .run_id = 4, .index = 0 } },
        .{ .submission_attachment = .{ .task_id = 3, .operation_id = "op-1", .index = max_index } },
    }) |target| {
        for ([_]Tier{ .thumbnail, .viewer }) |tier|
            try std.testing.expectEqual(Availability.missing, resolve(target, tier, sources, &relative).unavailable);
    }
}

//! core_facade.ts emission: the TypeScript projection of the same
//! contract the Zig mirror carries. One sidecar, two projections — the
//! host imports core_shim.zig, a compiler consumes this module — so the
//! two sides can never skew: types, declaration orders, number classes,
//! wire tags, and the canonical value encoding all derive from one
//! artifact.
//!
//! The emitted module is subset TypeScript the shipped checker accepts,
//! and it is deliberately SELF-CONTAINED: it declares the contract's
//! mirror types itself instead of importing the author's module,
//! because today's subset rules pin the behavioral entry points to the
//! compile entry (a core exporting update from an imported module is
//! refused, and command values may not leave update's return path).
//! The behavioral surface — dispatch entries that run the author's
//! update, command-byte encoding, helper forwarders — therefore stays
//! with the compile mode that owns those dispensations; what THIS
//! module carries is everything the byte contract needs stated in
//! TypeScript:
//!
//! - the mirror types (interfaces, literal-union enums, kind-tagged
//!   message union) with the sidecar's names, field orders, and — for
//!   single-payload arms, whose authored member names the emitted
//!   contract erases — a fixed `value` member that erases identically;
//! - the declaration-order wire-tag table and one typed constructor per
//!   message arm (`nsc_core_msg_<arm>`), throwing a kind-tagged
//!   teaching value on contract violations;
//! - the canonical value encoding, including the arithmetic f64 bit
//!   extractor (exact for every finite double, the infinities, and the
//!   canonical quiet NaN), exported as `nsc_core_model_snapshot` plus
//!   the two scalar probes the parity suite drives;
//! - the channel bytes envelope: the wire-shaped channel entries, one
//!   per wired channel (`nsc_core_<channel>_msg`), whose parameters
//!   mirror the compiled core's C declarations and whose whole
//!   multi-value result rides ONE bytes return — [produced u8][tag u8]
//!   [payload…]. Each builds its event record, runs the channel
//!   function (a null gate here, the compile mode's author seam, like
//!   `update` below), and packs the result through the exported packer
//!   (`nsc_core_pack_msg`), the produced-message-or-null surface hosts
//!   holding a mirror value use directly;
//! - the identity constants, the sidecar's unbound-list declarations
//!   (authors declare nothing; the generator carries them), and
//!   deterministic zero/sample model builders so a compiled facade can
//!   prove its encodings against the host's canonical encoder.
//!
//! Input model: the generator consumes CONTRACT FACTS — the author
//! module's own declarations (types, arms, unbound markings) plus the
//! profile's constants. In production those facts precede compilation
//! (the facade is the compile's entry, so no compiler-emitted artifact
//! can feed it); the conformance harness drives this emitter from
//! corpus sidecars as its adapter, which is sound because a sidecar
//! encodes exactly those facts. Deterministic: a pure function of the
//! fact value, pinned by a test. FACADE-GAPS in SCHEMA-GAPS.md records
//! each inexpressible surface with the subset rule that pins it.

const std = @import("std");
const sidecar_mod = @import("sidecar.zig");
const emit_mod = @import("emit.zig");

const Sidecar = sidecar_mod.Sidecar;
const TypeRef = sidecar_mod.TypeRef;

pub const Error = error{ Refused, OutOfMemory };

pub fn emitFacade(arena: std.mem.Allocator, sidecar: Sidecar, diags: *sidecar_mod.Diagnostics) Error![]const u8 {
    var emitter = FacadeEmitter{
        .arena = arena,
        .sidecar = sidecar,
        .diags = diags,
        .out = .empty,
    };
    try emitter.run();
    if (diags.hasErrors()) return error.Refused;
    return emitter.out.items;
}

/// TypeScript reserved words a declaration may not take (no quoting
/// escape exists on that side, unlike Zig's @"..." names).
const ts_reserved_words = [_][]const u8{
    "break",     "case",      "catch",  "class",   "const",      "continue",   "debugger",  "default",
    "delete",    "do",        "else",   "enum",    "export",     "extends",    "false",     "finally",
    "for",       "function",  "if",     "import",  "in",         "instanceof", "new",       "null",
    "return",    "super",     "switch", "this",    "throw",      "true",       "try",       "typeof",
    "var",       "void",      "while",  "with",    "let",        "static",     "yield",     "await",
    "interface", "type",      "number", "boolean", "string",     "object",     "undefined",
    // Intrinsic type keywords: a declaration under one would make every
    // reference bind the built-in, erasing the contract silently.
    "any",
    "unknown",   "never",     "bigint", "symbol",
    // Strict-mode reservations (modules are always strict).
     "implements", "package",    "private",   "protected",
    "public",    "arguments", "eval",
};

const FacadeEmitter = struct {
    arena: std.mem.Allocator,
    sidecar: Sidecar,
    diags: *sidecar_mod.Diagnostics,
    out: std.ArrayListUnmanaged(u8),
    inlined: []const []const u8 = &.{},
    flattened: []const []const u8 = &.{},
    node_stored: []const []const u8 = &.{},
    sample_ordinal: usize = 0,
    sample_slice_depth: usize = 0,

    /// The projection's spelling for a table name: the compile profile
    /// designates the root exports `Model` and `Msg` by exact name (the
    /// root's commit machinery and dispatch wiring key on them), so the
    /// facade DECLARES its roots under those spellings whatever the
    /// contract calls them, and aliases the contract names for
    /// reference fidelity. TypeScript type names never reach the host's
    /// reflection surface, so this renames nothing observable.
    fn spellName(self: *FacadeEmitter, name: []const u8) []const u8 {
        if (std.mem.eql(u8, name, self.sidecar.model)) return "Model";
        if (std.mem.eql(u8, name, self.sidecar.msg.name)) return "Msg";
        return name;
    }

    fn print(self: *FacadeEmitter, comptime fmt: []const u8, args: anytype) Error!void {
        const text = try std.fmt.allocPrint(self.arena, fmt, args);
        try self.out.appendSlice(self.arena, text);
    }

    fn raw(self: *FacadeEmitter, text: []const u8) Error!void {
        try self.out.appendSlice(self.arena, text);
    }

    fn run(self: *FacadeEmitter) Error!void {
        self.inlined = try emit_mod.inlinedTableNames(self.arena, self.sidecar);
        self.flattened = try self.flattenedTableNames();
        self.node_stored = try self.nodeStoredTableNames();
        try self.validateNames();
        self.validateOptionalDepth();
        if (self.diags.hasErrors()) return;
        try self.header();
        try self.typeMirrors();
        try self.unboundDecl();
        try self.hostChannelDecls();
        try self.entryPoints();
        try self.constants();
        try self.msgConstructors();
        try self.sampleBuilders();
        try self.encoders();
        try self.channelEntries();
    }

    // ------------------------------------------------------- fencing

    fn validateNames(self: *FacadeEmitter) Error!void {
        // Declaration names (type-table entries and the message union)
        // must be plain TypeScript identifiers: TypeScript has no
        // quoted-declaration escape. Field, member, and arm names are
        // free — properties may quote, and arm names ride string
        // literals plus identifier FRAGMENTS (constructor suffixes), so
        // they only need fragment-safe characters.
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.sidecar.types.structs) |entry| try names.append(self.arena, entry.name);
        for (self.sidecar.types.enums) |entry| try names.append(self.arena, entry.name);
        for (self.sidecar.types.unions) |entry| try names.append(self.arena, entry.name);
        try names.append(self.arena, self.sidecar.msg.name);

        for (names.items) |name| {
            if (pipelineIdentifierIssue(name, .declaration)) |issue| {
                self.diags.flag("types", "type name \"{s}\" {s} — the facade must stay declarable end to end (TypeScript source, then the compiled module, which takes identifiers verbatim); rename it in the core source", .{ name, issue });
            }
            // Ambient globals the generated module leans on: a local
            // declaration would shadow them out from under the encoders.
            if (std.mem.eql(u8, name, "Uint8Array")) {
                self.diags.flag("types", "\"Uint8Array\" shadows the ambient byte type every encoder in the generated facade uses; rename the type in the core source", .{});
            }
        }
        // Arm names become union members and constructor-name fragments
        // in the compiled module; member and field names become its
        // struct fields and enum members — all verbatim.
        for (self.sidecar.msg.arms) |arm| {
            if (pipelineIdentifierIssue(arm.name, .member)) |issue| {
                self.diags.flag("msg.arms", "arm \"{s}\" {s} — the facade must stay declarable end to end; rename it in the core source", .{ arm.name, issue });
            }
        }
        for (self.sidecar.types.unions) |entry| {
            for (entry.arms) |arm| {
                if (pipelineIdentifierIssue(arm.name, .member)) |issue| {
                    self.diags.flag("types.unions", "arm \"{s}\" of \"{s}\" {s} — the facade must stay declarable end to end; rename it in the core source", .{ arm.name, entry.name, issue });
                }
            }
        }
        for (self.sidecar.types.enums) |entry| {
            for (entry.members) |member| {
                if (pipelineIdentifierIssue(member, .member)) |issue| {
                    self.diags.flag("types.enums", "member \"{s}\" of \"{s}\" {s} — the facade must stay declarable end to end; rename it in the core source", .{ member, entry.name, issue });
                }
            }
        }
        // Field names ride to the compiled module's struct fields
        // verbatim (and the subset accepts identifier-named properties
        // only), so the pipeline rule covers them whole.
        for (self.sidecar.types.structs) |entry| {
            for (entry.fields) |field| {
                if (pipelineIdentifierIssue(field.name, .member)) |issue| {
                    self.diags.flag("types", "field \"{s}\" {s} — the facade must stay declarable end to end; rename it in the core source", .{ field.name, issue });
                }
            }
        }
        for (self.sidecar.msg.arms) |arm| {
            switch (arm.payload) {
                .number_bytes => |desc| {
                    for ([_][]const u8{ desc.number_field, desc.bytes_field }) |field_name| {
                        if (pipelineIdentifierIssue(field_name, .member)) |issue| {
                            self.diags.flag("msg.arms", "field \"{s}\" {s} — the facade must stay declarable end to end; rename it in the core source", .{ field_name, issue });
                        }
                    }
                },
                else => {},
            }
        }
        // Flattened arm fields share the object with the `kind`
        // discriminator: a number_bytes field or a synthesized inline
        // record field spelled "kind" would declare the discriminator
        // twice. Named record payloads ride a `value` member and stay
        // unaffected.
        for (self.sidecar.msg.arms) |arm| {
            switch (arm.payload) {
                .number_bytes => |desc| {
                    for ([_][]const u8{ desc.number_field, desc.bytes_field }) |field_name| {
                        if (std.mem.eql(u8, field_name, "kind")) {
                            self.diags.flag("msg.arms", "arm \"{s}\" flattens a field spelled \"kind\" beside the message discriminator of the same name; rename the field in the core source", .{arm.name});
                        }
                    }
                },
                .record => {
                    if (self.synthesizedRecordOf(recordPayloadRef(arm.payload), self.sidecar.msg.name, arm.name)) |record| {
                        for (record.fields) |field| {
                            if (std.mem.eql(u8, field.name, "kind")) {
                                self.diags.flag("msg.arms", "arm \"{s}\" flattens a field spelled \"kind\" beside the message discriminator of the same name; rename the field in the core source", .{arm.name});
                            }
                        }
                    }
                },
                else => {},
            }
        }
        for (self.sidecar.types.unions) |entry| {
            for (entry.arms) |arm| {
                if (arm.payload == .void) continue;
                if (self.synthesizedRecordOf(arm.payload, entry.name, arm.name)) |record| {
                    for (record.fields) |field| {
                        if (std.mem.eql(u8, field.name, "kind")) {
                            self.diags.flag("types.unions", "arm \"{s}\" of \"{s}\" flattens a field spelled \"kind\" beside the arm discriminator of the same name; rename the field in the core source", .{ arm.name, entry.name });
                        }
                    }
                }
            }
        }
        for (self.sidecar.types.enums) |entry| {
            if (entry.members.len < 2) {
                self.diags.flag("types", "enum \"{s}\" has one member — a single string literal is not a union in the projected subset, so no source can author it; give the state a second member or fold it away in the core source", .{entry.name});
            }
        }
        var facade_decls: std.ArrayListUnmanaged([]const u8) = .empty;
        try facade_decls.appendSlice(self.arena, &.{ "initialModel", "update", "asciiBytes", "NscfContractError", "NSCF_POW" });
        if (self.sidecar.init_returns_cmd or self.sidecar.update_returns_cmd) try facade_decls.append(self.arena, "Cmd");
        if (self.sidecar.has_subscriptions) try facade_decls.append(self.arena, "Sub");
        // The unbound consts declare exactly when their lists are
        // nonempty (unboundDecl), so their names join the fence exactly
        // then: an unbound MODEL list needs at least one entry naming a
        // model field (helper entries stay sidecar facts here).
        const model_struct = sidecar_mod.findStruct(self.sidecar.types, self.sidecar.model).?;
        const any_field_unbound = blk: {
            for (self.sidecar.model_unbound) |name| {
                for (model_struct.fields) |field| {
                    if (std.mem.eql(u8, field.name, name)) break :blk true;
                }
            }
            break :blk false;
        };
        if (any_field_unbound or self.sidecar.msg.unbound.len > 0) try facade_decls.append(self.arena, "viewUnbound");
        if (any_field_unbound) try facade_decls.append(self.arena, "modelUnbound");
        if (self.sidecar.msg.unbound.len > 0) try facade_decls.append(self.arena, "msgUnbound");
        // Wired channels add their event records, the channel-function
        // null gates, and (pinch) the phase vocabulary to the facade's
        // own declarations; the host-constructed and environment
        // channels add their exported-const conventions; a subscribing
        // contract adds the subscriptions stub.
        if (self.sidecar.channels.command_msg) try facade_decls.append(self.arena, "commandMsg");
        if (self.sidecar.channels.frame_msg) try facade_decls.appendSlice(self.arena, &.{ "FrameEvent", "frameMsg" });
        if (self.sidecar.channels.key_msg) try facade_decls.appendSlice(self.arena, &.{ "KeyEvent", "keyMsg" });
        if (self.sidecar.channels.pinch_msg) try facade_decls.appendSlice(self.arena, &.{ "PinchPhase", "PinchEvent", "pinchMsg" });
        if (self.sidecar.channels.appearance_msg != null) try facade_decls.append(self.arena, "appearanceMsg");
        if (self.sidecar.channels.chrome_msg != null) try facade_decls.append(self.arena, "chromeMsg");
        if (self.sidecar.channels.env_msgs.len > 0) try facade_decls.append(self.arena, "envMsgs");
        if (self.sidecar.has_subscriptions) try facade_decls.append(self.arena, "subscriptions");
        // Field names join the fence only for the reserved nsc name
        // space (they may otherwise be anything, quoted if exotic):
        // constructor parameter fallbacks and the runtime prelude own
        // those spellings.
        for (self.sidecar.types.structs) |entry| {
            for (entry.fields) |field| {
                if (std.mem.startsWith(u8, field.name, "nsc_core_") or std.mem.startsWith(u8, field.name, "nscf")) {
                    self.diags.flag("types", "field \"{s}\" takes the facade's reserved nsc name space; rename it in the core source", .{field.name});
                }
            }
        }
        // number_bytes descriptor fields never enter the type table but
        // become constructor parameters and record members all the same.
        for (self.sidecar.msg.arms) |arm| {
            switch (arm.payload) {
                .number_bytes => |desc| {
                    for ([_][]const u8{ desc.number_field, desc.bytes_field }) |field_name| {
                        if (std.mem.startsWith(u8, field_name, "nsc_core_") or std.mem.startsWith(u8, field_name, "nscf")) {
                            self.diags.flag("msg.arms", "field \"{s}\" takes the facade's reserved nsc name space; rename it in the core source", .{field_name});
                        }
                    }
                },
                else => {},
            }
        }
        for (self.sidecar.types.structs) |entry| try self.fenceDecl(entry.name, facade_decls.items);
        for (self.sidecar.types.enums) |entry| try self.fenceDecl(entry.name, facade_decls.items);
        for (self.sidecar.types.unions) |entry| try self.fenceDecl(entry.name, facade_decls.items);
        try self.fenceDecl(self.sidecar.msg.name, facade_decls.items);

        // Declaration form spells storage ONCE per record, so a record
        // referenced both by node and by value has no projection — one
        // declaration cannot say both. (The transpiled lane decides
        // storage per TYPE, so its contracts never mix; a hand contract
        // that does must split the type.)
        var value_refs: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.sidecar.types.structs) |entry| {
            for (entry.fields) |field| try noteValueRefs(&value_refs, self.arena, field.type);
        }
        for (self.sidecar.types.unions) |entry| {
            for (entry.arms) |arm| try noteValueRefs(&value_refs, self.arena, arm.payload);
        }
        for (self.sidecar.model_helpers) |helper| {
            try noteValueRefs(&value_refs, self.arena, helper.returns);
            for (helper.params) |param| try noteValueRefs(&value_refs, self.arena, param);
        }
        for (self.sidecar.msg.arms) |arm| {
            switch (arm.payload) {
                .scalar => |ref| try noteValueRefs(&value_refs, self.arena, ref),
                else => {},
            }
        }
        for (value_refs.items) |name| {
            if (nameListed(self.node_stored, name)) {
                self.diags.flag("types", "\"{s}\" is stored by reference at one site and by value at another — the projection states storage once per declaration, so one record cannot say both; split the type in the core source", .{name});
            }
        }

        // Value records the MODEL keeps carry scalar fields only, and
        // model sequences carry reference-stored records: the facade's
        // consumers commit by-value records shallowly, so heap-backed
        // fields would dangle across frames and by-value arrays have no
        // commit walk. Refuse here, where the teaching can name the
        // record, instead of emitting a facade its compilers refuse.
        try self.validateModelValueRecords();

        // The host-constructed channels build their event record's
        // fields DIRECTLY on the named arm, so the arm's record must
        // flatten into the arm literal (the single-use synthesized
        // shape). A shared named record would project as a nested
        // `value` member no host construction can fill.
        if (self.sidecar.channels.appearance_msg) |arm_name| {
            try self.requireFlattenedChannelArm("channels.appearance_msg", arm_name);
        }
        if (self.sidecar.channels.chrome_msg) |arm_name| {
            try self.requireFlattenedChannelArm("channels.chrome_msg", arm_name);
        }
        if (!std.mem.eql(u8, self.sidecar.model, "Model")) try self.fenceDecl("", &.{}); // placeholder keeps shape symmetric
    }

    /// Walk the model tree and refuse the value-record shapes the
    /// facade's compilers cannot carry: a model-kept value record with
    /// a non-scalar field, and a model sequence of value records.
    fn validateModelValueRecords(self: *FacadeEmitter) Error!void {
        var visited: std.ArrayListUnmanaged([]const u8) = .empty;
        const model = sidecar_mod.findStruct(self.sidecar.types, self.sidecar.model) orelse return;
        for (model.fields) |field| {
            try self.visitModelRef(&visited, field.type);
        }
    }

    fn visitModelRef(self: *FacadeEmitter, visited: *std.ArrayListUnmanaged([]const u8), ref: TypeRef) Error!void {
        switch (ref) {
            .value => |name| {
                if (nameListed(visited.items, name)) return;
                try visited.append(self.arena, name);
                const entry = sidecar_mod.findStruct(self.sidecar.types, name) orelse return;
                for (entry.fields) |field| {
                    const scalar = switch (field.type) {
                        .f64, .i64, .bool, .enum_ref => true,
                        else => false,
                    };
                    if (!scalar) {
                        self.diags.flag("types", "\"{s}\" is a value-stored record the model keeps, but field \"{s}\" is not a scalar — the compiled projection commits value records shallowly, so heap-backed fields would dangle across frames; store \"{s}\" by reference in the core source", .{ name, field.name, name });
                        break;
                    }
                }
            },
            .node => |name| {
                if (nameListed(visited.items, name)) return;
                try visited.append(self.arena, name);
                const entry = sidecar_mod.findStruct(self.sidecar.types, name) orelse return;
                for (entry.fields) |field| {
                    try self.visitModelRef(visited, field.type);
                }
            },
            .union_ref => |name| {
                if (nameListed(visited.items, name)) return;
                try visited.append(self.arena, name);
                const entry = sidecar_mod.findUnion(self.sidecar.types, name) orelse return;
                for (entry.arms) |arm| {
                    try self.visitModelRef(visited, arm.payload);
                }
            },
            .slice => |elem| {
                const element = if (elem.* == .optional) elem.optional.* else elem.*;
                if (element == .value) {
                    self.diags.flag("types", "a model sequence holds \"{s}\" by value — sequences the model keeps carry reference-stored records (the compiled projection has no by-value sequence commit); store \"{s}\" by reference in the core source", .{ element.value, element.value });
                }
                try self.visitModelRef(visited, elem.*);
            },
            .optional => |inner| try self.visitModelRef(visited, inner.*),
            else => {},
        }
    }

    /// Refuse a host-constructed channel arm whose record does not
    /// flatten into its arm literal.
    fn requireFlattenedChannelArm(self: *FacadeEmitter, at: []const u8, arm_name: []const u8) Error!void {
        const arm = sidecar_mod.findArm(self.sidecar.msg, arm_name) orelse return;
        switch (arm.payload) {
            .record => |name| {
                if (nameListed(self.flattened, name)) return;
                self.diags.flag(at, "arm \"{s}\" carries the named record \"{s}\", which the projection cannot flatten into the arm (the host fills the event's fields directly on the arm) — declare the event's fields inline on the arm in the core source", .{ arm_name, name });
            },
            else => {},
        }
    }

    fn fenceDecl(self: *FacadeEmitter, name: []const u8, facade_decls: []const []const u8) Error!void {
        if (name.len == 0) return;
        if (std.mem.startsWith(u8, name, "nsc_core_") or std.mem.startsWith(u8, name, "nscf")) {
            self.diags.flag("types", "\"{s}\" collides with the facade's reserved nsc name space; rename it in the core source", .{name});
            return;
        }
        for (facade_decls) |decl| {
            if (std.mem.eql(u8, name, decl)) {
                self.diags.flag("types", "\"{s}\" collides with a declaration the generated facade itself must make; rename it in the core source", .{name});
            }
        }
        // The facade aliases the entry vocabulary's fixed spellings when
        // the sidecar's own names differ (mirroring the Zig side).
        if (!std.mem.eql(u8, self.sidecar.model, name) and std.mem.eql(u8, name, "Model") and !std.mem.eql(u8, self.sidecar.model, "Model")) {
            self.diags.flag("types", "\"Model\" collides with the facade's entry alias for the model root; rename it in the core source", .{});
        }
        if (!std.mem.eql(u8, self.sidecar.msg.name, name) and std.mem.eql(u8, name, "Msg") and !std.mem.eql(u8, self.sidecar.msg.name, "Msg")) {
            self.diags.flag("types", "\"Msg\" collides with the facade's entry alias for the message union; rename it in the core source", .{});
        }
    }

    /// TypeScript's null carries exactly one absence level, so a nested
    /// optional has no faithful projection (its own source language
    /// cannot author one either: `T | null | null` collapses).
    fn validateOptionalDepth(self: *FacadeEmitter) void {
        for (self.sidecar.types.structs, 0..) |entry, index| {
            for (entry.fields, 0..) |field, field_index| {
                self.flagNestedOptional(field.type, false, pathText(self.arena, "types.structs[{d}].fields[{d}].type", .{ index, field_index }));
            }
        }
        for (self.sidecar.types.unions, 0..) |entry, index| {
            for (entry.arms, 0..) |arm, arm_index| {
                self.flagNestedOptional(arm.payload, false, pathText(self.arena, "types.unions[{d}].arms[{d}].payload", .{ index, arm_index }));
            }
        }
        for (self.sidecar.model_helpers, 0..) |helper, index| {
            self.flagNestedOptional(helper.returns, false, pathText(self.arena, "model_helpers[{d}].returns", .{index}));
            for (helper.params, 0..) |param, param_index| {
                self.flagNestedOptional(param, false, pathText(self.arena, "model_helpers[{d}].params[{d}]", .{ index, param_index }));
            }
        }
        for (self.sidecar.msg.arms, 0..) |arm, index| {
            switch (arm.payload) {
                .scalar => |ref| self.flagNestedOptional(ref, false, pathText(self.arena, "msg.arms[{d}].payload.type", .{index})),
                else => {},
            }
        }
    }

    fn flagNestedOptional(self: *FacadeEmitter, ref: TypeRef, inside_optional: bool, at: []const u8) void {
        switch (ref) {
            .optional => |inner| {
                if (inside_optional) {
                    self.diags.flag(at, "a nested optional has no TypeScript projection — one null carries one absence level, and the source language cannot author a second; flatten the state in the core source", .{});
                    return;
                }
                self.flagNestedOptional(inner.*, true, at);
            },
            .slice => |elem| self.flagNestedOptional(elem.*, false, at),
            else => {},
        }
    }

    // ------------------------------------------------------- sections

    fn header(self: *FacadeEmitter) Error!void {
        // The effect vocabulary joins the import exactly when a
        // contract shape needs it: Cmd for a cmd-returning entry stub,
        // Sub for the subscriptions stub.
        const needs_cmd = self.sidecar.init_returns_cmd or self.sidecar.update_returns_cmd;
        const imports: []const u8 = if (needs_cmd and self.sidecar.has_subscriptions)
            "Cmd, Sub, asciiBytes"
        else if (needs_cmd)
            "Cmd, asciiBytes"
        else if (self.sidecar.has_subscriptions)
            "Sub, asciiBytes"
        else
            "asciiBytes";
        try self.print(
            \\// Generated by corewire from this app's core.contract.json — the
            \\// TypeScript projection of the compiled core's contract. The same
            \\// sidecar generates the host's Zig mirror (core_shim.zig), so the
            \\// two sides carry one set of types, wire tags, field orders, and
            \\// byte encodings by construction. Do not edit; regenerate from the
            \\// sidecar.
            \\//
            \\// Contract identity: entry {s}, compiler {s}, build_id
            \\// {x:0>16}.
            \\
            \\import {{ {s} }} from "@native-sdk/core";
            \\
        , .{ try commentText(self.arena, self.sidecar.entry), try commentText(self.arena, self.sidecar.compiler_version), self.sidecar.build_id, imports });
    }

    fn typeMirrors(self: *FacadeEmitter) Error!void {
        for (self.sidecar.types.enums) |entry| {
            try self.print("\nexport type {s} =", .{entry.name});
            for (entry.members, 0..) |member, index| {
                try self.print("{s} \"{s}\"", .{ if (index == 0) "" else " |", try tsString(self.arena, member) });
            }
            try self.raw(";\n");
        }
        // Every table entry gets a NAMED declaration — except the
        // flattened single-use records, whose whole shape lives inline
        // in their one arm literal and whose synthesized names must
        // stay undeclared (a downstream consumer of the module
        // re-derives the same names from the inline arms).
        for (self.sidecar.types.structs) |*entry| {
            if (std.mem.eql(u8, entry.name, self.sidecar.model)) continue;
            if (nameListed(self.flattened, entry.name)) continue;
            try self.structInterface(entry);
        }
        for (self.sidecar.types.unions) |entry| {
            try self.print("\nexport type {s} =", .{entry.name});
            for (entry.arms) |arm| {
                try self.print("\n  | {s}", .{try self.armTypeLiteral(entry.name, arm.name, armPayloadRef(arm))});
            }
            try self.raw(";\n");
        }
        const model = sidecar_mod.findStruct(self.sidecar.types, self.sidecar.model).?;
        try self.structInterface(model);
        if (!std.mem.eql(u8, self.sidecar.model, "Model")) {
            try self.print("\n/// The contract's own spelling for the root state type (the\n/// declaration takes the profile's designated export name).\nexport type {s} = Model;\n", .{self.sidecar.model});
        }

        try self.raw("\nexport type Msg =");
        for (self.sidecar.msg.arms) |arm| {
            try self.print("\n  | {s}", .{try self.msgArmTypeLiteral(arm)});
        }
        try self.raw(";\n");
        if (!std.mem.eql(u8, self.sidecar.msg.name, "Msg")) {
            try self.print("\n/// The contract's own spelling for the message union (the\n/// declaration takes the profile's designated export name).\nexport type {s} = Msg;\n", .{self.sidecar.msg.name});
        }
    }

    fn structInterface(self: *FacadeEmitter, entry: *const sidecar_mod.Struct) Error!void {
        // Declaration form spells storage for a contract emitter that
        // re-derives it: node-stored records (and the model root, whose
        // designation must be an interface) declare as interfaces;
        // value-stored records take the object-literal alias form.
        const as_interface = nameListed(self.node_stored, entry.name) or std.mem.eql(u8, entry.name, self.sidecar.model);
        if (as_interface) {
            try self.print("\nexport interface {s} {{", .{self.spellName(entry.name)});
        } else {
            try self.print("\nexport type {s} = {{", .{self.spellName(entry.name)});
        }
        for (entry.fields) |field| {
            try self.print("\n  readonly {s}: {s};", .{ try tsProp(self.arena, field.name), try self.spellRef(field.type, entry.name, field.name) });
        }
        try self.raw(if (as_interface) "\n}\n" else "\n};\n");
    }

    /// One arm of a kind-tagged union type: bare, single `value`
    /// member, or (for a synthesized inline record) the record's own
    /// fields flattened beside `kind`. Single-payload member names are
    /// the facade's choice — the emitted contract erases them, so any
    /// spelling projects to the same compiled layout.
    fn armTypeLiteral(self: *FacadeEmitter, union_name: []const u8, arm_name: []const u8, payload: ?TypeRef) Error![]const u8 {
        const escaped = try tsString(self.arena, arm_name);
        const ref = payload orelse
            return std.fmt.allocPrint(self.arena, "{{ readonly kind: \"{s}\" }}", .{escaped});
        // A synthesized inline record flattens beside `kind`, exactly
        // as its authoring produced it; everything else is a single
        // payload whose authored member name the contract erased.
        if (self.synthesizedRecordOf(ref, union_name, arm_name)) |record| {
            var text: std.ArrayListUnmanaged(u8) = .empty;
            try text.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "{{ readonly kind: \"{s}\"", .{escaped}));
            for (record.fields) |field| {
                try text.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "; readonly {s}: {s}", .{ try tsProp(self.arena, field.name), try self.spellRef(field.type, record.name, field.name) }));
            }
            try text.appendSlice(self.arena, " }");
            return text.items;
        }
        return std.fmt.allocPrint(self.arena, "{{ readonly kind: \"{s}\"; readonly value: {s} }}", .{ escaped, try self.spellRef(ref, union_name, arm_name) });
    }

    /// The synthesized single-use records this projection flattens into
    /// their one arm literal: neither an interface declaration nor a
    /// named encoder ever spells them, so their synthesized names stay
    /// free for any downstream consumer of the module that re-derives
    /// the same names from the inline arms.
    fn flattenedTableNames(self: *FacadeEmitter) Error![]const []const u8 {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.sidecar.msg.arms) |arm| {
            switch (arm.payload) {
                .record => {
                    if (self.synthesizedRecordOf(recordPayloadRef(arm.payload), self.sidecar.msg.name, arm.name)) |record| {
                        try names.append(self.arena, record.name);
                    }
                },
                else => {},
            }
        }
        for (self.sidecar.types.unions) |entry| {
            for (entry.arms) |arm| {
                if (arm.payload == .void) continue;
                if (self.synthesizedRecordOf(arm.payload, entry.name, arm.name)) |record| {
                    try names.append(self.arena, record.name);
                }
            }
        }
        return names.items;
    }

    /// The record names the contract stores BY REFERENCE anywhere: they
    /// declare as interfaces (the projection's node-storage spelling);
    /// every other record declares as an object-literal type alias (the
    /// value-storage spelling), so a contract emitter re-deriving
    /// storage from declaration form lands on the contract's own
    /// classes.
    fn nodeStoredTableNames(self: *FacadeEmitter) Error![]const []const u8 {
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        // The model root is reference-stored by contract (no explicit
        // reference spells it), so it seeds the set: a `value`
        // reference to the root elsewhere is the mixed-storage case and
        // refuses like any other.
        try names.append(self.arena, self.sidecar.model);
        for (self.sidecar.types.structs) |entry| {
            for (entry.fields) |field| {
                try noteNodeRefs(&names, self.arena, field.type);
            }
        }
        for (self.sidecar.types.unions) |entry| {
            for (entry.arms) |arm| {
                try noteNodeRefs(&names, self.arena, arm.payload);
            }
        }
        for (self.sidecar.model_helpers) |helper| {
            try noteNodeRefs(&names, self.arena, helper.returns);
            for (helper.params) |param| try noteNodeRefs(&names, self.arena, param);
        }
        for (self.sidecar.msg.arms) |arm| {
            switch (arm.payload) {
                .scalar => |ref| try noteNodeRefs(&names, self.arena, ref),
                else => {},
            }
        }
        return names.items;
    }

    /// The struct behind a synthesized, inlined record reference at
    /// this site — the shape that flattens beside `kind`. VALUE
    /// references only: flattening is a by-value layout, so a
    /// node-stored payload keeps its named declaration however its
    /// name is spelled.
    fn synthesizedRecordOf(self: *FacadeEmitter, ref: TypeRef, container: []const u8, member: []const u8) ?*const sidecar_mod.Struct {
        const name = switch (ref) {
            .value => |n| n,
            else => return null,
        };
        if (!emit_mod.isSynthesizedRef(container, member, name) or !nameListed(self.inlined, name)) return null;
        return sidecar_mod.findStruct(self.sidecar.types, name);
    }

    fn msgArmTypeLiteral(self: *FacadeEmitter, arm: sidecar_mod.MsgArm) Error![]const u8 {
        const escaped = try tsString(self.arena, arm.name);
        switch (arm.payload) {
            .void => return std.fmt.allocPrint(self.arena, "{{ readonly kind: \"{s}\" }}", .{escaped}),
            .bytes => return std.fmt.allocPrint(self.arena, "{{ readonly kind: \"{s}\"; readonly value: Uint8Array }}", .{escaped}),
            .number => return std.fmt.allocPrint(self.arena, "{{ readonly kind: \"{s}\"; readonly value: number }}", .{escaped}),
            .number_bytes => |desc| return std.fmt.allocPrint(self.arena, "{{ readonly kind: \"{s}\"; readonly {s}: number; readonly {s}: Uint8Array }}", .{ escaped, try tsProp(self.arena, desc.number_field), try tsProp(self.arena, desc.bytes_field) }),
            .record => |name| {
                if (nameListed(self.inlined, name) and emit_mod.isSynthesizedRef(self.sidecar.msg.name, arm.name, name)) {
                    // The transpiled contract flattened these fields
                    // beside `kind`, preserving their names — restate
                    // them the same way.
                    const record = sidecar_mod.findStruct(self.sidecar.types, name).?;
                    var text: std.ArrayListUnmanaged(u8) = .empty;
                    try text.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "{{ readonly kind: \"{s}\"", .{escaped}));
                    for (record.fields) |field| {
                        try text.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "; readonly {s}: {s}", .{ try tsProp(self.arena, field.name), try self.spellRef(field.type, name, field.name) }));
                    }
                    try text.appendSlice(self.arena, " }");
                    return text.items;
                }
                return std.fmt.allocPrint(self.arena, "{{ readonly kind: \"{s}\"; readonly value: {s} }}", .{ escaped, name });
            },
            .union_ref, .enum_ref => |name| return std.fmt.allocPrint(self.arena, "{{ readonly kind: \"{s}\"; readonly value: {s} }}", .{ escaped, name }),
            .scalar => |ref| return std.fmt.allocPrint(self.arena, "{{ readonly kind: \"{s}\"; readonly value: {s} }}", .{ escaped, try self.spellRef(ref, "", "") }),
        }
    }

    /// Whether the slot at `slot` carries a u64 attestation: the
    /// unsigned class picks the unsigned encoder, so a negative value
    /// refuses instead of silently encoding bytes the mirror would read
    /// as a huge unsigned value. Slice elements pass null — the
    /// format-1 grammar cannot attest them.
    fn attestedU64(self: *FacadeEmitter, slot: ?[]const u8) bool {
        const path = slot orelse return false;
        for (self.sidecar.integer_slots) |entry| {
            if (entry.class == .u64 and std.mem.eql(u8, entry.slot, path)) return true;
        }
        return false;
    }

    fn anyU64(self: *FacadeEmitter) bool {
        for (self.sidecar.integer_slots) |entry| {
            if (entry.class == .u64) return true;
        }
        return false;
    }

    /// A slot path in the sidecar's grammar: `<Container>.<member>`.
    fn slotOf(self: *FacadeEmitter, container: []const u8, member: []const u8) Error![]const u8 {
        return std.fmt.allocPrint(self.arena, "{s}.{s}", .{ container, member });
    }

    /// The one TypeRef-to-TypeScript-spelling authority (the facade twin
    /// of the Zig mirror's spellRef).
    fn spellRef(self: *FacadeEmitter, ref: TypeRef, container: []const u8, member: []const u8) Error![]const u8 {
        return switch (ref) {
            .bool => "boolean",
            .f64, .i64 => "number",
            .bytes => "Uint8Array",
            .void => "void",
            .optional => |inner| try std.fmt.allocPrint(self.arena, "{s} | null", .{try self.spellRef(inner.*, container, member)}),
            .slice => |elem| blk: {
                // Sequences spell plain `T[]`: the declaration site's own
                // `readonly` modifier already pins immutability, and the
                // plain spelling is the one the projection's closed type
                // vocabulary carries end to end (the readonly-array type
                // operator has no contract projection).
                //
                // Composite element spellings parenthesize: `number |
                // null[]` would type the null as the array.
                const spelled = try self.spellRef(elem.*, container, member);
                if (std.mem.indexOfAny(u8, spelled, " |") != null) {
                    break :blk try std.fmt.allocPrint(self.arena, "({s})[]", .{spelled});
                }
                break :blk try std.fmt.allocPrint(self.arena, "{s}[]", .{spelled});
            },
            // Reference storage is a layout fact of the host mirror;
            // TypeScript sees the record value either way.
            .node, .value => |name| self.arena.dupe(u8, self.spellName(name)),
            .enum_ref, .union_ref => |name| self.arena.dupe(u8, self.spellName(name)),
        };
    }

    fn unboundDecl(self: *FacadeEmitter) Error!void {
        // Only names this module DECLARES may ride the list: message
        // arms and model fields. An unbound HELPER stays in the sidecar
        // fact (helpers are mode-forwarded and the facade declares
        // none), so listing it here would name nothing the checker can
        // resolve.
        const model = sidecar_mod.findStruct(self.sidecar.types, self.sidecar.model).?;
        var field_unbound: std.ArrayListUnmanaged([]const u8) = .empty;
        for (self.sidecar.model_unbound) |name| {
            for (model.fields) |field| {
                if (std.mem.eql(u8, field.name, name)) {
                    try field_unbound.append(self.arena, name);
                    break;
                }
            }
        }
        // The authoring surface is ONE list resolved by name, so a name
        // that is both a model field and a message arm cannot be marked
        // on one side only — the sidecar's split lists carry more than
        // the projection can say. Refuse the divergent case instead of
        // silently marking the wrong declaration.
        for (self.sidecar.msg.unbound) |name| {
            const also_field = for (model.fields) |field| {
                if (std.mem.eql(u8, field.name, name)) break true;
            } else false;
            if (also_field and !nameListed(self.sidecar.model_unbound, name)) {
                self.diags.flag("msg.unbound", "\"{s}\" is an unbound message arm AND a bound model field — the projection's single unbound list resolves by name and would mark both; rename one side in the core source", .{name});
            }
        }
        for (field_unbound.items) |name| {
            const also_arm = sidecar_mod.findArm(self.sidecar.msg, name) != null;
            if (also_arm and !nameListed(self.sidecar.msg.unbound, name)) {
                self.diags.flag("model_unbound", "\"{s}\" is an unbound model field AND a bound message arm — the projection's single unbound list resolves by name and would mark both; rename one side in the core source", .{name});
            }
        }
        if (self.diags.hasErrors()) return;
        if (field_unbound.items.len == 0 and self.sidecar.msg.unbound.len == 0) return;
        try self.raw(
            \\
            \\// The unbound-list declarations, carried by the generator from the
            \\// author's own markings in the core module: message arms only the
            \\// host fires and model fields only update logic reads. Two
            \\// consumers, two spellings of one fact: the checker tier reads the
            \\// single name-resolved viewUnbound list; a contract emitter reads
            \\// the split modelUnbound/msgUnbound pair. (The authoring
            \\// convention's exact wording is provisional pending the authoring
            \\// spec; the mechanics — generator-carried — are settled.)
            \\export const viewUnbound = [
            \\
        );
        for (self.sidecar.msg.unbound) |name| {
            try self.print("  \"{s}\",\n", .{try tsString(self.arena, name)});
        }
        for (field_unbound.items) |name| {
            // A name unbound on both sides rides once.
            if (nameListed(self.sidecar.msg.unbound, name)) continue;
            try self.print("  \"{s}\",\n", .{try tsString(self.arena, name)});
        }
        try self.raw("] as const;\n");
        if (field_unbound.items.len > 0) {
            // Field names only: unbound HELPERS stay a sidecar fact here
            // too (the facade declares no helper functions to resolve
            // them against).
            try self.raw("\nexport const modelUnbound = [\n");
            for (field_unbound.items) |name| {
                try self.print("  \"{s}\",\n", .{try tsString(self.arena, name)});
            }
            try self.raw("] as const;\n");
        }
        if (self.sidecar.msg.unbound.len > 0) {
            try self.raw("\nexport const msgUnbound = [\n");
            for (self.sidecar.msg.unbound) |name| {
                try self.print("  \"{s}\",\n", .{try tsString(self.arena, name)});
            }
            try self.raw("] as const;\n");
        }
    }

    /// The host-constructed channel arms and the launch-time environment
    /// channel: exported-const declarations a contract consumer reads,
    /// restating the sidecar's channels section.
    fn hostChannelDecls(self: *FacadeEmitter) Error!void {
        if (self.sidecar.channels.appearance_msg) |arm_name| {
            try self.print("\n/// The arm the host fills with the structural appearance record.\nexport const appearanceMsg = \"{s}\";\n", .{try tsString(self.arena, arm_name)});
        }
        if (self.sidecar.channels.chrome_msg) |arm_name| {
            try self.print("\n/// The arm the host fills with the structural window-chrome record.\nexport const chromeMsg = \"{s}\";\n", .{try tsString(self.arena, arm_name)});
        }
        if (self.sidecar.channels.env_msgs.len > 0) {
            try self.raw("\n/// The launch-time environment channel: each variable present at\n/// launch dispatches one journaled Msg on its bytes arm.\nexport const envMsgs = [\n");
            for (self.sidecar.channels.env_msgs) |entry| {
                try self.print("  {{ env: \"{s}\", msg: \"{s}\" }},\n", .{ try tsString(self.arena, entry.env), try tsString(self.arena, entry.msg) });
            }
            try self.raw("] as const;\n");
        }
    }

    fn entryPoints(self: *FacadeEmitter) Error!void {
        // The zero model: the deterministic value every entry-shape
        // consumer can boot against. The compiled core's real init and
        // update stay with the author's module; the compile mode wires
        // them in (FACADE-GAPS records the subset rules that keep the
        // forwarders out of this module today). The stubs still carry
        // the CONTRACT's declared shapes — cmd-returning entries return
        // the [state, effect] tuple and a subscribing contract declares
        // the subscriptions function — so every shape flag a consumer
        // derives from these declarations restates the sidecar's.
        var zero = std.ArrayListUnmanaged(u8).empty;
        try self.zeroValue(&zero, .{ .value = self.sidecar.model }, 1, null);
        try self.print(
            \\
            \\function nscfZeroModel(): Model {{
            \\  return {s};
            \\}}
            \\
        , .{zero.items});
        if (self.sidecar.init_returns_cmd) {
            try self.raw(
                \\
                \\export function initialModel(): [Model, Cmd<Msg>] {
                \\  return [nscfZeroModel(), Cmd.none];
                \\}
                \\
            );
        } else {
            try self.raw(
                \\
                \\export function initialModel(): Model {
                \\  return nscfZeroModel();
                \\}
                \\
            );
        }
        if (self.sidecar.update_returns_cmd) {
            try self.raw(
                \\
                \\export function update(model: Model, msg: Msg): [Model, Cmd<Msg>] {
                \\  return [model, Cmd.none];
                \\}
                \\
            );
        } else {
            try self.raw(
                \\
                \\export function update(model: Model, msg: Msg): Model {
                \\  return model;
                \\}
                \\
            );
        }
        if (self.sidecar.has_subscriptions) {
            try self.raw(
                \\
                \\export function subscriptions(model: Model): Sub<Msg> {
                \\  return Sub.none;
                \\}
                \\
            );
        }
    }

    fn constants(self: *FacadeEmitter) Error!void {
        try self.print(
            \\
            \\export const nsc_core_abi_version = {d};
            \\export const nsc_core_snapshot_format = {d};
            \\// 64-bit identities ride as 16-hex-digit strings: a number carries
            \\// at most 2^53 exactly.
            \\export const nsc_core_build_id = "{x:0>16}";
            \\
            \\// Declaration-order wire tags, one constant per arm (the subset
            \\// folds numeric constants; a generic string table is not model
            \\// vocabulary).
            \\
        , .{ self.sidecar.abi_version, self.sidecar.abi.snapshot_format, self.sidecar.build_id });
        for (self.sidecar.msg.arms, 0..) |arm, tag| {
            try self.print("export const nsc_core_tag_{s} = {d};\n", .{ arm.name, tag });
        }
    }

    fn msgConstructors(self: *FacadeEmitter) Error!void {
        const msg = "Msg";
        try self.raw("\n// One typed constructor per message arm (the dispatch-table\n// projection): the host names arms by wire tag, this side by name.\n");
        for (self.sidecar.msg.arms) |arm| {
            switch (arm.payload) {
                .void => try self.print("\nexport function nsc_core_msg_{s}(): {s} {{\n  return {{ kind: \"{s}\" }};\n}}\n", .{ arm.name, msg, try tsString(self.arena, arm.name) }),
                .bytes => try self.print("\nexport function nsc_core_msg_{s}(value: Uint8Array): {s} {{\n  return {{ kind: \"{s}\", value: value }};\n}}\n", .{ arm.name, msg, try tsString(self.arena, arm.name) }),
                .number => try self.print("\nexport function nsc_core_msg_{s}(value: number): {s} {{\n  return {{ kind: \"{s}\", value: value }};\n}}\n", .{ arm.name, msg, try tsString(self.arena, arm.name) }),
                .number_bytes => |desc| {
                    const number_param = try tsParam(self.arena, desc.number_field, 0);
                    const bytes_param = try tsParam(self.arena, desc.bytes_field, 1);
                    try self.print("\nexport function nsc_core_msg_{s}({s}: number, {s}: Uint8Array): {s} {{\n  return {{ kind: \"{s}\", {s}: {s}, {s}: {s} }};\n}}\n", .{ arm.name, number_param, bytes_param, msg, try tsString(self.arena, arm.name), try tsProp(self.arena, desc.number_field), number_param, try tsProp(self.arena, desc.bytes_field), bytes_param });
                },
                .record => |name| {
                    // Synthesized names pattern on the CONTRACT's message
                    // name; the facade's fixed `Msg` spelling is only the
                    // declared type.
                    if (nameListed(self.inlined, name) and emit_mod.isSynthesizedRef(self.sidecar.msg.name, arm.name, name)) {
                        const record = sidecar_mod.findStruct(self.sidecar.types, name).?;
                        var params: std.ArrayListUnmanaged(u8) = .empty;
                        var fields: std.ArrayListUnmanaged(u8) = .empty;
                        for (record.fields, 0..) |field, index| {
                            const param = try tsParam(self.arena, field.name, index);
                            if (index > 0) try params.appendSlice(self.arena, ", ");
                            try params.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "{s}: {s}", .{ param, try self.spellRef(field.type, name, field.name) }));
                            try fields.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, ", {s}: {s}", .{ try tsProp(self.arena, field.name), param }));
                        }
                        try self.print("\nexport function nsc_core_msg_{s}({s}): {s} {{\n  return {{ kind: \"{s}\"{s} }};\n}}\n", .{ arm.name, params.items, msg, try tsString(self.arena, arm.name), fields.items });
                    } else {
                        try self.print("\nexport function nsc_core_msg_{s}(value: {s}): {s} {{\n  return {{ kind: \"{s}\", value: value }};\n}}\n", .{ arm.name, name, msg, try tsString(self.arena, arm.name) });
                    }
                },
                .union_ref, .enum_ref => |name| try self.print("\nexport function nsc_core_msg_{s}(value: {s}): {s} {{\n  return {{ kind: \"{s}\", value: value }};\n}}\n", .{ arm.name, name, msg, try tsString(self.arena, arm.name) }),
                .scalar => |ref| try self.print("\nexport function nsc_core_msg_{s}(value: {s}): {s} {{\n  return {{ kind: \"{s}\", value: value }};\n}}\n", .{ arm.name, try self.spellRef(ref, "", ""), msg, try tsString(self.arena, arm.name) }),
            }
        }
    }

    // ------------------------------------------------ value builders

    fn sampleBuilders(self: *FacadeEmitter) Error!void {
        var sample = std.ArrayListUnmanaged(u8).empty;
        self.sample_ordinal = 0;
        try self.sampleValue(&sample, .{ .value = self.sidecar.model }, 1, null);
        try self.print(
            \\
            \\/// A deterministic, non-trivial model value (every field populated,
            \\/// varied numbers, present optionals, two-element sequences) for
            \\/// proving the snapshot encoding against the host's canonical
            \\/// encoder.
            \\export function nsc_core_sample_model(): Model {{
            \\  return {s};
            \\}}
            \\
        , .{sample.items});
    }

    fn indentText(self: *FacadeEmitter, depth: usize) Error![]const u8 {
        const text = try self.arena.alloc(u8, depth * 2);
        @memset(text, ' ');
        return text;
    }

    fn zeroValue(self: *FacadeEmitter, out: *std.ArrayListUnmanaged(u8), ref: TypeRef, depth: usize, slot: ?[]const u8) Error!void {
        _ = slot;
        switch (ref) {
            .bool => try out.appendSlice(self.arena, "false"),
            .f64, .i64 => try out.appendSlice(self.arena, "0"),
            .bytes => try out.appendSlice(self.arena, "new Uint8Array(0)"),
            .void => try out.appendSlice(self.arena, "undefined"),
            .optional => try out.appendSlice(self.arena, "null"),
            .slice => try out.appendSlice(self.arena, "[]"),
            .node, .value => |name| {
                const entry = sidecar_mod.findStruct(self.sidecar.types, name).?;
                try self.recordValue(out, entry, depth, zeroField);
            },
            .enum_ref => |name| {
                const entry = sidecar_mod.findEnum(self.sidecar.types, name).?;
                try out.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "\"{s}\"", .{try tsString(self.arena, entry.members[0])}));
            },
            .union_ref => |name| {
                const entry = sidecar_mod.findUnion(self.sidecar.types, name).?;
                try self.unionValue(out, entry, 0, depth, zeroField);
            },
        }
    }

    const FieldValueFn = *const fn (self: *FacadeEmitter, out: *std.ArrayListUnmanaged(u8), ref: TypeRef, depth: usize, slot: ?[]const u8) Error!void;

    fn zeroField(self: *FacadeEmitter, out: *std.ArrayListUnmanaged(u8), ref: TypeRef, depth: usize, slot: ?[]const u8) Error!void {
        try self.zeroValue(out, ref, depth, slot);
    }

    fn sampleField(self: *FacadeEmitter, out: *std.ArrayListUnmanaged(u8), ref: TypeRef, depth: usize, slot: ?[]const u8) Error!void {
        try self.sampleValue(out, ref, depth, slot);
    }

    fn recordValue(self: *FacadeEmitter, out: *std.ArrayListUnmanaged(u8), entry: *const sidecar_mod.Struct, depth: usize, field_value: FieldValueFn) Error!void {
        try out.appendSlice(self.arena, "{\n");
        for (entry.fields) |field| {
            try out.appendSlice(self.arena, try self.indentText(depth + 1));
            try out.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "{s}: ", .{try tsProp(self.arena, field.name)}));
            try field_value(self, out, field.type, depth + 1, try self.slotOf(entry.name, field.name));
            try out.appendSlice(self.arena, ",\n");
        }
        try out.appendSlice(self.arena, try self.indentText(depth));
        try out.appendSlice(self.arena, "}");
    }

    fn unionValue(self: *FacadeEmitter, out: *std.ArrayListUnmanaged(u8), entry: *const sidecar_mod.Union, arm_index: usize, depth: usize, field_value: FieldValueFn) Error!void {
        const arm = entry.arms[arm_index];
        if (arm.payload == .void) {
            try out.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "{{ kind: \"{s}\" }}", .{try tsString(self.arena, arm.name)}));
            return;
        }
        if (self.synthesizedRecordOf(arm.payload, entry.name, arm.name)) |record| {
            try out.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "{{ kind: \"{s}\"", .{try tsString(self.arena, arm.name)}));
            for (record.fields) |field| {
                try out.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, ", {s}: ", .{try tsProp(self.arena, field.name)}));
                try field_value(self, out, field.type, depth, try self.slotOf(record.name, field.name));
            }
            try out.appendSlice(self.arena, " }");
            return;
        }
        try out.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "{{ kind: \"{s}\", value: ", .{try tsString(self.arena, arm.name)}));
        try field_value(self, out, arm.payload, depth, try self.slotOf(entry.name, arm.name));
        try out.appendSlice(self.arena, " }");
    }

    fn sampleValue(self: *FacadeEmitter, out: *std.ArrayListUnmanaged(u8), ref: TypeRef, depth: usize, slot: ?[]const u8) Error!void {
        self.sample_ordinal += 1;
        const n: i64 = @intCast(self.sample_ordinal);
        switch (ref) {
            .bool => try out.appendSlice(self.arena, if (@rem(n, 2) == 0) "true" else "false"),
            .i64 => {
                // A u64-attested slot's sample stays non-negative (the
                // unsigned encoder refuses negatives); the magnitude
                // keeps the per-ordinal variety.
                const varied = n * 7 - 12;
                const value = if (self.attestedU64(slot) and varied < 0) -varied else varied;
                try out.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "{d}", .{value}));
            },
            .f64 => {
                // Varied signs and fractions (quarters stay exact in
                // binary, so both encoders see identical values).
                const quarters = n * 13 - 22;
                try out.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "{d}.{s}", .{ @divFloor(quarters, 4), fractionText(@mod(quarters, 4)) }));
            },
            .bytes => try out.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "asciiBytes(\"sample-{d}\")", .{n})),
            .void => try out.appendSlice(self.arena, "undefined"),
            .optional => |inner| try self.sampleValue(out, inner.*, depth, slot),
            .slice => |elem| {
                // Two elements at the outermost level exercise ordering;
                // nested levels take one so deeply nested sequence types
                // stay linear in the emitted text.
                const element_count: usize = if (self.sample_slice_depth == 0) 2 else 1;
                self.sample_slice_depth += 1;
                defer self.sample_slice_depth -= 1;
                try out.appendSlice(self.arena, "[\n");
                for (0..element_count) |_| {
                    try out.appendSlice(self.arena, try self.indentText(depth + 1));
                    try self.sampleValue(out, elem.*, depth + 1, null);
                    try out.appendSlice(self.arena, ",\n");
                }
                try out.appendSlice(self.arena, try self.indentText(depth));
                try out.appendSlice(self.arena, "]");
            },
            .node, .value => |name| {
                const entry = sidecar_mod.findStruct(self.sidecar.types, name).?;
                try self.recordValue(out, entry, depth, sampleField);
            },
            .enum_ref => |name| {
                const entry = sidecar_mod.findEnum(self.sidecar.types, name).?;
                const member = entry.members[@intCast(@mod(n, @as(i64, @intCast(entry.members.len))))];
                try out.appendSlice(self.arena, try std.fmt.allocPrint(self.arena, "\"{s}\"", .{try tsString(self.arena, member)}));
            },
            .union_ref => |name| {
                const entry = sidecar_mod.findUnion(self.sidecar.types, name).?;
                const arm_index: usize = @intCast(@mod(n, @as(i64, @intCast(entry.arms.len))));
                try self.unionValue(out, entry, arm_index, depth, sampleField);
            },
        }
    }

    // ---------------------------------------------------- encoders

    fn encoders(self: *FacadeEmitter) Error!void {
        try self.raw(
            \\
            \\// ----------------------------------------------------------------
            \\// The canonical value encoding (the host decodes with the same
            \\// rules): little-endian, headerless, record fields in declaration
            \\// order; numbers 8 bytes (i64 two's complement / f64 bit pattern),
            \\// bool one byte, bytes and sequences u32-length-prefixed, enums a
            \\// u32 declaration-order member index, options one presence byte,
            \\// union values a one-byte arm index before the payload.
            \\
            \\// Detected contract violations throw this kind-tagged teaching
            \\// value; an exception that escapes the compiled core reaches the
            \\// host's panic sink with an "Uncaught " prefix on its message.
            \\export interface NscfContractError {
            \\  readonly kind: "nscf_contract";
            \\  readonly teaching: Uint8Array;
            \\}
            \\
            \\// Every encoder returns an OWNED byte buffer and byte values are
            \\// integer-derived end to end (literals, lengths, byte reads, and
            \\// integer arithmetic over them): the number model gives each
            \\// number slot one machine class, and byte stores require the
            \\// integer one. Runs concatenate by copy (nscfCat); fractional
            \\// arithmetic (the f64 bit extraction) only ever feeds comparisons.
            \\
            \\function nscfNoParts(): Uint8Array[] {
            \\  return [];
            \\}
            \\
            \\function nscfCat(parts: readonly Uint8Array[]): Uint8Array {
            \\  let total = 0;
            \\  for (let i = 0; i < parts.length; i++) {
            \\    total = total + parts[i].length;
            \\  }
            \\  const out = new Uint8Array(total);
            \\  let at = 0;
            \\  for (let i = 0; i < parts.length; i++) {
            \\    out.set(parts[i], at);
            \\    at = at + parts[i].length;
            \\  }
            \\  return out;
            \\}
            \\
            \\function nscfByte(value: number): Uint8Array {
            \\  const out = new Uint8Array(1);
            \\  out[0] = value;
            \\  return out;
            \\}
            \\
            \\// The most-significant-first bits of a whole value below 2^width,
            \\// as bytes (byte reads are integer-valued, so bits re-enter integer
            \\// arithmetic when the bytes assemble). The scan carries two locals —
            \\// the remaining value and a halving power — and dividing a power of
            \\// two by two is exact all the way down to one. nscfI64 repeats this
            \\// scan privately instead of calling here: its input slots are host
            \\// boundary values, and keeping boundary and non-boundary callers
            \\// out of one function keeps the number-model resolution linear.
            \\function nscfBitsBelow(value: number, width: number): Uint8Array {
            \\  let p = 1;
            \\  for (let i = 1; i < width; i++) {
            \\    p = p * 2;
            \\  }
            \\  let rest = value;
            \\  // The emitted `new Uint8Array(n)` is a fresh arena allocation that
            \\  // only counts as initialized where written; sparse bit writers
            \\  // start from explicit zeros.
            \\  const bits = new Uint8Array(width);
            \\  for (let i = 0; i < width; i++) {
            \\    bits[i] = 0;
            \\  }
            \\  for (let i = 0; i < width; i++) {
            \\    if (rest >= p) {
            \\      bits[i] = 1;
            \\      rest = rest - p;
            \\    }
            \\    p = p / 2;
            \\  }
            \\  return bits;
            \\}
            \\
            \\// Little-endian bytes from most-significant-first bits (byteCount
            \\// times eight bits).
            \\function nscfBitsToBytes(bits: Uint8Array, byteCount: number): Uint8Array {
            \\  const out = new Uint8Array(byteCount);
            \\  let start = bits.length - 8;
            \\  let at = 0;
            \\  while (start >= 0) {
            \\    let v = 0;
            \\    for (let bit = 0; bit < 8; bit++) {
            \\      v = v * 2 + bits[start + bit];
            \\    }
            \\    out[at] = v;
            \\    at = at + 1;
            \\    start = start - 8;
            \\  }
            \\  return out;
            \\}
            \\
            \\// i64, two's complement LE. Values are whole and within +-(2^53 - 1)
            \\// by the number model; negatives ride the identity
            \\// bits(v) = ~bits(-1 - v). The sign paths stay separate statements
            \\// end to end.
            \\function nscfI64(value: number): Uint8Array {
            \\  if (value !== Math.floor(value) || value > 9007199254740991 || value < -9007199254740991) {
            \\    throw { kind: "nscf_contract", teaching: asciiBytes("an integer slot carries a non-integer or out-of-range value — the i64 encoding has no honest bytes for it; keep integer slots whole and within +-(2^53 - 1)") } as NscfContractError;
            \\  }
            \\  const bits = new Uint8Array(64);
            \\  for (let i = 0; i < 64; i++) {
            \\    bits[i] = 0;
            \\  }
            \\  if (value < 0) {
            \\    let rest = -1 - value;
            \\    let p = 4503599627370496;
            \\    for (let i = 0; i < 53; i++) {
            \\      if (rest >= p) {
            \\        rest = rest - p;
            \\      } else {
            \\        bits[11 + i] = 1;
            \\      }
            \\      p = p / 2;
            \\    }
            \\    for (let i = 0; i < 11; i++) {
            \\      bits[i] = 1;
            \\    }
            \\    return nscfBitsToBytes(bits, 8);
            \\  }
            \\  let rest = value;
            \\  let p = 4503599627370496;
            \\  for (let i = 0; i < 53; i++) {
            \\    if (rest >= p) {
            \\      bits[11 + i] = 1;
            \\      rest = rest - p;
            \\    }
            \\    p = p / 2;
            \\  }
            \\  return nscfBitsToBytes(bits, 8);
            \\}
            \\
            \\function nscfU32(value: number): Uint8Array {
            \\  return nscfBitsToBytes(nscfBitsBelow(value, 32), 4);
            \\}
            \\
            \\// The f64 bit pattern by exact arithmetic (multiplying and dividing
            \\// by two is exact for every finite double): sign, biased exponent,
            \\// then 52 fraction bits extracted most significant first. NaN
            \\// canonicalizes to the quiet pattern; fractional arithmetic feeds
            \\// comparisons only, never a byte slot.
            \\function nscfF64(value: number): Uint8Array {
            \\  const bits = new Uint8Array(64);
            \\  for (let i = 0; i < 64; i++) {
            \\    bits[i] = 0;
            \\  }
            \\  if (value !== value) {
            \\    for (let i = 1; i < 13; i++) {
            \\      bits[i] = 1;
            \\    }
            \\    return nscfBitsToBytes(bits, 8);
            \\  }
            \\  const negative = value < 0 || (value === 0 && 1 / value < 0);
            \\  if (negative) {
            \\    bits[0] = 1;
            \\  }
            \\  const magnitude = value < 0 ? -value : value;
            \\  if (magnitude - magnitude !== 0) {
            \\    for (let i = 1; i < 12; i++) {
            \\      bits[i] = 1;
            \\    }
            \\    return nscfBitsToBytes(bits, 8);
            \\  }
            \\  if (magnitude === 0) {
            \\    return nscfBitsToBytes(bits, 8);
            \\  }
            \\  let exponent = 0;
            \\  let mantissa = magnitude;
            \\  while (mantissa >= 2) {
            \\    mantissa = mantissa / 2;
            \\    exponent = exponent + 1;
            \\  }
            \\  while (mantissa < 1 && exponent > -1022) {
            \\    mantissa = mantissa * 2;
            \\    exponent = exponent - 1;
            \\  }
            \\  let biased = 0;
            \\  let fraction = mantissa;
            \\  if (mantissa >= 1) {
            \\    biased = exponent + 1023;
            \\    fraction = mantissa - 1;
            \\  }
            \\  const expBits = nscfBitsBelow(biased, 11);
            \\  for (let i = 0; i < 11; i++) {
            \\    const expBit = expBits[i];
            \\    bits[1 + i] = expBit;
            \\  }
            \\  for (let i = 0; i < 52; i++) {
            \\    fraction = fraction * 2;
            \\    if (fraction >= 1) {
            \\      bits[12 + i] = 1;
            \\      fraction = fraction - 1;
            \\    }
            \\  }
            \\  return nscfBitsToBytes(bits, 8);
            \\}
            \\
            \\function nscfBytes(value: Uint8Array): Uint8Array {
            \\  return nscfCat([nscfU32(value.length), value]);
            \\}
            \\
            \\export function nsc_core_probe_i64(value: number): Uint8Array {
            \\  return nscfI64(value);
            \\}
            \\
            \\export function nsc_core_probe_f64(value: number): Uint8Array {
            \\  return nscfF64(value);
            \\}
            \\
        );

        // The unsigned twin, emitted only when a slot attests the u64
        // class: 8-byte unsigned LE, refusing negatives — a negative
        // value has no honest unsigned bytes, and encoding one anyway
        // would decode host-side as a huge unsigned value.
        if (self.anyU64()) {
            try self.raw(
                \\
                \\// u64, unsigned LE — the unsigned twin for u64-attested integer
                \\// slots. Values are whole and within [0, 2^53 - 1] by the number
                \\// model; the same 53-bit scan as nscfI64's non-negative path.
                \\function nscfU64(value: number): Uint8Array {
                \\  if (value !== Math.floor(value) || value > 9007199254740991 || value < 0) {
                \\    throw { kind: "nscf_contract", teaching: asciiBytes("an unsigned integer slot carries a non-integer, negative, or out-of-range value — the u64 encoding has no honest bytes for it; keep unsigned integer slots whole and within 0..(2^53 - 1)") } as NscfContractError;
                \\  }
                \\  const bits = new Uint8Array(64);
                \\  for (let i = 0; i < 64; i++) {
                \\    bits[i] = 0;
                \\  }
                \\  let rest = value;
                \\  let p = 4503599627370496;
                \\  for (let i = 0; i < 53; i++) {
                \\    if (rest >= p) {
                \\      bits[11 + i] = 1;
                \\      rest = rest - p;
                \\    }
                \\    p = p / 2;
                \\  }
                \\  return nscfBitsToBytes(bits, 8);
                \\}
                \\
            );
        }

        for (self.sidecar.types.enums) |entry| {
            try self.print("\nfunction nscfIndex{s}(value: {s}): number {{\n", .{ entry.name, entry.name });
            for (entry.members, 0..) |member, index| {
                if (index + 1 == entry.members.len) {
                    try self.print("  return {d};\n}}\n", .{index});
                } else {
                    try self.print("  if (value === \"{s}\") {{\n    return {d};\n  }}\n", .{ try tsString(self.arena, member), index });
                }
            }
        }

        for (self.sidecar.types.structs) |*entry| {
            // Flattened single-use records encode inline at their one
            // arm site; a named encoder would need the undeclared type.
            if (nameListed(self.flattened, entry.name)) continue;
            try self.structEncoder(entry);
        }
        for (self.sidecar.types.unions) |*entry| {
            try self.unionEncoder(entry);
        }

        try self.print(
            \\
            \\/// The committed model in the canonical value encoding — the exact
            \\/// bytes the host's snapshot decoder expects. The caller states the
            \\/// snapshot generation it wants (a mismatch is a refusal, never a
            \\/// silently different encoding), and the committed value arrives as
            \\/// a parameter: module state lives in the model, and a snapshot
            \\/// entry is not a view helper, so it must not join the model's
            \\/// binding surface.
            \\export function nsc_core_model_snapshot(snapshotFormat: number, model: Model): Uint8Array {{
            \\  if (snapshotFormat !== nsc_core_snapshot_format) {{
            \\    throw {{ kind: "nscf_contract", teaching: asciiBytes("this facade encodes snapshot format {d}; re-generate the caller or the facade so both speak one generation") }} as NscfContractError;
            \\  }}
            \\  return nscfEncode{s}(model);
            \\}}
            \\
        , .{ self.sidecar.abi.snapshot_format, self.sidecar.model });
    }

    // ------------------------------------------------ channel entries

    /// The channel bytes envelope: a channel entry's whole result rides
    /// one bytes return — [produced u8][tag u8][payload…] — so the
    /// multi-value result (produced?, which arm, payload bytes) needs no
    /// marshalling shape of its own. Byte 0 is 0 (nothing produced; the
    /// envelope is exactly two bytes) or 1; byte 1 is the produced arm's
    /// declaration-order wire tag (meaningless when nothing was
    /// produced; the packer emits 0); the payload is the arm's
    /// canonical value encoding — the envelope's tail is byte-identical
    /// to the canonical union encoding of the produced message.
    ///
    /// Two surfaces ride the envelope here. `nsc_core_pack_msg` is the
    /// packer: a produced message or null in, envelope bytes out. The
    /// `nsc_core_<channel>_msg` exports are the WIRE-shaped channel
    /// entries whose parameters mirror the compiled core's C
    /// declarations (bytes ride buffer parameters, boolean modifiers
    /// u8 0-or-1, the pinch phase its declaration-order member index):
    /// each builds the channel's event record, runs the channel
    /// function, and hands the produced message to the packer. The
    /// channel functions are declared as null gates beside them, the
    /// way `update` above returns its model unchanged — the compile
    /// mode that owns the behavioral entry points wires the author's
    /// code in.
    fn channelEntries(self: *FacadeEmitter) Error!void {
        const chan = self.sidecar.channels;
        if (!(chan.command_msg or chan.frame_msg or chan.key_msg or chan.pinch_msg)) return;

        try self.raw(
            \\
            \\// ----------------------------------------------------------------
            \\// The channel bytes envelope: a channel entry's whole result rides
            \\// one bytes return — [produced u8][tag u8][payload...]. Byte 0 is 0
            \\// (nothing produced; the envelope is exactly two bytes) or 1; byte 1
            \\// is the produced arm's declaration-order wire tag (0 when nothing
            \\// was produced); the payload is the arm's canonical value encoding.
            \\
            \\function nscfMsgEnvelope(value: Msg): Uint8Array {
            \\
        );
        for (self.sidecar.msg.arms, 0..) |arm, tag| {
            try self.print("  if (value.kind === \"{s}\") {{\n    const parts: Uint8Array[] = [nscfByte(1), nscfByte({d})];\n", .{ try tsString(self.arena, arm.name), tag });
            try self.msgPayloadEncodeStatements(arm);
            try self.raw("    return nscfCat(parts);\n  }\n");
        }
        try self.raw("  throw { kind: \"nscf_contract\", teaching: asciiBytes(\"a channel produced a message outside the declared union — the value and the contract disagree\") } as NscfContractError;\n}\n");

        try self.raw(
            \\
            \\/// The envelope packer: a produced message or null in, envelope
            \\/// bytes out. The wire-shaped channel entries below hand their
            \\/// channel function's result here; a host that already holds a
            \\/// mirror message value packs through this export directly.
            \\export function nsc_core_pack_msg(msg: Msg | null): Uint8Array {
            \\  const nscfMsg = msg;
            \\  if (nscfMsg === null) {
            \\    const parts: Uint8Array[] = [nscfByte(0), nscfByte(0)];
            \\    return nscfCat(parts);
            \\  } else {
            \\    return nscfMsgEnvelope(nscfMsg);
            \\  }
            \\}
            \\
        );

        try self.raw(
            \\
            \\// The wire-shaped channel entries, one per wired channel. Their
            \\// parameters mirror the compiled core's C declarations — bytes ride
            \\// buffer parameters, the boolean modifiers u8 0-or-1, the pinch
            \\// phase its declaration-order member index — and the whole result
            \\// returns as the bytes envelope. Each entry builds its channel's
            \\// event record, runs the channel function, and hands the produced
            \\// message to the packer. The channel functions beside them are
            \\// null gates, exactly as update above returns its model unchanged:
            \\// the compile mode that owns the behavioral entry points wires the
            \\// author's code in.
            \\
        );
        if (chan.key_msg) {
            // A modifier byte past 1 is host/core skew, the wire-tag
            // teaching's sibling — never silently truthy.
            try self.raw(
                \\
                \\function nscfWireBool(value: number): boolean {
                \\  if (value === 0) {
                \\    return false;
                \\  }
                \\  if (value === 1) {
                \\    return true;
                \\  }
                \\  throw { kind: "nscf_contract", teaching: asciiBytes("a channel entry's boolean parameter carries a byte past 1 — the host and this core disagree about the contract") } as NscfContractError;
                \\}
                \\
            );
        }
        if (chan.command_msg) {
            try self.raw(
                \\
                \\function commandMsg(name: Uint8Array): Msg | null {
                \\  return null;
                \\}
                \\
                \\export function nsc_core_command_msg(name: Uint8Array): Uint8Array {
                \\  return nsc_core_pack_msg(commandMsg(name));
                \\}
                \\
            );
        }
        if (chan.frame_msg) {
            try self.raw(
                \\
                \\/// The presented-frame channel's record: canvas points plus the
                \\/// frame clock in fractional milliseconds.
                \\export interface FrameEvent {
                \\  readonly width: number;
                \\  readonly height: number;
                \\  readonly timestampMs: number;
                \\  readonly intervalMs: number;
                \\}
                \\
                \\function frameMsg(model: Model, frame: FrameEvent): Msg | null {
                \\  return null;
                \\}
                \\
                \\export function nsc_core_frame_msg(width: number, height: number, timestampMs: number, intervalMs: number): Uint8Array {
                \\  // The committed model is compile-mode state; until that wiring
                \\  // lands, the gate receives the deterministic zero model (and
                \\  // produces nothing regardless).
                \\  return nsc_core_pack_msg(frameMsg(nscfZeroModel(), { width: width, height: height, timestampMs: timestampMs, intervalMs: intervalMs }));
                \\}
                \\
            );
        }
        if (chan.key_msg) {
            try self.raw(
                \\
                \\/// The key-fallback channel's record: the lowercased key name
                \\/// plus the four modifier booleans.
                \\export interface KeyEvent {
                \\  readonly key: Uint8Array;
                \\  readonly shift: boolean;
                \\  readonly control: boolean;
                \\  readonly alt: boolean;
                \\  readonly super: boolean;
                \\}
                \\
                \\function keyMsg(key: KeyEvent): Msg | null {
                \\  return null;
                \\}
                \\
                \\export function nsc_core_key_msg(key: Uint8Array, shift: number, control: number, alt: number, superMod: number): Uint8Array {
                \\  return nsc_core_pack_msg(keyMsg({ key: key, shift: nscfWireBool(shift), control: nscfWireBool(control), alt: nscfWireBool(alt), super: nscfWireBool(superMod) }));
                \\}
                \\
            );
        }
        if (chan.pinch_msg) {
            try self.raw(
                \\
                \\export type PinchPhase = "begin" | "change" | "end";
                \\
                \\/// The pinch channel's record: window/view source identity, the
                \\/// multiplicative magnification delta, and the view-local anchor.
                \\export interface PinchEvent {
                \\  readonly windowId: number;
                \\  readonly label: Uint8Array;
                \\  readonly phase: PinchPhase;
                \\  readonly scale: number;
                \\  readonly x: number;
                \\  readonly y: number;
                \\}
                \\
                \\function nscfPinchPhase(phase: number): PinchPhase {
                \\  if (phase === 0) {
                \\    return "begin";
                \\  }
                \\  if (phase === 1) {
                \\    return "change";
                \\  }
                \\  if (phase === 2) {
                \\    return "end";
                \\  }
                \\  throw { kind: "nscf_contract", teaching: asciiBytes("a pinch phase index past the declared members reached this core — the host and this core disagree about the contract") } as NscfContractError;
                \\}
                \\
                \\function pinchMsg(pinch: PinchEvent): Msg | null {
                \\  return null;
                \\}
                \\
                \\export function nsc_core_pinch_msg(windowId: number, label: Uint8Array, phase: number, scale: number, x: number, y: number): Uint8Array {
                \\  return nsc_core_pack_msg(pinchMsg({ windowId: windowId, label: label, phase: nscfPinchPhase(phase), scale: scale, x: x, y: y }));
                \\}
                \\
            );
        }
    }

    /// Statements appending one message arm's canonical payload bytes to
    /// `parts`, off the narrowed arm value — the payload-descriptor twin
    /// of the union encoder's per-arm body. The bytes must decode
    /// against the arm's MIRROR payload type, so field order and number
    /// classes follow the sidecar exactly.
    fn msgPayloadEncodeStatements(self: *FacadeEmitter, arm: sidecar_mod.MsgArm) Error!void {
        switch (arm.payload) {
            .void => {},
            .bytes => try self.fieldEncodeStatements(.bytes, "value.value", 2, 0, null),
            .number => |class| try self.fieldEncodeStatements(numberRef(class), "value.value", 2, 0, try self.slotOf(self.sidecar.msg.name, arm.name)),
            .number_bytes => |desc| {
                // The mirror declares the number field first (the
                // emitted convention of every producer of this shape —
                // SCHEMA-GAPS.md), so the number's bytes lead.
                try self.fieldEncodeStatements(numberRef(desc.number_class), try tsAccess(self.arena, "value", desc.number_field), 2, 0, try std.fmt.allocPrint(self.arena, "{s}.{s}.{s}", .{ self.sidecar.msg.name, arm.name, desc.number_field }));
                try self.fieldEncodeStatements(.bytes, try tsAccess(self.arena, "value", desc.bytes_field), 2, 8, null);
            },
            .record => |name| {
                if (self.synthesizedRecordOf(recordPayloadRef(arm.payload), self.sidecar.msg.name, arm.name)) |record| {
                    // Flattened beside `kind`: encode the record's
                    // fields off the narrowed arm in declaration order.
                    for (record.fields, 0..) |field, field_index| {
                        try self.fieldEncodeStatements(field.type, try tsAccess(self.arena, "value", field.name), 2, field_index * 8, try self.slotOf(record.name, field.name));
                    }
                } else {
                    try self.fieldEncodeStatements(.{ .value = name }, "value.value", 2, 0, null);
                }
            },
            .union_ref => |name| try self.fieldEncodeStatements(.{ .union_ref = name }, "value.value", 2, 0, null),
            .enum_ref => |name| try self.fieldEncodeStatements(.{ .enum_ref = name }, "value.value", 2, 0, null),
            .scalar => |ref| try self.fieldEncodeStatements(ref, "value.value", 2, 0, try self.slotOf(self.sidecar.msg.name, arm.name)),
        }
    }

    fn encoderNameFor(self: *FacadeEmitter, name: []const u8) Error![]const u8 {
        return std.fmt.allocPrint(self.arena, "nscfEncode{s}", .{name});
    }

    fn structEncoder(self: *FacadeEmitter, entry: *const sidecar_mod.Struct) Error!void {
        try self.print("\nfunction {s}(value: {s}): Uint8Array {{\n  const parts: Uint8Array[] = [...nscfNoParts()];\n", .{ try self.encoderNameFor(entry.name), self.spellName(entry.name) });
        for (entry.fields, 0..) |field, index| {
            // Temp names seed per field: every statement shares one
            // function scope, and optional/slice nesting takes the +1
            // steps within the field's own range.
            try self.fieldEncodeStatements(field.type, try tsAccess(self.arena, "value", field.name), 1, index * 8, try self.slotOf(entry.name, field.name));
        }
        try self.raw("  return nscfCat(parts);\n}\n");
    }

    fn unionEncoder(self: *FacadeEmitter, entry: *const sidecar_mod.Union) Error!void {
        try self.print("\nfunction {s}(value: {s}): Uint8Array {{\n", .{ try self.encoderNameFor(entry.name), self.spellName(entry.name) });
        for (entry.arms, 0..) |arm, index| {
            try self.print("  if (value.kind === \"{s}\") {{\n    const parts: Uint8Array[] = [nscfByte({d})];\n", .{ try tsString(self.arena, arm.name), index });
            if (self.synthesizedRecordOf(arm.payload, entry.name, arm.name)) |record| {
                // Flattened beside `kind`: encode the record's fields
                // off the narrowed arm in declaration order (the record
                // is tabled, so its fields carry its own slot paths).
                for (record.fields, 0..) |field, field_index| {
                    try self.fieldEncodeStatements(field.type, try tsAccess(self.arena, "value", field.name), 2, field_index * 8, try self.slotOf(record.name, field.name));
                }
            } else if (arm.payload != .void) {
                try self.fieldEncodeStatements(arm.payload, "value.value", 2, 0, try self.slotOf(entry.name, arm.name));
            }
            try self.raw("    return nscfCat(parts);\n  }\n");
        }
        try self.print("  throw {{ kind: \"nscf_contract\", teaching: asciiBytes(\"{s} carries an arm outside its declared union — the value and the contract disagree\") }} as NscfContractError;\n}}\n", .{try tsString(self.arena, entry.name)});
    }

    /// Statements appending `expr`'s canonical encoding to `parts`.
    /// `slot` is the site's slot path (null where no path form exists),
    /// consulted for the attested integer class.
    fn fieldEncodeStatements(self: *FacadeEmitter, ref: TypeRef, expr: []const u8, depth: usize, temp_seed: usize, slot: ?[]const u8) Error!void {
        const pad = try self.indentText(depth);
        switch (ref) {
            .bool => try self.print("{s}parts[parts.length] = nscfByte({s} ? 1 : 0);\n", .{ pad, expr }),
            .i64 => try self.print("{s}parts[parts.length] = {s}({s});\n", .{ pad, if (self.attestedU64(slot)) "nscfU64" else "nscfI64", expr }),
            .f64 => try self.print("{s}parts[parts.length] = nscfF64({s});\n", .{ pad, expr }),
            .bytes => try self.print("{s}parts[parts.length] = nscfBytes({s});\n", .{ pad, expr }),
            .void => {},
            .optional => |inner| {
                const temp = try std.fmt.allocPrint(self.arena, "nscfOpt{d}", .{temp_seed});
                try self.print("{s}const {s} = {s};\n{s}if ({s} === null) {{\n{s}  parts[parts.length] = nscfByte(0);\n{s}}} else {{\n{s}  parts[parts.length] = nscfByte(1);\n", .{ pad, temp, expr, pad, temp, pad, pad, pad });
                try self.fieldEncodeStatements(inner.*, temp, depth + 1, temp_seed + 1, slot);
                try self.print("{s}}}\n", .{pad});
            },
            .slice => |elem| {
                const index = try std.fmt.allocPrint(self.arena, "nscfIdx{d}", .{temp_seed});
                try self.print("{s}parts[parts.length] = nscfU32({s}.length);\n{s}for (let {s} = 0; {s} < {s}.length; {s}++) {{\n", .{ pad, expr, pad, index, index, expr, index });
                try self.fieldEncodeStatements(elem.*, try std.fmt.allocPrint(self.arena, "{s}[{s}]", .{ expr, index }), depth + 1, temp_seed + 1, null);
                try self.print("{s}}}\n", .{pad});
            },
            .node, .value => |name| try self.print("{s}parts[parts.length] = {s}({s});\n", .{ pad, try self.encoderNameFor(name), expr }),
            .enum_ref => |name| try self.print("{s}parts[parts.length] = nscfU32(nscfIndex{s}({s}));\n", .{ pad, name, expr }),
            .union_ref => |name| try self.print("{s}parts[parts.length] = {s}({s});\n", .{ pad, try self.encoderNameFor(name), expr }),
        }
    }
};

/// Collect the record names `ref` reaches through NODE references,
/// walking the optional/slice wrappers (a node behind an optional or a
/// sequence is node storage all the same).
fn noteNodeRefs(names: *std.ArrayListUnmanaged([]const u8), arena: std.mem.Allocator, ref: TypeRef) error{OutOfMemory}!void {
    switch (ref) {
        .node => |name| {
            if (!nameListed(names.items, name)) try names.append(arena, name);
        },
        .optional => |inner| try noteNodeRefs(names, arena, inner.*),
        .slice => |elem| try noteNodeRefs(names, arena, elem.*),
        else => {},
    }
}

/// The VALUE-reference twin of noteNodeRefs.
fn noteValueRefs(names: *std.ArrayListUnmanaged([]const u8), arena: std.mem.Allocator, ref: TypeRef) error{OutOfMemory}!void {
    switch (ref) {
        .value => |name| {
            if (!nameListed(names.items, name)) try names.append(arena, name);
        },
        .optional => |inner| try noteValueRefs(names, arena, inner.*),
        .slice => |elem| try noteValueRefs(names, arena, elem.*),
        else => {},
    }
}

/// A msg record payload as the TypeRef shape synthesizedRecordOf reads.
fn recordPayloadRef(payload: sidecar_mod.Payload) TypeRef {
    return switch (payload) {
        .record => |name| .{ .value = name },
        else => unreachable,
    };
}

/// A number class as the TypeRef the field-encoder authority takes.
fn numberRef(class: sidecar_mod.NumberClass) TypeRef {
    return switch (class) {
        .f64 => .f64,
        .i64 => .i64,
    };
}

fn pathText(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(arena, fmt, args) catch "";
}

fn armPayloadRef(arm: sidecar_mod.UnionArm) ?TypeRef {
    return if (arm.payload == .void) null else arm.payload;
}

fn fractionText(quarters: i64) []const u8 {
    return switch (quarters) {
        0 => "0",
        1 => "25",
        2 => "5",
        else => "75",
    };
}

fn nameListed(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn commentText(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    const out = try arena.dupe(u8, text);
    for (out) |*char| {
        if (char.* < 0x20 or char.* == 0x7f) char.* = ' ';
    }
    // U+2028/U+2029 are line terminators to a TypeScript scanner: blank
    // their UTF-8 bytes so provenance text cannot end the comment early.
    var index: usize = 0;
    while (index + 2 < out.len) : (index += 1) {
        if (out[index] == 0xe2 and out[index + 1] == 0x80 and (out[index + 2] == 0xa8 or out[index + 2] == 0xa9)) {
            out[index] = ' ';
            out[index + 1] = ' ';
            out[index + 2] = ' ';
        }
    }
    return out;
}

/// Escape a name into a TS double-quoted string literal (arm names ride
/// string literals in the kind-tagged union). The scanner's line
/// terminators are LF, CR, LS (U+2028), and PS (U+2029) — all escaped
/// here (NEL U+0085 is ordinary text to the scanner); quotes and
/// backslashes escape byte-for-byte.
fn tsString(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        const char = text[index];
        if (char == 0xe2 and index + 2 < text.len and text[index + 1] == 0x80 and
            (text[index + 2] == 0xa8 or text[index + 2] == 0xa9))
        {
            const escape: []const u8 = if (text[index + 2] == 0xa8) "\\u2028" else "\\u2029";
            try out.appendSlice(arena, escape);
            index += 3;
            continue;
        }
        switch (char) {
            '"' => try out.appendSlice(arena, "\\\""),
            '\\' => try out.appendSlice(arena, "\\\\"),
            '\n' => try out.appendSlice(arena, "\\n"),
            '\r' => try out.appendSlice(arena, "\\r"),
            '\t' => try out.appendSlice(arena, "\\t"),
            else => try out.append(arena, char),
        }
        index += 1;
    }
    return out.items;
}

/// A property spelling: plain identifiers stay bare (reserved words
/// are legal property names); anything else quotes.
fn tsProp(arena: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]const u8 {
    if (isIdentifierFragment(name) and name.len > 0 and !(name[0] >= '0' and name[0] <= '9')) {
        return name;
    }
    return std.fmt.allocPrint(arena, "\"{s}\"", .{try tsString(arena, name)});
}

/// A property ACCESS: dot for plain spellings, brackets otherwise.
fn tsAccess(arena: std.mem.Allocator, base: []const u8, name: []const u8) error{OutOfMemory}![]const u8 {
    if (isIdentifierFragment(name) and name.len > 0 and !(name[0] >= '0' and name[0] <= '9')) {
        return std.fmt.allocPrint(arena, "{s}.{s}", .{ base, name });
    }
    return std.fmt.allocPrint(arena, "{s}[\"{s}\"]", .{ base, try tsString(arena, name) });
}

/// A parameter name derived from an authored field name: reserved words
/// and exotic spellings fall back to a positional name (parameters,
/// unlike properties, must be plain identifiers).
fn tsParam(arena: std.mem.Allocator, name: []const u8, index: usize) error{OutOfMemory}![]const u8 {
    if (isTsIdentifier(name)) return name;
    // The fallback lives in the fenced nsc name space, so it can never
    // collide with an authored sibling field's spelling.
    return std.fmt.allocPrint(arena, "nscf_arg{d}", .{index});
}

/// A property name the subset can declare bare (reserved words are
/// legal property spellings; quoting is not accepted).
fn isBareProperty(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] >= '0' and name[0] <= '9') return false;
    return isIdentifierFragment(name);
}

/// Why a name cannot survive the WHOLE proxy pipeline, or null when it
/// can. The facade is TypeScript, but the validation proxy compiles it
/// with the shipped transpiler, which emits identifiers VERBATIM into
/// the downstream module (it has no quoting machinery) — so every name
/// the facade declares must be legal in both languages: the shared
/// identifier charset (letters, digits, underscore; `$` exists only on
/// the TypeScript side), a non-digit start, not the discard spelling,
/// and no keyword or primitive-type name of either language.
const NameRole = enum {
    /// A TypeScript declaration (type alias, interface): TypeScript's
    /// reserved words apply on top of the compiled module's rules.
    declaration,
    /// A member position (property, union arm, enum member):
    /// TypeScript accepts reserved words there — the corpus's own
    /// `number` field proves it — so only the compiled module's rules
    /// apply.
    member,
};

fn pipelineIdentifierIssue(name: []const u8, role: NameRole) ?[]const u8 {
    if (name.len == 0) return "is empty";
    if (std.mem.eql(u8, name, "_")) return "is the discard spelling in the compiled module";
    if (name[0] >= '0' and name[0] <= '9') return "starts with a digit";
    for (name) |char| {
        const ok = (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z') or
            (char >= '0' and char <= '9') or char == '_';
        if (!ok) return "uses characters outside the compiled module's identifier set (letters, digits, underscore)";
    }
    if (std.zig.Token.keywords.has(name)) return "is a keyword in the compiled module";
    if (std.zig.isPrimitive(name)) return "is a primitive type name in the compiled module";
    if (role == .declaration) {
        for (ts_reserved_words) |word| {
            if (std.mem.eql(u8, name, word)) return "is a reserved word in TypeScript";
        }
    }
    return null;
}

fn isIdentifierFragment(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |char| {
        const ok = (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z') or
            (char >= '0' and char <= '9') or char == '_' or char == '$';
        if (!ok) return false;
    }
    return true;
}

fn isTsIdentifier(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] >= '0' and name[0] <= '9') return false;
    for (name) |char| {
        const ok = (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z') or
            (char >= '0' and char <= '9') or char == '_' or char == '$';
        if (!ok) return false;
    }
    for (ts_reserved_words) |word| {
        if (std.mem.eql(u8, name, word)) return false;
    }
    return true;
}

// --------------------------------------------------------------- tests

const testing = std.testing;

fn facadeFromJson(arena: std.mem.Allocator, json: []const u8) ![]const u8 {
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = sidecar_mod.read(arena, json, &diags) catch |err| {
        for (diags.list.items) |item| {
            std.debug.print("  [{s}] {s}: {s}\n", .{ @tagName(item.severity), item.path, item.message });
        }
        return err;
    };
    return emitFacade(arena, parsed, &diags) catch |err| {
        for (diags.list.items) |item| {
            std.debug.print("  [{s}] {s}: {s}\n", .{ @tagName(item.severity), item.path, item.message });
        }
        return err;
    };
}

test "facade emission is deterministic and carries the projection surface" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const first = try facadeFromJson(arena, sidecar_mod.minimal_valid_json);
    const second = try facadeFromJson(arena, sidecar_mod.minimal_valid_json);
    try testing.expectEqualStrings(first, second);
    try testing.expect(std.mem.indexOf(u8, first, "export interface Model {") != null);
    try testing.expect(std.mem.indexOf(u8, first, "readonly count: number;") != null);
    try testing.expect(std.mem.indexOf(u8, first, "export type Msg =") != null);
    try testing.expect(std.mem.indexOf(u8, first, "| { readonly kind: \"label_set\"; readonly value: Uint8Array }") != null);
    try testing.expect(std.mem.indexOf(u8, first, "export const nsc_core_build_id = \"00000000b01dface\";") != null);
    try testing.expect(std.mem.indexOf(u8, first, "export function nsc_core_msg_bump(): Msg {") != null);
    try testing.expect(std.mem.indexOf(u8, first, "export function nsc_core_model_snapshot(snapshotFormat: number, model: Model): Uint8Array {") != null);
    try testing.expect(std.mem.indexOf(u8, first, "function nscfF64(value: number): Uint8Array {") != null);
    // The unbound list rides the facade (the author declares nothing).
    try testing.expect(std.mem.indexOf(u8, first, "export const viewUnbound = [\n  \"label_set\",\n] as const;") != null);
}

test "wired channels emit wire-shaped exports and the packer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"key_msg\": false", "\"key_msg\": true");
    source = try std.mem.replaceOwned(u8, arena, source, "\"helper_call\"]", "\"helper_call\", \"key_msg\"]");
    const generated = try facadeFromJson(arena, source);
    // The wired channel gets the wire-shaped export (host-event params
    // in, envelope bytes out), none for the unwired rest.
    try testing.expect(std.mem.indexOf(u8, generated, "export function nsc_core_key_msg(key: Uint8Array, shift: number, control: number, alt: number, superMod: number): Uint8Array {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "nsc_core_frame_msg") == null);
    try testing.expect(std.mem.indexOf(u8, generated, "nsc_core_command_msg") == null);
    try testing.expect(std.mem.indexOf(u8, generated, "nsc_core_pinch_msg") == null);
    // The wire entry runs the channel-function gate and hands the
    // result to the packer; the modifier bytes convert 0-or-1 strictly.
    try testing.expect(std.mem.indexOf(u8, generated, "return nsc_core_pack_msg(keyMsg({ key: key, shift: nscfWireBool(shift), control: nscfWireBool(control), alt: nscfWireBool(alt), super: nscfWireBool(superMod) }));") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "function keyMsg(key: KeyEvent): Msg | null {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "boolean parameter carries a byte past 1") != null);
    // The packer owns the produced-or-null surface under its own name.
    try testing.expect(std.mem.indexOf(u8, generated, "export function nsc_core_pack_msg(msg: Msg | null): Uint8Array {") != null);
    // The nothing-produced envelope is exactly [0, 0]; a produced arm
    // leads with [1, tag] and appends the arm's canonical payload.
    try testing.expect(std.mem.indexOf(u8, generated, "const parts: Uint8Array[] = [nscfByte(0), nscfByte(0)];") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "function nscfMsgEnvelope(value: Msg): Uint8Array {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "if (value.kind === \"bump\") {\n    const parts: Uint8Array[] = [nscfByte(1), nscfByte(0)];\n    return nscfCat(parts);\n  }") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "if (value.kind === \"label_set\") {\n    const parts: Uint8Array[] = [nscfByte(1), nscfByte(1)];\n    parts[parts.length] = nscfBytes(value.value);\n    return nscfCat(parts);\n  }") != null);
}

test "the command and pinch wire entries marshal their C parameter shapes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"command_msg\": false", "\"command_msg\": true");
    source = try std.mem.replaceOwned(u8, arena, source, "\"pinch_msg\": false", "\"pinch_msg\": true");
    source = try std.mem.replaceOwned(u8, arena, source, "\"helper_call\"]", "\"helper_call\", \"command_msg\", \"pinch_msg\"]");
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "export function nsc_core_command_msg(name: Uint8Array): Uint8Array {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "return nsc_core_pack_msg(commandMsg(name));") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "export function nsc_core_pinch_msg(windowId: number, label: Uint8Array, phase: number, scale: number, x: number, y: number): Uint8Array {") != null);
    // The phase index maps to the declaration-order member and refuses
    // past the declared members.
    try testing.expect(std.mem.indexOf(u8, generated, "return nsc_core_pack_msg(pinchMsg({ windowId: windowId, label: label, phase: nscfPinchPhase(phase), scale: scale, x: x, y: y }));") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "export type PinchPhase = \"begin\" | \"change\" | \"end\";") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "pinch phase index past the declared members") != null);
    // No key channel: the modifier converter stays out.
    try testing.expect(std.mem.indexOf(u8, generated, "nscfWireBool") == null);
}

test "a type taking a wired channel's facade declaration refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"key_msg\": false", "\"key_msg\": true");
    source = try std.mem.replaceOwned(u8, arena, source, "\"helper_call\"]", "\"helper_call\", \"key_msg\"]");
    source = try std.mem.replaceOwned(u8, arena, source, "\"enums\": []", "\"enums\": [{\"name\": \"KeyEvent\", \"members\": [\"a\", \"b\"]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"enum\", \"name\": \"KeyEvent\"}}",
    );
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emitFacade(arena, parsed, &diags));
    var found = false;
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, "collides with a declaration the generated facade itself must make") != null) found = true;
    }
    try testing.expect(found);
}

test "unwired channels leave the envelope surface out of the facade" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const generated = try facadeFromJson(arena, sidecar_mod.minimal_valid_json);
    try testing.expect(std.mem.indexOf(u8, generated, "nscfMsgEnvelope") == null);
    try testing.expect(std.mem.indexOf(u8, generated, "nsc_core_key_msg") == null);
    try testing.expect(std.mem.indexOf(u8, generated, "nsc_core_pack_msg") == null);
}

test "envelope payloads follow the sidecar's classes and flattened orders" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // An i64-classed number arm and a synthesized flattened record arm,
    // with the frame channel wired.
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"structs\": [", "\"structs\": [\n      {\"name\": \"Msg_loaded\", \"fields\": [{\"name\": \"status\", \"type\": {\"kind\": \"f64\"}}, {\"name\": \"ok\", \"type\": {\"kind\": \"bool\"}}]},");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"number\", \"class\": \"i64\"}}, {\"name\": \"loaded\", \"payload\": {\"kind\": \"record\", \"name\": \"Msg_loaded\"}}",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "\"frame_msg\": false", "\"frame_msg\": true");
    source = try std.mem.replaceOwned(u8, arena, source, "\"helper_call\"]", "\"helper_call\", \"frame_msg\"]");
    source = try std.mem.replaceOwned(u8, arena, source, "{\"slot\": \"Model.count\", \"class\": \"i64\"}", "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"Msg.bump\", \"class\": \"i64\"}");
    const generated = try facadeFromJson(arena, source);
    // The i64 class picks the two's-complement encoder, never the f64
    // bit pattern.
    try testing.expect(std.mem.indexOf(u8, generated, "if (value.kind === \"bump\") {\n    const parts: Uint8Array[] = [nscfByte(1), nscfByte(0)];\n    parts[parts.length] = nscfI64(value.value);\n    return nscfCat(parts);\n  }") != null);
    // The flattened record encodes its fields off the narrowed arm in
    // declaration order, exactly as the arm's mirror payload decodes.
    try testing.expect(std.mem.indexOf(u8, generated, "if (value.kind === \"loaded\") {\n    const parts: Uint8Array[] = [nscfByte(1), nscfByte(1)];\n    parts[parts.length] = nscfF64(value.status);\n    parts[parts.length] = nscfByte(value.ok ? 1 : 0);\n    return nscfCat(parts);\n  }") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "export function nsc_core_frame_msg(width: number, height: number, timestampMs: number, intervalMs: number): Uint8Array {") != null);
}

test "u64-attested slots pick the unsigned encoder; the twin emits only when attested" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A u64-attested model field and message arm beside an i64-attested
    // one, with the key channel wired so the envelope path emits too.
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "{\"name\": \"count\", \"type\": {\"kind\": \"i64\"}}",
        "{\"name\": \"count\", \"type\": {\"kind\": \"i64\"}},\n        {\"name\": \"id\", \"type\": {\"kind\": \"i64\"}}",
    );
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"tick\", \"payload\": {\"kind\": \"number\", \"class\": \"i64\"}}",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "\"key_msg\": false", "\"key_msg\": true");
    source = try std.mem.replaceOwned(u8, arena, source, "\"helper_call\"]", "\"helper_call\", \"key_msg\"]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}",
        "{\"slot\": \"Model.count\", \"class\": \"i64\"}, {\"slot\": \"Model.id\", \"class\": \"u64\"}, {\"slot\": \"Msg.tick\", \"class\": \"u64\"}",
    );
    const generated = try facadeFromJson(arena, source);
    // Slot by slot: the attestation picks the encoder.
    try testing.expect(std.mem.indexOf(u8, generated, "function nscfU64(value: number): Uint8Array {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "parts[parts.length] = nscfI64(value.count);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "parts[parts.length] = nscfU64(value.id);") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "parts[parts.length] = nscfU64(value.value);") != null);
    // The unsigned encoder refuses negatives, and its sample stays
    // non-negative so the deterministic sample model encodes.
    try testing.expect(std.mem.indexOf(u8, generated, "value < 0") != null);
    // Without a u64 attestation, the twin never emits.
    const signed_only = try facadeFromJson(arena, sidecar_mod.minimal_valid_json);
    try testing.expect(std.mem.indexOf(u8, signed_only, "nscfU64") == null);
}

test "a synthesized-name node payload keeps its named declaration" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Single-use and pattern-named, but NODE-stored: flattening would
    // silently convert reference storage to value storage, so the arm
    // keeps the named payload behind a `value` member and the interface
    // declares.
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"structs\": [", "\"structs\": [\n      {\"name\": \"Edit_set\", \"fields\": [{\"name\": \"a\", \"type\": {\"kind\": \"f64\"}}, {\"name\": \"b\", \"type\": {\"kind\": \"bool\"}}]},");
    source = try std.mem.replaceOwned(u8, arena, source, "\"unions\": []", "\"unions\": [{\"name\": \"Edit\", \"arms\": [{\"name\": \"clear\", \"payload\": {\"kind\": \"void\"}}, {\"name\": \"set\", \"payload\": {\"kind\": \"node\", \"name\": \"Edit_set\"}}]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"union\", \"name\": \"Edit\"}}",
    );
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "export interface Edit_set {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "| { readonly kind: \"set\"; readonly value: Edit_set }") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "readonly kind: \"set\"; readonly a:") == null);
}

test "a value reference to the model root refuses as mixed storage" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The root is reference-stored by contract; a record field holding
    // it by value would make the compiled projection re-derive the
    // field as node storage.
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"structs\": [", "\"structs\": [\n      {\"name\": \"Wrap\", \"fields\": [{\"name\": \"inner\", \"type\": {\"kind\": \"value\", \"name\": \"Model\"}}]},");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"record\", \"name\": \"Wrap\"}}",
    );
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emitFacade(arena, parsed, &diags));
    var found = false;
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, "storage once per declaration") != null) found = true;
    }
    try testing.expect(found);
}


test "declaration forms spell the contract's record storage" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A node-stored list element and a value-stored record field: the
    // former declares as an interface, the latter as an object alias;
    // the model root stays an interface (its designation requires one).
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"structs\": [", "\"structs\": [\n      {\"name\": \"Task\", \"fields\": [{\"name\": \"id\", \"type\": {\"kind\": \"f64\"}}]},\n      {\"name\": \"Pos\", \"fields\": [{\"name\": \"x\", \"type\": {\"kind\": \"f64\"}}]},");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"items\", \"type\": {\"kind\": \"slice\", \"elem\": {\"kind\": \"node\", \"name\": \"Task\"}}}, {\"name\": \"pos\", \"type\": {\"kind\": \"value\", \"name\": \"Pos\"}}",
    );
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "export interface Task {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "export type Pos = {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "export interface Model {") != null);
}

test "composite slice elements parenthesize in the projection" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"slice\", \"elem\": {\"kind\": \"optional\", \"inner\": {\"kind\": \"f64\"}}}}",
    );
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "readonly label: (number | null)[];") != null);
}

test "renamed roots declare under the profile's designated spellings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"Model\"", "\"State\"");
    source = try std.mem.replaceOwned(u8, arena, source, "\"slot\": \"Model.count\"", "\"slot\": \"State.count\"");
    source = try std.mem.replaceOwned(u8, arena, source, "\"name\": \"Msg\"", "\"name\": \"Event\"");
    const generated = try facadeFromJson(arena, source);
    // The root commit machinery and dispatch wiring key on the exact
    // exports; the contract's own names ride as aliases.
    try testing.expect(std.mem.indexOf(u8, generated, "export interface Model {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "export type State = Model;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "export type Msg =") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "export type Event = Msg;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "export function initialModel(): Model {") != null);
}

test "entry stubs carry the contract's declared shapes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // minimal_valid_json: init bare, update cmd-returning, no
    // subscriptions.
    const generated = try facadeFromJson(arena, sidecar_mod.minimal_valid_json);
    try testing.expect(std.mem.indexOf(u8, generated, "export function initialModel(): Model {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "export function update(model: Model, msg: Msg): [Model, Cmd<Msg>] {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "return [model, Cmd.none];") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "import { Cmd, asciiBytes }") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "subscriptions") == null);

    // The inverse shapes: cmd-returning init, bare update, a
    // subscribing contract.
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"init_returns_cmd\": false", "\"init_returns_cmd\": true");
    source = try std.mem.replaceOwned(u8, arena, source, "\"update_returns_cmd\": true", "\"update_returns_cmd\": false");
    source = try std.mem.replaceOwned(u8, arena, source, "\"has_subscriptions\": false", "\"has_subscriptions\": true");
    const inverse = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, inverse, "export function initialModel(): [Model, Cmd<Msg>] {") != null);
    try testing.expect(std.mem.indexOf(u8, inverse, "return [nscfZeroModel(), Cmd.none];") != null);
    try testing.expect(std.mem.indexOf(u8, inverse, "export function update(model: Model, msg: Msg): Model {") != null);
    try testing.expect(std.mem.indexOf(u8, inverse, "export function subscriptions(model: Model): Sub<Msg> {") != null);
    try testing.expect(std.mem.indexOf(u8, inverse, "import { Cmd, Sub, asciiBytes }") != null);
}

test "split unbound consts and host-channel consts restate the sidecar" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"model_unbound\": []", "\"model_unbound\": [\"count\"]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "\"env_msgs\": []",
        "\"env_msgs\": [{\"env\": \"APP_LABEL\", \"msg\": \"label_set\"}]",
    );
    const generated = try facadeFromJson(arena, source);
    // One fact, two spellings: the checker tier's single list plus the
    // contract emitter's split pair.
    try testing.expect(std.mem.indexOf(u8, generated, "export const viewUnbound = [\n  \"label_set\",\n  \"count\",\n] as const;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "export const modelUnbound = [\n  \"count\",\n] as const;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "export const msgUnbound = [\n  \"label_set\",\n] as const;") != null);
    // The environment channel's exported-const convention.
    try testing.expect(std.mem.indexOf(u8, generated, "export const envMsgs = [\n  { env: \"APP_LABEL\", msg: \"label_set\" },\n] as const;") != null);
    // No host-constructed arms declared: the consts stay out.
    try testing.expect(std.mem.indexOf(u8, generated, "appearanceMsg") == null);
    try testing.expect(std.mem.indexOf(u8, generated, "chromeMsg") == null);
}

test "a record referenced by node and value at once refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"structs\": [", "\"structs\": [\n      {\"name\": \"Item\", \"fields\": [{\"name\": \"x\", \"type\": {\"kind\": \"f64\"}}]},");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"live\", \"type\": {\"kind\": \"node\", \"name\": \"Item\"}}, {\"name\": \"cached\", \"type\": {\"kind\": \"value\", \"name\": \"Item\"}}",
    );
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emitFacade(arena, parsed, &diags));
    var found = false;
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, "storage once per declaration") != null) found = true;
    }
    try testing.expect(found);
}

test "a host-constructed channel arm with a shared named record refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // AppearanceEvent is used TWICE (a model field and the arm), so it
    // never flattens; the host cannot fill its fields directly on the
    // arm.
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"structs\": [", "\"structs\": [\n      {\"name\": \"AppearanceEvent\", \"fields\": [{\"name\": \"colorScheme\", \"type\": {\"kind\": \"enum\", \"name\": \"ColorScheme\"}}, {\"name\": \"reduceMotion\", \"type\": {\"kind\": \"bool\"}}, {\"name\": \"highContrast\", \"type\": {\"kind\": \"bool\"}}]},");
    source = try std.mem.replaceOwned(u8, arena, source, "\"enums\": []", "\"enums\": [{\"name\": \"ColorScheme\", \"members\": [\"light\", \"dark\"]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"last\", \"type\": {\"kind\": \"value\", \"name\": \"AppearanceEvent\"}}",
    );
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"appearance_changed\", \"payload\": {\"kind\": \"record\", \"name\": \"AppearanceEvent\"}}",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "\"appearance_msg\": null", "\"appearance_msg\": \"appearance_changed\"");
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emitFacade(arena, parsed, &diags));
    var found = false;
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, "cannot flatten into the arm") != null) found = true;
    }
    try testing.expect(found);
}

test "viewUnbound is fenced only when the const declares" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // No unbound facts at all: a contract type named viewUnbound
    // projects (nothing collides).
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"unbound\": [\"label_set\"]", "\"unbound\": []");
    source = try std.mem.replaceOwned(u8, arena, source, "\"enums\": []", "\"enums\": [{\"name\": \"viewUnbound\", \"members\": [\"a\", \"b\"]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"enum\", \"name\": \"viewUnbound\"}}",
    );
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "export type viewUnbound =") != null);
    // With an unbound arm, the const declares and the name refuses.
    const colliding = try std.mem.replaceOwned(u8, arena, source, "\"unbound\": []", "\"unbound\": [\"label_set\"]");
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, colliding, &diags);
    try testing.expectError(error.Refused, emitFacade(arena, parsed, &diags));
}

test "the split unbound names are fenced only when their consts declare" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A contract type named modelUnbound projects while no unbound
    // model fields exist: nothing collides, nothing refuses.
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"enums\": []", "\"enums\": [{\"name\": \"modelUnbound\", \"members\": [\"a\", \"b\"]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"enum\", \"name\": \"modelUnbound\"}}",
    );
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "export type modelUnbound =") != null);
    // The same type refuses once an unbound model field makes the
    // facade declare the const.
    const colliding = try std.mem.replaceOwned(u8, arena, source, "\"model_unbound\": []", "\"model_unbound\": [\"count\"]");
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, colliding, &diags);
    try testing.expectError(error.Refused, emitFacade(arena, parsed, &diags));
}

test "unbound helper names stay out of the facade's viewUnbound list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "\"model_helpers\": []",
        "\"model_helpers\": [{\"name\": \"summary\", \"params\": [], \"returns\": {\"kind\": \"bytes\"}, \"arena\": false}]",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "\"model_unbound\": []", "\"model_unbound\": [\"summary\", \"count\"]");
    const generated = try facadeFromJson(arena, source);
    // The facade declares no helpers, so the checker could resolve
    // "summary" to nothing; the field entry rides, the helper's stays a
    // sidecar fact.
    try testing.expect(std.mem.indexOf(u8, generated, "\"count\",") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "\"summary\",") == null);
}

test "synthesized records inside tabled unions flatten beside kind" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The set_composition shape: an authored multi-field arm whose
    // record was tabled under the synthesized pattern.
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"structs\": [", "\"structs\": [\n      {\"name\": \"Edit_set_composition\", \"fields\": [{\"name\": \"text\", \"type\": {\"kind\": \"bytes\"}}, {\"name\": \"cursor\", \"type\": {\"kind\": \"optional\", \"inner\": {\"kind\": \"f64\"}}}]},");
    source = try std.mem.replaceOwned(u8, arena, source, "\"unions\": []", "\"unions\": [{\"name\": \"Edit\", \"arms\": [{\"name\": \"clear\", \"payload\": {\"kind\": \"void\"}}, {\"name\": \"set_composition\", \"payload\": {\"kind\": \"value\", \"name\": \"Edit_set_composition\"}}]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"union\", \"name\": \"Edit\"}}",
    );
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "| { readonly kind: \"set_composition\"; readonly text: Uint8Array; readonly cursor: number | null }") != null);
    // The union encoder reads the flattened fields off the narrowed arm.
    try testing.expect(std.mem.indexOf(u8, generated, "if (value.kind === \"set_composition\")") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "const nscfOpt8 = value.cursor;") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "value.value") == null);
}

test "renamed message roots still flatten their synthesized payload records" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A single-use Event_loaded record on a union named Event: the arm
    // type flattens it, so the constructor must build the flattened
    // shape, not a `value` member.
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"name\": \"Msg\"", "\"name\": \"Event\"");
    source = try std.mem.replaceOwned(u8, arena, source, "\"structs\": [", "\"structs\": [\n      {\"name\": \"Event_loaded\", \"fields\": [{\"name\": \"status\", \"type\": {\"kind\": \"f64\"}}, {\"name\": \"ok\", \"type\": {\"kind\": \"bool\"}}]},");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"loaded\", \"payload\": {\"kind\": \"record\", \"name\": \"Event_loaded\"}}",
    );
    const generated = try facadeFromJson(arena, source);
    try testing.expect(std.mem.indexOf(u8, generated, "| { readonly kind: \"loaded\"; readonly status: number; readonly ok: boolean }") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "export function nsc_core_msg_loaded(status: number, ok: boolean): Msg {") != null);
    try testing.expect(std.mem.indexOf(u8, generated, "return { kind: \"loaded\", status: status, ok: ok };") != null);
}

test "an unbound name split across homonymous field and arm refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Msg arm "count" is unbound; Model field "count" is bound: one
    // name-resolved list cannot say that.
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"count\", \"payload\": {\"kind\": \"void\"}}",
    );
    source = try std.mem.replaceOwned(u8, arena, source, "\"unbound\": [\"label_set\"]", "\"unbound\": [\"count\"]");
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emitFacade(arena, parsed, &diags));
    var found = false;
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, "single unbound list resolves by name") != null) found = true;
    }
    try testing.expect(found);
}

test "nested optionals refuse in the projection" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"optional\", \"inner\": {\"kind\": \"optional\", \"inner\": {\"kind\": \"f64\"}}}}",
    );
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emitFacade(arena, parsed, &diags));
    var found = false;
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, "one absence level") != null) found = true;
    }
    try testing.expect(found);
}

test "strict-mode reserved words cannot declare" {
    try testing.expect(!isTsIdentifier("implements"));
    try testing.expect(!isTsIdentifier("private"));
    try testing.expect(!isTsIdentifier("arguments"));
    try testing.expect(!isTsIdentifier("any"));
    try testing.expect(!isTsIdentifier("unknown"));
    try testing.expect(!isTsIdentifier("never"));
    try testing.expect(!isTsIdentifier("bigint"));
    try testing.expect(!isTsIdentifier("symbol"));
    try testing.expect(isTsIdentifier("implementation"));
    try testing.expect(isTsIdentifier("anywhere"));
}

test "a flattened field spelled kind refuses against the discriminator" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // number_bytes flattens its two fields beside `kind`.
    const source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"number_bytes\", \"number_field\": \"kind\", \"number_class\": \"f64\", \"bytes_field\": \"body\"}}",
    );
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emitFacade(arena, parsed, &diags));
    var found = false;
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, "beside the message discriminator") != null) found = true;
    }
    try testing.expect(found);

    // A synthesized inline record flattens too; a named payload would
    // ride a `value` member and stay unaffected.
    var record_source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"structs\": [", "\"structs\": [\n      {\"name\": \"Msg_loaded\", \"fields\": [{\"name\": \"kind\", \"type\": {\"kind\": \"f64\"}}, {\"name\": \"ok\", \"type\": {\"kind\": \"bool\"}}]},");
    record_source = try std.mem.replaceOwned(
        u8,
        arena,
        record_source,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"loaded\", \"payload\": {\"kind\": \"record\", \"name\": \"Msg_loaded\"}}",
    );
    var record_diags = sidecar_mod.Diagnostics{ .arena = arena };
    const record_parsed = try sidecar_mod.read(arena, record_source, &record_diags);
    try testing.expectError(error.Refused, emitFacade(arena, record_parsed, &record_diags));
}

test "TS line terminators escape inside emitted string literals" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The identifier fences keep author strings out of the exotic
    // range, so this escaper is defense in depth — pinned directly:
    // LS/PS are scanner line terminators, and quotes, backslashes, and
    // ASCII terminators ride their own escapes.
    try testing.expectEqualStrings("A\\u2028B", try tsString(arena, "A\xe2\x80\xa8B"));
    try testing.expectEqualStrings("C\\u2029D", try tsString(arena, "C\xe2\x80\xa9D"));
    try testing.expectEqualStrings("q\\\"x\\\\y\\nz", try tsString(arena, "q\"x\\y\nz"));
    // NEL is ordinary text to the scanner (its terminator set is
    // LF/CR/LS/PS) and passes through.
    try testing.expectEqualStrings("n\xc2\x85m", try tsString(arena, "n\xc2\x85m"));
}

test "number_bytes fields in the reserved nsc space refuse" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // An authored "nscf_arg1" beside an exotic sibling would collide
    // with the sibling's positional parameter fallback.
    var source = try std.mem.replaceOwned(
        u8,
        arena,
        sidecar_mod.minimal_valid_json,
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"void\"}}",
        "{\"name\": \"bump\", \"payload\": {\"kind\": \"number_bytes\", \"number_field\": \"nscf_arg1\", \"number_class\": \"f64\", \"bytes_field\": \"body-data\"}}",
    );
    _ = &source;
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emitFacade(arena, parsed, &diags));
    var found = false;
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, "reserved nsc name space") != null) found = true;
    }
    try testing.expect(found);
}

test "a type taking a generated facade declaration's name refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"enums\": []", "\"enums\": [{\"name\": \"NscfContractError\", \"members\": [\"a\"]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"enum\", \"name\": \"NscfContractError\"}}",
    );
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emitFacade(arena, parsed, &diags));
}

test "facade names that TypeScript cannot declare refuse with a teaching" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"name\": \"Msg\"", "\"name\": \"class\"");
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emitFacade(arena, parsed, &diags));
    var found = false;
    for (diags.list.items) |item| {
        if (item.severity == .@"error" and std.mem.indexOf(u8, item.message, "is a reserved word in TypeScript") != null) found = true;
    }
    try testing.expect(found);
}

test "a type in the facade's reserved nsc name space refuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source = try std.mem.replaceOwned(u8, arena, sidecar_mod.minimal_valid_json, "\"enums\": []", "\"enums\": [{\"name\": \"nscfHelper\", \"members\": [\"a\"]}]");
    source = try std.mem.replaceOwned(
        u8,
        arena,
        source,
        "{\"name\": \"label\", \"type\": {\"kind\": \"bytes\"}}",
        "{\"name\": \"label\", \"type\": {\"kind\": \"enum\", \"name\": \"nscfHelper\"}}",
    );
    var diags = sidecar_mod.Diagnostics{ .arena = arena };
    const parsed = try sidecar_mod.read(arena, source, &diags);
    try testing.expectError(error.Refused, emitFacade(arena, parsed, &diags));
}

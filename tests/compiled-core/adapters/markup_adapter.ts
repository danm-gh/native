// The markup fixture's compiled-core entry module — the interim
// hand-authored stand-in for compile-mode wiring: it imports the
// AUTHOR'S core (tests/ts-core/markup_fixture.ts, staged beside this
// file with its SDK imports resolved locally), owns the committed model
// in module state, and exports the profile-declared dispatch surface.
// Inbound payloads decode through the shared wire codec; the returned
// Cmd data encodes through the same codec's v3 command wire. This is
// the corpus's three-function-channel core (frame, key AND pinch), so
// the profile's conditional channel entries all stand here. The paired
// e2e battery holds every byte of this module to the transpiler lane's
// output.

import {
  initialModel,
  update,
  frameMsg as coreFrameMsg,
  keyMsg as coreKeyMsg,
  pinchMsg as corePinchMsg,
  type Model,
  type Msg,
  type Filter,
} from "./markup_fixture.ts";
import type { Cmd } from "./sdk/core.ts";
import type { ColorScheme, PinchPhase } from "./sdk/events.ts";
import {
  assertConsumed,
  cmdBytes,
  decodeTextInputEvent,
  finish,
  newSink,
  readBool,
  readBytesBody,
  readF64,
  readU32,
  trap,
  wBool,
  wBytes,
  wF64,
  wU32,
  type Sink,
} from "./wire.ts";

// The contract type designations the sidecar section names — the
// author's declarations re-exported verbatim, plus every named type the
// contract's tables reach (the emitter reads the entry module's exported
// declarations).
export type { Model, Msg, Filter, Task } from "./markup_fixture.ts";
export type { ColorScheme, ChromeInsets, ChromeButtons } from "./sdk/events.ts";
export type { TextInputEvent, TextCaretMove, TextCaretDirection, TextSelection } from "./sdk/text.ts";

// The exported-const channel conventions must be DECLARED here (the
// sidecar emitter reads the entry module's own declarations; re-exports
// do not join its tables), and the paired battery's comptime channel
// checks hold these restatements equal to the author's. This core
// declares no model helpers.
export const appearanceMsg = "appearance_changed";

export const chromeMsg = "chrome_changed";

export const envMsgs = [{ env: "TS_BOARD_BANNER", msg: "banner_set" }];

// The designated shape-flag export: init returns the model alone
// (init_returns_cmd false) and update returns [model, cmd bytes]
// (update_returns_cmd true).
export function init(): Model {
  return initialModel();
}

// Declaration-order wire tags (the contract sidecar is the tag
// authority; a skewed table cannot survive the paired battery's byte
// comparison or the mirror's boot fence).
const armNames = [
  "add",
  "toggle",
  "pick",
  "cycle",
  "clear",
  "stamp",
  "stamped",
  "hover_row",
  "hover_off",
  "draft_edit",
  "canvas_resized",
  "zoomed",
  "appearance_changed",
  "chrome_changed",
  "banner_set",
];

const TAG_add = 0;
const TAG_toggle = 1;
const TAG_pick = 2;
const TAG_cycle = 3;
const TAG_clear = 4;
const TAG_stamp = 5;
const TAG_stamped = 6;
const TAG_hover_row = 7;
const TAG_hover_off = 8;
const TAG_draft_edit = 9;
const TAG_canvas_resized = 10;
const TAG_zoomed = 11;
const TAG_appearance_changed = 12;
const TAG_chrome_changed = 13;
const TAG_banner_set = 14;

function tagOf(kind: string): number {
  for (let i = 0; i < armNames.length; i++) {
    if (armNames[i] === kind) return i;
  }
  trap("a command routes the unknown arm " + kind + " — the author module and this adapter disagree");
}

export function coreUpdate(model: Model, msg: Msg): [Model, Uint8Array] {
  const pair = update(model, msg);
  return [pair[0], cmdBytes(pair[1] as Cmd<never>, tagOf)];
}

// ------------------------------------------------ the dispatch surface
// One committed model in module state; every dispatch entry runs one
// update+commit and returns the cycle's command bytes.

const cmdNone = new Uint8Array(0);

let committed: Model = initialModel();

function commit(out: [Model, Uint8Array]): Uint8Array {
  committed = out[0];
  return out[1];
}

function trapUnknownTag(entry: string, tag: number): never {
  trap("tag " + tag + " does not name a " + entry + " message arm of this core — the host and this core disagree about the contract");
}

export function boot_cmd(): Uint8Array {
  // init_returns_cmd is false for this contract: no boot command.
  return cmdNone;
}

export function dispatch_void(tag: number): Uint8Array {
  if (tag === TAG_add) return commit(coreUpdate(committed, { kind: "add" }));
  if (tag === TAG_cycle) return commit(coreUpdate(committed, { kind: "cycle" }));
  if (tag === TAG_clear) return commit(coreUpdate(committed, { kind: "clear" }));
  if (tag === TAG_stamp) return commit(coreUpdate(committed, { kind: "stamp" }));
  trapUnknownTag("bare", tag);
}

export function dispatch_bytes(tag: number, payload: Uint8Array): Uint8Array {
  if (tag === TAG_banner_set) return commit(coreUpdate(committed, { kind: "banner_set", value: payload }));
  trapUnknownTag("bytes", tag);
}

export function dispatch_number(tag: number, value: number): Uint8Array {
  if (tag === TAG_toggle) return commit(coreUpdate(committed, { kind: "toggle", id: value }));
  if (tag === TAG_pick) return commit(coreUpdate(committed, { kind: "pick", id: value }));
  if (tag === TAG_stamped) return commit(coreUpdate(committed, { kind: "stamped", at: value }));
  if (tag === TAG_hover_row) return commit(coreUpdate(committed, { kind: "hover_row", id: value }));
  if (tag === TAG_hover_off) return commit(coreUpdate(committed, { kind: "hover_off", id: value }));
  if (tag === TAG_canvas_resized) return commit(coreUpdate(committed, { kind: "canvas_resized", width: value }));
  trapUnknownTag("number", tag);
}

export function dispatch_number_bytes(tag: number, value: number, payload: Uint8Array): Uint8Array {
  trapUnknownTag("number-with-bytes", tag);
}

export function dispatch_bool(tag: number, value: number): Uint8Array {
  trapUnknownTag("boolean", tag);
}

export function dispatch_enum(tag: number, member: number): Uint8Array {
  trapUnknownTag("enum", tag);
}

// The enum member table the contract's ColorScheme entry fixes; a
// payload's member index reads back through it.
const colorSchemes: ColorScheme[] = ["light", "dark"];

function trapMember(enumName: string, member: number): never {
  trap("member index " + member + " does not name a " + enumName + " member — the host and this core disagree about the contract");
}

export function dispatch_record(tag: number, fields: Uint8Array): Uint8Array {
  if (tag === TAG_zoomed) {
    assertConsumed(fields, 17);
    return commit(coreUpdate(committed, {
      kind: "zoomed",
      factor: readF64(fields, 0),
      windowId: readF64(fields, 8),
      fromBoard: readBool(fields, 16),
    }));
  }
  if (tag === TAG_appearance_changed) {
    const scheme = readU32(fields, 0);
    if (scheme >= colorSchemes.length) trapMember("ColorScheme", scheme);
    assertConsumed(fields, 6);
    return commit(coreUpdate(committed, {
      kind: "appearance_changed",
      colorScheme: colorSchemes[scheme]!,
      reduceMotion: readBool(fields, 4),
      highContrast: readBool(fields, 5),
    }));
  }
  if (tag === TAG_chrome_changed) {
    assertConsumed(fields, 65);
    return commit(coreUpdate(committed, {
      kind: "chrome_changed",
      insets: {
        top: readF64(fields, 0),
        right: readF64(fields, 8),
        bottom: readF64(fields, 16),
        left: readF64(fields, 24),
      },
      buttons: {
        x: readF64(fields, 32),
        y: readF64(fields, 40),
        width: readF64(fields, 48),
        height: readF64(fields, 56),
      },
      tabsProjected: readBool(fields, 64),
    }));
  }
  if (tag === TAG_draft_edit) {
    // The emitted contract may store this union's record payloads by
    // reference, in which case the mirror routes the arm through the
    // generic record entry; the canonical union encoding is the same
    // either way.
    return commit(coreUpdate(committed, { kind: "draft_edit", edit: decodeTextInputEvent(fields) }));
  }
  trapUnknownTag("record", tag);
}

export function dispatch_text_input(tag: number, event: Uint8Array): Uint8Array {
  if (tag === TAG_draft_edit) {
    return commit(coreUpdate(committed, { kind: "draft_edit", edit: decodeTextInputEvent(event) }));
  }
  trapUnknownTag("text-input", tag);
}

export function dispatch_scroll_state(
  tag: number,
  offsetX: number,
  offsetY: number,
  velocityX: number,
  velocityY: number,
  viewportExtentX: number,
  viewportExtentY: number,
  contentExtentX: number,
  contentExtentY: number,
): Uint8Array {
  trapUnknownTag("scroll-state", tag);
}

// --------------------------------------------- the ABI channel entries
// Each answers the channel bytes envelope: [produced u8][tag u8]
// [payload in the arm's canonical value encoding].

function noChannelMsg(): Uint8Array {
  return new Uint8Array(2);
}

function channelEnvelope(tag: number, payload: Uint8Array): Uint8Array {
  const out = new Uint8Array(2 + payload.length);
  out[0] = 1;
  out[1] = tag;
  for (let i = 0; i < payload.length; i++) out[2 + i] = payload[i]!;
  return out;
}

function f64Payload(value: number): Uint8Array {
  const sink = newSink();
  wF64(sink, value);
  return finish(sink);
}

function asciiString(bytes: Uint8Array): string {
  let out = "";
  for (let i = 0; i < bytes.length; i++) out = out + String.fromCharCode(bytes[i]!);
  return out;
}

export function abi_frame_msg(width: number, height: number, timestampMs: number, intervalMs: number): Uint8Array {
  const produced = coreFrameMsg(committed, {
    width: width,
    height: height,
    timestampMs: timestampMs,
    intervalMs: intervalMs,
  });
  if (produced === null) return noChannelMsg();
  // The one arm this channel produces carries the frame width.
  if (produced.kind === "canvas_resized") {
    return channelEnvelope(TAG_canvas_resized, f64Payload(produced.width));
  }
  trap("the frame channel produced the unroutable arm " + produced.kind + " — the author module and this adapter disagree");
}

export function abi_key_msg(
  key: Uint8Array,
  shift: number,
  control: number,
  alt: number,
  superMod: number,
): Uint8Array {
  const produced = coreKeyMsg({
    key: asciiString(key),
    shift: shift !== 0,
    control: control !== 0,
    alt: alt !== 0,
    super: superMod !== 0,
  });
  if (produced === null) return noChannelMsg();
  // Every arm this channel produces is payload-free.
  return channelEnvelope(tagOf(produced.kind), new Uint8Array(0));
}

// The pinch phase table the channel's u32 member index reads back
// through (the SDK's declared PinchPhase members, in order).
const pinchPhases: PinchPhase[] = ["begin", "change", "end"];

export function abi_pinch_msg(
  windowId: number,
  label: Uint8Array,
  phase: number,
  scale: number,
  x: number,
  y: number,
): Uint8Array {
  if (phase >= pinchPhases.length) trapMember("PinchPhase", phase);
  const produced = corePinchMsg({
    windowId: windowId,
    label: asciiString(label),
    phase: pinchPhases[phase]!,
    scale: scale,
    x: x,
    y: y,
  });
  if (produced === null) return noChannelMsg();
  // The one arm this channel produces carries the zoom record: the
  // multiplicative factor plus the gesture's source identity.
  if (produced.kind === "zoomed") {
    const sink = newSink();
    wF64(sink, produced.factor);
    wF64(sink, produced.windowId);
    wBool(sink, produced.fromBoard);
    return channelEnvelope(TAG_zoomed, finish(sink));
  }
  trap("the pinch channel produced the unroutable arm " + produced.kind + " — the author module and this adapter disagree");
}

// --------------------------------------------------------- post-cycle

export function subscriptions(): Uint8Array {
  // has_subscriptions is false for this contract: always empty.
  return new Uint8Array(0);
}

// The canonical committed-model encoding (snapshot format 1): the Model
// record's fields in declaration order, enums as u32 member indices,
// optionals as a one-byte present flag plus the inner value when
// present, slices as u32 count + elements — the same bytes the
// transpiler lane's canonical encoder emits for this model. The field
// names stay the author's camelCase spellings: the markup binds fields
// by their own names, so a contract that renamed them would not be this
// fixture's contract.

const filters: Filter[] = ["all", "open", "done"];

function wEnum(sink: Sink, members: string[], value: string): void {
  for (let i = 0; i < members.length; i++) {
    if (members[i] === value) {
      wU32(sink, i);
      return;
    }
  }
  trap("a model enum slot carries an undeclared member — the author module and this adapter disagree");
}

function wOptionalF64(sink: Sink, value: number | null): void {
  if (value === null) {
    wBool(sink, false);
    return;
  }
  wBool(sink, true);
  wF64(sink, value);
}

export function model_snapshot(): Uint8Array {
  const sink = newSink();
  const model = committed;
  wEnum(sink, filters, model.filter);
  wF64(sink, model.nextId);
  wF64(sink, model.doneCount);
  wBytes(sink, model.banner);
  wOptionalF64(sink, model.selected);
  wU32(sink, model.tasks.length);
  for (let i = 0; i < model.tasks.length; i++) {
    const task = model.tasks[i]!;
    wF64(sink, task.id);
    wBytes(sink, task.title);
    wBool(sink, task.done);
  }
  wF64(sink, model.stampMs);
  wBytes(sink, model.draft);
  wF64(sink, model.canvasWidth);
  wF64(sink, model.zoom);
  wF64(sink, model.zoomWindowId);
  wBool(sink, model.zoomFromBoard);
  wBool(sink, model.dark);
  wF64(sink, model.chromeTop);
  wF64(sink, model.previewSurface);
  wF64(sink, model.hoveredId);
  return finish(sink);
}

// This core declares no model helpers; the entry stays for the ABI's
// fixed export set.
export function helper_call(helper: number, args: Uint8Array): Uint8Array {
  assertConsumed(args, 0);
  trap("helper index " + helper + " does not name an exported model helper of this core — the host and this core disagree about the contract");
}

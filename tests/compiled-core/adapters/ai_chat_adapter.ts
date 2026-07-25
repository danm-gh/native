// The ai-chat fixture's compiled-core entry module — the interim
// hand-authored stand-in for compile-mode wiring: it imports the
// AUTHOR'S core (examples/ai-chat-ts/src/core.ts, staged beside this
// file with its SDK imports resolved locally), owns the committed model
// in module state, and exports the profile-declared dispatch surface.
// Inbound payloads decode through the shared wire codec; the returned
// Cmd data encodes through the same codec's v3 command wire; snapshots
// go through the generated facade's own compiled encoder — the contract
// artifact under test. The paired e2e battery holds every byte of this
// module to the transpiler lane's output.

import {
  initialModel,
  update,
  unconfigured as coreUnconfigured,
  endpointMissing as coreEndpointMissing,
  modelMissing as coreModelMissing,
  keyMissing as coreKeyMissing,
  sending as coreSending,
  failed as coreFailed,
  failReasonLabel as coreFailReasonLabel,
  draftText as coreDraftText,
  emptyConversation as coreEmptyConversation,
  modelLabel as coreModelLabel,
  sendDisabled as coreSendDisabled,
  clearDisabled as coreClearDisabled,
  turnRows as coreTurnRows,
  type Model,
  type Msg,
  type TurnRow,
} from "./core.ts";
import type { Cmd } from "./sdk/core.ts";
import type { ScrollState } from "./sdk/events.ts";
import {
  assertConsumed,
  cmdBytes,
  decodeTextInputEvent,
  finish,
  newSink,
  trap,
  truncTowardZero,
  wBool,
  wBytes,
  wF64,
  wU32,
  type Sink,
} from "./wire.ts";

// The contract type designations the sidecar section names — the
// author's declarations re-exported verbatim, plus every named type the
// contract's tables reach (the emitter reads the entry module's
// exported declarations).
export type { Model, Msg, ComposerDraft, Phase, TurnRow } from "./core.ts";
export type { Turn, Role } from "./api.ts";
export type { ScrollState } from "./sdk/events.ts";
export type { TextInputEvent, TextCaretMove, TextCaretDirection, TextSelection } from "./sdk/text.ts";

// The exported-const channel conventions and the model helpers must be
// DECLARED here (the sidecar emitter reads the entry module's own
// declarations; re-exports do not join its tables). The helper wrappers
// stand in declaration order — the contract's model_helpers table and
// helper_call's index space both derive from it — and the paired
// battery's comptime channel checks hold these restatements equal to
// the author's.
export const envMsgs = [
  { env: "NATIVE_SDK_CHAT_ENDPOINT", msg: "endpoint_set" },
  { env: "NATIVE_SDK_CHAT_MODEL", msg: "model_set" },
  { env: "NATIVE_SDK_CHAT_API_KEY", msg: "key_set" },
];

export const viewUnbound = [
  "chat_response",
  "chat_failed",
  "endpoint_set",
  "model_set",
  "key_set",
  "turns",
  "nextId",
  "phase",
  "failReason",
  "draft",
  "endpoint",
  "modelName",
  "apiKey",
];

export function unconfigured(model: Model): boolean {
  return coreUnconfigured(model);
}
export function endpointMissing(model: Model): boolean {
  return coreEndpointMissing(model);
}
export function modelMissing(model: Model): boolean {
  return coreModelMissing(model);
}
export function keyMissing(model: Model): boolean {
  return coreKeyMissing(model);
}
export function sending(model: Model): boolean {
  return coreSending(model);
}
export function failed(model: Model): boolean {
  return coreFailed(model);
}
export function failReasonLabel(model: Model): Uint8Array {
  return coreFailReasonLabel(model);
}
export function draftText(model: Model): Uint8Array {
  return coreDraftText(model);
}
export function emptyConversation(model: Model): boolean {
  return coreEmptyConversation(model);
}
export function modelLabel(model: Model): Uint8Array {
  return coreModelLabel(model);
}
export function sendDisabled(model: Model): boolean {
  return coreSendDisabled(model);
}
export function clearDisabled(model: Model): boolean {
  return coreClearDisabled(model);
}
export function turnRows(model: Model): TurnRow[] {
  return coreTurnRows(model) as TurnRow[];
}

// The designated shape-flag exports: init returns the bare model
// (init_returns_cmd false), update returns [model, cmd bytes]
// (update_returns_cmd true).
export function init(): Model {
  return initialModel();
}

// Declaration-order wire tags (the contract sidecar is the tag
// authority; a skewed table cannot survive the paired battery's
// byte comparison or the mirror's boot fence).
const TAG_draft_edit = 0;
const TAG_send = 1;
const TAG_retry = 2;
const TAG_clear = 3;
const TAG_chat_response = 4;
const TAG_chat_failed = 5;
const TAG_chat_scrolled = 6;
const TAG_endpoint_set = 7;
const TAG_model_set = 8;
const TAG_key_set = 9;

function tagOf(kind: string): number {
  switch (kind) {
    case "draft_edit":
      return TAG_draft_edit;
    case "send":
      return TAG_send;
    case "retry":
      return TAG_retry;
    case "clear":
      return TAG_clear;
    case "chat_response":
      return TAG_chat_response;
    case "chat_failed":
      return TAG_chat_failed;
    case "chat_scrolled":
      return TAG_chat_scrolled;
    case "endpoint_set":
      return TAG_endpoint_set;
    case "model_set":
      return TAG_model_set;
    case "key_set":
      return TAG_key_set;
    default:
      trap("a command routes the unknown arm " + kind + " — the author module and this adapter disagree");
  }
}

const cmdNone = new Uint8Array(0);

export function coreUpdate(model: Model, msg: Msg): [Model, Uint8Array] {
  const pair = update(model, msg);
  return [pair[0], cmdBytes(pair[1] as Cmd<never>, tagOf)];
}

// ------------------------------------------------ the dispatch surface
// One committed model in module state; every dispatch entry runs one
// update+commit and returns the cycle's command bytes.

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
  if (tag === TAG_send) return commit(coreUpdate(committed, { kind: "send" }));
  if (tag === TAG_retry) return commit(coreUpdate(committed, { kind: "retry" }));
  if (tag === TAG_clear) return commit(coreUpdate(committed, { kind: "clear" }));
  trapUnknownTag("bare", tag);
}

export function dispatch_bytes(tag: number, payload: Uint8Array): Uint8Array {
  if (tag === TAG_chat_failed) return commit(coreUpdate(committed, { kind: "chat_failed", reason: payload }));
  if (tag === TAG_endpoint_set) return commit(coreUpdate(committed, { kind: "endpoint_set", value: payload }));
  if (tag === TAG_model_set) return commit(coreUpdate(committed, { kind: "model_set", value: payload }));
  if (tag === TAG_key_set) return commit(coreUpdate(committed, { kind: "key_set", value: payload }));
  trapUnknownTag("bytes", tag);
}

export function dispatch_number(tag: number, value: number): Uint8Array {
  trapUnknownTag("number", tag);
}

export function dispatch_number_bytes(tag: number, value: number, payload: Uint8Array): Uint8Array {
  if (tag === TAG_chat_response) {
    return commit(coreUpdate(committed, { kind: "chat_response", status: truncTowardZero(value), body: payload }));
  }
  trapUnknownTag("number-with-bytes", tag);
}

export function dispatch_bool(tag: number, value: number): Uint8Array {
  trapUnknownTag("boolean", tag);
}

export function dispatch_enum(tag: number, member: number): Uint8Array {
  trapUnknownTag("enum", tag);
}

export function dispatch_record(tag: number, fields: Uint8Array): Uint8Array {
  if (tag === TAG_draft_edit) {
    // The emitted contract stores this union's record payloads by
    // reference, so the mirror routes the arm through the generic
    // record entry; the canonical union encoding is the same either
    // way ([arm u8][payload]).
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
  if (tag === TAG_chat_scrolled) {
    const scroll: ScrollState = {
      offsetX: offsetX,
      offsetY: offsetY,
      velocityX: velocityX,
      velocityY: velocityY,
      viewportExtentX: viewportExtentX,
      viewportExtentY: viewportExtentY,
      contentExtentX: contentExtentX,
      contentExtentY: contentExtentY,
    };
    return commit(coreUpdate(committed, { kind: "chat_scrolled", scroll: scroll }));
  }
  trapUnknownTag("scroll-state", tag);
}

// --------------------------------------------------------- post-cycle

export function subscriptions(): Uint8Array {
  // has_subscriptions is false for this contract: always empty.
  return new Uint8Array(0);
}

// The canonical committed-model encoding (snapshot format 1): the
// Model record's fields in declaration order, enums as u32 member
// indices, records inline, slices as u32 count + elements — the same
// bytes the transpiler lane's canonical encoder emits for this model.

const roleMembers = ["user", "assistant"] as const;
const phaseMembers = ["idle", "sending", "failed"] as const;

function wEnum(sink: Sink, members: readonly string[], value: string): void {
  for (let i = 0; i < members.length; i++) {
    if (members[i] === value) {
      wU32(sink, i);
      return;
    }
  }
  trap("a model enum slot carries an undeclared member — the author module and this adapter disagree");
}

export function model_snapshot(): Uint8Array {
  const sink = newSink();
  const model = committed;
  wU32(sink, model.turns.length);
  for (let i = 0; i < model.turns.length; i++) {
    const turn = model.turns[i]!;
    wF64(sink, turn.id);
    wEnum(sink, roleMembers, turn.role);
    wBytes(sink, turn.text);
  }
  wF64(sink, model.nextId);
  wEnum(sink, phaseMembers, model.phase);
  wBytes(sink, model.failReason);
  wBytes(sink, model.draft.bytes);
  wF64(sink, model.draft.anchor);
  wF64(sink, model.draft.focus);
  wF64(sink, model.draft.compStart);
  wF64(sink, model.draft.compEnd);
  wBytes(sink, model.endpoint);
  wBytes(sink, model.modelName);
  wBytes(sink, model.apiKey);
  wF64(sink, model.chatScrollTop);
  return finish(sink);
}

// ------------------------------------------------------- model helpers
// Indexed by the contract's model_helpers order; results ride the
// canonical value encoding of each helper's declared return type.

function boolResult(value: boolean): Uint8Array {
  const sink = newSink();
  wBool(sink, value);
  return finish(sink);
}

function bytesResult(value: Uint8Array): Uint8Array {
  const sink = newSink();
  wBytes(sink, value);
  return finish(sink);
}

export function helper_call(helper: number, args: Uint8Array): Uint8Array {
  assertConsumed(args, 0);
  if (helper === 0) return boolResult(coreUnconfigured(committed));
  if (helper === 1) return boolResult(coreEndpointMissing(committed));
  if (helper === 2) return boolResult(coreModelMissing(committed));
  if (helper === 3) return boolResult(coreKeyMissing(committed));
  if (helper === 4) return boolResult(coreSending(committed));
  if (helper === 5) return boolResult(coreFailed(committed));
  if (helper === 6) return bytesResult(coreFailReasonLabel(committed));
  if (helper === 7) return bytesResult(coreDraftText(committed));
  if (helper === 8) return boolResult(coreEmptyConversation(committed));
  if (helper === 9) return bytesResult(coreModelLabel(committed));
  if (helper === 10) return boolResult(coreSendDisabled(committed));
  if (helper === 11) return boolResult(coreClearDisabled(committed));
  if (helper === 12) {
    const rows = coreTurnRows(committed);
    const sink = newSink();
    wU32(sink, rows.length);
    for (let i = 0; i < rows.length; i++) {
      const row = rows[i]!;
      wF64(sink, row.id);
      wBool(sink, row.user);
      wBytes(sink, row.text);
    }
    return finish(sink);
  }
  trap("helper index " + helper + " does not name an exported model helper of this core — the host and this core disagree about the contract");
}

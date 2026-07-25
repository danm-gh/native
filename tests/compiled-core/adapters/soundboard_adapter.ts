import {
  initialModel,
  update,
  subscriptions as coreSubs,
  frameMsg as coreFrameMsg,
  keyMsg as coreKeyMsg,
  type Model,
  type Msg,
} from "./core.ts";
import type { Cmd, Sub } from "./sdk/core.ts";
import { cmdBytes, subBytes, trap } from "./wire.ts";

export type { Model, Msg, SearchDraft, Tab, QueueEntry } from "./core.ts";
export type { AlbumCell, TrackRow } from "./library.ts";
export type { ScrollState, ChromeInsets, ChromeButtons } from "./sdk/events.ts";
export type { TextInputEvent, TextCaretMove, TextCaretDirection, TextSelection } from "./sdk/text.ts";

export const envMsgs = [{ env: "NATIVE_SDK_MUSIC_URL_BASE", msg: "url_base_set" }];
export const chromeMsg = "chrome_changed";
export const viewUnbound = ["audio_event"];

function tagOf(kind: string): number {
  if (kind === "url_base_set") return 17;
  trap("unknown arm " + kind);
}

export function init(): Model {
  return initialModel();
}

export function coreUpdate(model: Model, msg: Msg): [Model, Uint8Array] {
  const pair = update(model, msg);
  return [pair[0], cmdBytes(pair[1] as Cmd<never>, tagOf)];
}

export function coreSubscriptions(model: Model): Uint8Array {
  return subBytes(coreSubs(model) as Sub<never>, tagOf);
}

export function frameMsg(model: Model, width: number, height: number, timestampMs: number, intervalMs: number): Uint8Array {
  const produced = coreFrameMsg(model, { width: width, height: height, timestampMs: timestampMs, intervalMs: intervalMs });
  if (produced === null) return new Uint8Array(2);
  return new Uint8Array(2);
}

export function keyMsg(key: Uint8Array, shift: number, control: number, alt: number, superMod: number): Uint8Array {
  return new Uint8Array(2);
}

let committed: Model = initialModel();

export function boot_cmd(): Uint8Array {
  return new Uint8Array(0);
}
export function dispatch_void(tag: number): Uint8Array {
  trap("stub " + tag);
}
export function dispatch_bytes(tag: number, payload: Uint8Array): Uint8Array {
  trap("stub " + tag);
}
export function dispatch_number(tag: number, value: number): Uint8Array {
  trap("stub " + tag);
}
export function dispatch_number_bytes(tag: number, value: number, payload: Uint8Array): Uint8Array {
  trap("stub " + tag);
}
export function dispatch_bool(tag: number, value: number): Uint8Array {
  trap("stub " + tag);
}
export function dispatch_enum(tag: number, member: number): Uint8Array {
  trap("stub " + tag);
}
export function dispatch_record(tag: number, fields: Uint8Array): Uint8Array {
  trap("stub " + tag);
}
export function dispatch_text_input(tag: number, event: Uint8Array): Uint8Array {
  trap("stub " + tag);
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
  trap("stub " + tag);
}
export function subscriptions(): Uint8Array {
  return coreSubscriptions(committed);
}
export function model_snapshot(): Uint8Array {
  return new Uint8Array(0);
}
export function helper_call(helper: number, args: Uint8Array): Uint8Array {
  trap("stub " + helper);
}

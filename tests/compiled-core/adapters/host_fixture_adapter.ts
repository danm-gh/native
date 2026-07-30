// The host fixture's compiled-core entry module — the interim
// hand-authored stand-in for compile-mode wiring: it imports the
// AUTHOR'S core (tests/ts-core/fixture.ts, staged beside this file with
// its SDK imports resolved locally), owns the committed model in module
// state, and exports the profile-declared dispatch surface. Inbound
// payloads decode through the shared wire codec; the returned Cmd and
// Sub data encode through the same codec's v3 wires. The paired e2e
// battery holds every byte of this module to the transpiler lane's
// output.

import {
  initialModel,
  update,
  subscriptions as coreSubs,
  type Model,
  type Msg,
  type AudioState,
  type VideoState,
  type ImageState,
  type ChannelState,
} from "./fixture.ts";
import type { Cmd, Sub } from "./sdk/core.ts";
import {
  assertConsumed,
  cmdBytes,
  finish,
  newSink,
  readBool,
  readBytesBody,
  readF64,
  readU32,
  subBytes,
  trap,
  wBool,
  wBytes,
  wF64,
  wI64,
  wU32,
  type Sink,
} from "./wire.ts";

// The contract type designations the sidecar section names — the
// author's declarations re-exported verbatim, plus every named type the
// contract's tables reach.
export type {
  Model,
  Msg,
  AudioState,
  VideoState,
  ImageState,
  ChannelState,
} from "./fixture.ts";

// The designated shape-flag exports: init returns [model, cmd bytes]
// (init_returns_cmd true) and update returns [model, cmd bytes]
// (update_returns_cmd true).
export function init(): [Model, Uint8Array] {
  const pair = initialModel();
  return [pair[0], cmdBytes(pair[1] as Cmd<never>, tagOf)];
}

// Declaration-order wire tags (the contract sidecar is the tag
// authority; a skewed table cannot survive the paired battery's byte
// comparison or the mirror's boot fence).
const armNames = [
  "toggle",
  "refresh",
  "abort",
  "stamp",
  "note",
  "loaded",
  "failed",
  "tick",
  "stamped",
  "save",
  "load",
  "wrote",
  "get",
  "fetched",
  "share",
  "paste",
  "later",
  "halt",
  "boomed",
  "run",
  "hang",
  "kill",
  "lined",
  "ended",
  "play",
  "pause_music",
  "set_volume",
  "stop_music",
  "audio_evt",
  "play_clip",
  "pause_clip",
  "stop_clip",
  "video_evt",
  "show_cover",
  "show_cover_again",
  "load_next",
  "load_top",
  "load_past",
  "load_flood",
  "load_frac",
  "load_sized",
  "load_top_bytes",
  "load_past_bytes",
  "cancel_cover",
  "cancel_missing",
  "evict_first",
  "evict_cover",
  "evict_missing",
  "image_done",
  "watch",
  "mix_reject",
  "mix_reject_flip",
  "chan_evt",
];

const TAG_toggle = 0;
const TAG_refresh = 1;
const TAG_abort = 2;
const TAG_stamp = 3;
const TAG_note = 4;
const TAG_loaded = 5;
const TAG_failed = 6;
const TAG_tick = 7;
const TAG_stamped = 8;
const TAG_save = 9;
const TAG_load = 10;
const TAG_wrote = 11;
const TAG_get = 12;
const TAG_fetched = 13;
const TAG_share = 14;
const TAG_paste = 15;
const TAG_later = 16;
const TAG_halt = 17;
const TAG_boomed = 18;
const TAG_run = 19;
const TAG_hang = 20;
const TAG_kill = 21;
const TAG_lined = 22;
const TAG_ended = 23;
const TAG_play = 24;
const TAG_pause_music = 25;
const TAG_set_volume = 26;
const TAG_stop_music = 27;
const TAG_audio_evt = 28;
const TAG_play_clip = 29;
const TAG_pause_clip = 30;
const TAG_stop_clip = 31;
const TAG_video_evt = 32;
const TAG_show_cover = 33;
const TAG_show_cover_again = 34;
const TAG_load_next = 35;
const TAG_load_top = 36;
const TAG_load_past = 37;
const TAG_load_flood = 38;
const TAG_load_frac = 39;
const TAG_load_sized = 40;
const TAG_load_top_bytes = 41;
const TAG_load_past_bytes = 42;
const TAG_cancel_cover = 43;
const TAG_cancel_missing = 44;
const TAG_evict_first = 45;
const TAG_evict_cover = 46;
const TAG_evict_missing = 47;
const TAG_image_done = 48;
const TAG_watch = 49;
const TAG_mix_reject = 50;
const TAG_mix_reject_flip = 51;
const TAG_chan_evt = 52;

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

export function coreSubscriptions(model: Model): Uint8Array {
  return subBytes(coreSubs(model) as Sub<never>, tagOf);
}

// ------------------------------------------------ the dispatch surface
// One committed model in module state; every dispatch entry runs one
// update+commit and returns the cycle's command bytes.

const bootPair = initialModel();
let committed: Model = bootPair[0];

function commit(out: [Model, Uint8Array]): Uint8Array {
  committed = out[0];
  return out[1];
}

function trapUnknownTag(entry: string, tag: number): never {
  trap("tag " + tag + " does not name a " + entry + " message arm of this core — the host and this core disagree about the contract");
}

export function boot_cmd(): Uint8Array {
  return cmdBytes(bootPair[1] as Cmd<never>, tagOf);
}

export function dispatch_void(tag: number): Uint8Array {
  if (tag === TAG_toggle) return commit(coreUpdate(committed, { kind: "toggle" }));
  if (tag === TAG_refresh) return commit(coreUpdate(committed, { kind: "refresh" }));
  if (tag === TAG_abort) return commit(coreUpdate(committed, { kind: "abort" }));
  if (tag === TAG_stamp) return commit(coreUpdate(committed, { kind: "stamp" }));
  if (tag === TAG_note) return commit(coreUpdate(committed, { kind: "note" }));
  if (tag === TAG_save) return commit(coreUpdate(committed, { kind: "save" }));
  if (tag === TAG_load) return commit(coreUpdate(committed, { kind: "load" }));
  if (tag === TAG_wrote) return commit(coreUpdate(committed, { kind: "wrote" }));
  if (tag === TAG_get) return commit(coreUpdate(committed, { kind: "get" }));
  if (tag === TAG_share) return commit(coreUpdate(committed, { kind: "share" }));
  if (tag === TAG_paste) return commit(coreUpdate(committed, { kind: "paste" }));
  if (tag === TAG_later) return commit(coreUpdate(committed, { kind: "later" }));
  if (tag === TAG_halt) return commit(coreUpdate(committed, { kind: "halt" }));
  if (tag === TAG_run) return commit(coreUpdate(committed, { kind: "run" }));
  if (tag === TAG_hang) return commit(coreUpdate(committed, { kind: "hang" }));
  if (tag === TAG_kill) return commit(coreUpdate(committed, { kind: "kill" }));
  if (tag === TAG_play) return commit(coreUpdate(committed, { kind: "play" }));
  if (tag === TAG_pause_music) return commit(coreUpdate(committed, { kind: "pause_music" }));
  if (tag === TAG_set_volume) return commit(coreUpdate(committed, { kind: "set_volume" }));
  if (tag === TAG_stop_music) return commit(coreUpdate(committed, { kind: "stop_music" }));
  if (tag === TAG_play_clip) return commit(coreUpdate(committed, { kind: "play_clip" }));
  if (tag === TAG_pause_clip) return commit(coreUpdate(committed, { kind: "pause_clip" }));
  if (tag === TAG_stop_clip) return commit(coreUpdate(committed, { kind: "stop_clip" }));
  if (tag === TAG_show_cover) return commit(coreUpdate(committed, { kind: "show_cover" }));
  if (tag === TAG_show_cover_again) return commit(coreUpdate(committed, { kind: "show_cover_again" }));
  if (tag === TAG_load_next) return commit(coreUpdate(committed, { kind: "load_next" }));
  if (tag === TAG_load_top) return commit(coreUpdate(committed, { kind: "load_top" }));
  if (tag === TAG_load_past) return commit(coreUpdate(committed, { kind: "load_past" }));
  if (tag === TAG_load_flood) return commit(coreUpdate(committed, { kind: "load_flood" }));
  if (tag === TAG_load_frac) return commit(coreUpdate(committed, { kind: "load_frac" }));
  if (tag === TAG_load_sized) return commit(coreUpdate(committed, { kind: "load_sized" }));
  if (tag === TAG_load_top_bytes) return commit(coreUpdate(committed, { kind: "load_top_bytes" }));
  if (tag === TAG_load_past_bytes) return commit(coreUpdate(committed, { kind: "load_past_bytes" }));
  if (tag === TAG_cancel_cover) return commit(coreUpdate(committed, { kind: "cancel_cover" }));
  if (tag === TAG_cancel_missing) return commit(coreUpdate(committed, { kind: "cancel_missing" }));
  if (tag === TAG_evict_first) return commit(coreUpdate(committed, { kind: "evict_first" }));
  if (tag === TAG_evict_cover) return commit(coreUpdate(committed, { kind: "evict_cover" }));
  if (tag === TAG_evict_missing) return commit(coreUpdate(committed, { kind: "evict_missing" }));
  if (tag === TAG_watch) return commit(coreUpdate(committed, { kind: "watch" }));
  if (tag === TAG_mix_reject) return commit(coreUpdate(committed, { kind: "mix_reject" }));
  if (tag === TAG_mix_reject_flip) return commit(coreUpdate(committed, { kind: "mix_reject_flip" }));
  trapUnknownTag("bare", tag);
}

export function dispatch_bytes(tag: number, payload: Uint8Array): Uint8Array {
  if (tag === TAG_loaded) return commit(coreUpdate(committed, { kind: "loaded", body: payload }));
  if (tag === TAG_failed) return commit(coreUpdate(committed, { kind: "failed", why: payload }));
  if (tag === TAG_lined) return commit(coreUpdate(committed, { kind: "lined", text: payload }));
  trapUnknownTag("bytes", tag);
}

export function dispatch_number(tag: number, value: number): Uint8Array {
  if (tag === TAG_tick) return commit(coreUpdate(committed, { kind: "tick", at: value }));
  if (tag === TAG_stamped) return commit(coreUpdate(committed, { kind: "stamped", at: value }));
  if (tag === TAG_boomed) return commit(coreUpdate(committed, { kind: "boomed", at: value }));
  if (tag === TAG_ended) return commit(coreUpdate(committed, { kind: "ended", code: value }));
  trapUnknownTag("number", tag);
}

export function dispatch_number_bytes(tag: number, value: number, payload: Uint8Array): Uint8Array {
  if (tag === TAG_fetched) {
    return commit(coreUpdate(committed, { kind: "fetched", status: value, body: payload }));
  }
  trapUnknownTag("number-with-bytes", tag);
}

export function dispatch_bool(tag: number, value: number): Uint8Array {
  trapUnknownTag("boolean", tag);
}

export function dispatch_enum(tag: number, member: number): Uint8Array {
  trapUnknownTag("enum", tag);
}

// The enum member tables the contract's enum entries fix; a payload's
// member index reads back through them.
const audioStates: AudioState[] = ["loaded", "position", "completed", "failed", "rejected", "spectrum"];
const videoStates: VideoState[] = ["loaded", "position", "completed", "failed", "rejected"];
const imageStates: ImageState[] = [
  "loaded",
  "rejected",
  "not_found",
  "io_failed",
  "connect_failed",
  "tls_failed",
  "protocol_failed",
  "timed_out",
  "http_status",
  "cancelled",
  "too_large",
  "unsupported",
  "decode_failed",
  "registry_full",
  "alloc_failed",
];
const channelStates: ChannelState[] = ["data", "closed", "rejected"];

function trapMember(enumName: string, member: number): never {
  trap("member index " + member + " does not name a " + enumName + " member — the host and this core disagree about the contract");
}

export function dispatch_record(tag: number, fields: Uint8Array): Uint8Array {
  if (tag === TAG_audio_evt) {
    const state = readU32(fields, 0);
    if (state >= audioStates.length) trapMember("AudioState", state);
    const bandsLen = readU32(fields, 22);
    assertConsumed(fields, 26 + bandsLen);
    return commit(coreUpdate(committed, {
      kind: "audio_evt",
      state: audioStates[state]!,
      positionMs: readF64(fields, 4),
      durationMs: readF64(fields, 12),
      playing: readBool(fields, 20),
      buffering: readBool(fields, 21),
      bands: readBytesBody(fields, 26, bandsLen),
    }));
  }
  if (tag === TAG_video_evt) {
    const state = readU32(fields, 0);
    if (state >= videoStates.length) trapMember("VideoState", state);
    assertConsumed(fields, 38);
    return commit(coreUpdate(committed, {
      kind: "video_evt",
      state: videoStates[state]!,
      positionMs: readF64(fields, 4),
      durationMs: readF64(fields, 12),
      playing: readBool(fields, 20),
      buffering: readBool(fields, 21),
      width: readF64(fields, 22),
      height: readF64(fields, 30),
    }));
  }
  if (tag === TAG_image_done) {
    const state = readU32(fields, 8);
    if (state >= imageStates.length) trapMember("ImageState", state);
    assertConsumed(fields, 36);
    return commit(coreUpdate(committed, {
      kind: "image_done",
      id: readF64(fields, 0),
      state: imageStates[state]!,
      width: readF64(fields, 12),
      height: readF64(fields, 20),
      status: readF64(fields, 28),
    }));
  }
  if (tag === TAG_chan_evt) {
    const state = readU32(fields, 8);
    if (state >= channelStates.length) trapMember("ChannelState", state);
    const bytesLen = readU32(fields, 12);
    const after = 16 + bytesLen;
    assertConsumed(fields, after + 16);
    return commit(coreUpdate(committed, {
      kind: "chan_evt",
      key: readF64(fields, 0),
      state: channelStates[state]!,
      bytes: readBytesBody(fields, 16, bytesLen),
      droppedPending: readF64(fields, after),
      droppedTotal: readF64(fields, after + 8),
    }));
  }
  trapUnknownTag("record", tag);
}

export function dispatch_text_input(tag: number, event: Uint8Array): Uint8Array {
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

// --------------------------------------------------------- post-cycle

export function subscriptions(): Uint8Array {
  return coreSubscriptions(committed);
}

// The canonical committed-model encoding (snapshot format 1): the Model
// record's fields in declaration order, enums as u32 member indices,
// slices as u32 count + elements — the same bytes the transpiler lane's
// canonical encoder emits for this model.

function wEnum(sink: Sink, members: string[], value: string): void {
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
  wBool(sink, model.polling);
  wI64(sink, model.ticks);
  wF64(sink, model.lastTickAt);
  wF64(sink, model.stampMs);
  wI64(sink, model.failures);
  wBytes(sink, model.status);
  wBytes(sink, model.lastErr);
  wI64(sink, model.saved);
  wF64(sink, model.code);
  wF64(sink, model.firedAt);
  wI64(sink, model.lines);
  wBytes(sink, model.lastLine);
  wF64(sink, model.exitCode);
  wEnum(sink, audioStates, model.audioState);
  wF64(sink, model.posMs);
  wF64(sink, model.durMs);
  wBool(sink, model.playing);
  wBytes(sink, model.bands);
  wI64(sink, model.audioEvents);
  wEnum(sink, videoStates, model.videoState);
  wF64(sink, model.vPosMs);
  wF64(sink, model.vDurMs);
  wBool(sink, model.vPlaying);
  wF64(sink, model.vW);
  wF64(sink, model.vH);
  wI64(sink, model.videoEvents);
  wF64(sink, model.cover);
  wF64(sink, model.coverW);
  wF64(sink, model.coverH);
  wEnum(sink, imageStates, model.imageState);
  wF64(sink, model.imageStatus);
  wI64(sink, model.imageResults);
  wF64(sink, model.lastImageId);
  wI64(sink, model.nextCover);
  wI64(sink, model.topId);
  wF64(sink, model.fracBytes);
  wI64(sink, model.wholeBytes);
  wI64(sink, model.topBytes);
  wF64(sink, model.pastBytes);
  wEnum(sink, channelStates, model.chanState);
  wI64(sink, model.chanEvents);
  wI64(sink, model.rejectSeq);
  wI64(sink, model.chanRejectAt);
  wI64(sink, model.imgRejectAt);
  return finish(sink);
}

// This core declares no model helpers; the entry stays for the ABI's
// fixed export set.
export function helper_call(helper: number, args: Uint8Array): Uint8Array {
  assertConsumed(args, 0);
  trap("helper index " + helper + " does not name an exported model helper of this core — the host and this core disagree about the contract");
}

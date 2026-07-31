// The soundboard fixture's compiled-core entry module — the interim
// hand-authored stand-in for compile-mode wiring: it imports the
// AUTHOR'S core (examples/soundboard-ts/src/core.ts, staged beside this
// file with its SDK imports resolved locally), owns the committed model
// in module state, and exports the profile-declared dispatch surface.
// Inbound payloads decode through the shared wire codec; the returned
// Cmd and Sub data encode through the same codec's v3 wires. The paired
// e2e battery holds every byte of this module to the transpiler lane's
// output.

import {
  initialModel,
  update,
  subscriptions as coreSubs,
  frameMsg as coreFrameMsg,
  keyMsg as coreKeyMsg,
  albumsShowing as h_albumsShowing,
  songsShowing as h_songsShowing,
  detailPage as h_detailPage,
  searchText as h_searchText,
  visibleAlbums as h_visibleAlbums,
  gridColumns as h_gridColumns,
  gridShownColumns as h_gridShownColumns,
  gridTileWidth as h_gridTileWidth,
  gridRowWidth as h_gridRowWidth,
  gridCoverSize as h_gridCoverSize,
  gridTileHeight as h_gridTileHeight,
  visibleTracks as h_visibleTracks,
  openAlbumRows as h_openAlbumRows,
  visibleAlbumCount as h_visibleAlbumCount,
  albumCount as h_albumCount,
  visibleTrackCount as h_visibleTrackCount,
  trackCount as h_trackCount,
  noAlbumMatches as h_noAlbumMatches,
  noTrackMatches as h_noTrackMatches,
  noMatchesLabel as h_noMatchesLabel,
  openAlbumId as h_openAlbumId,
  openAlbumTitle as h_openAlbumTitle,
  openAlbumInitials as h_openAlbumInitials,
  openAlbumCover as h_openAlbumCover,
  openAlbumMeta as h_openAlbumMeta,
  idle as h_idle,
  nowPlayingTitle as h_nowPlayingTitle,
  nowPlayingArtist as h_nowPlayingArtist,
  nowPlayingInitials as h_nowPlayingInitials,
  nowPlayingCover as h_nowPlayingCover,
  playPauseIcon as h_playPauseIcon,
  progressFraction as h_progressFraction,
  elapsedLabel as h_elapsedLabel,
  durationLabel as h_durationLabel,
  queueLen as h_queueLen,
  type Model,
  type Msg,
} from "./core.ts";
import type { AlbumCell, TrackRow } from "./library.ts";
import type { Cmd, Sub } from "./sdk/core.ts";
import type { FrameEvent, KeyEvent, ScrollState } from "./sdk/events.ts";
import {
  assertConsumed,
  cmdBytes,
  decodeTextInputEvent,
  finish,
  newSink,
  readBool,
  readBytesBody,
  readF64,
  readI64,
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
// contract's tables reach (the emitter reads the entry module's exported
// declarations).
export type { Model, Msg, SearchDraft, Tab, QueueEntry } from "./core.ts";
export type { AlbumCell, TrackRow } from "./library.ts";
export type { ScrollState, ChromeInsets, ChromeButtons, AudioState } from "./sdk/events.ts";
export type { TextInputEvent, TextCaretMove, TextCaretDirection, TextSelection } from "./sdk/text.ts";

// The exported-const channel conventions and the model helpers must be
// DECLARED here (the sidecar emitter reads the entry module's own
// declarations; re-exports do not join its tables). The helper wrappers
// stand in declaration order — the contract's model_helpers table and
// helper_call's index space both derive from it — and the paired
// battery's comptime channel checks hold these restatements equal to the
// author's.
export const envMsgs = [{ env: "NATIVE_SDK_MUSIC_URL_BASE", msg: "url_base_set" }];

export const chromeMsg = "chrome_changed";

export const viewUnbound = [
  "audio_event",
  "clock_tick",
  "canvas_resized",
  "url_base_set",
  "chrome_changed",
  "canvasWidth",
  "urlBase",
  "tab",
  "openAlbum",
  "now",
  "playing",
  "elapsedMs",
  "nowDurationMs",
  "platformDurationMs",
  "loadPending",
  "buffering",
  "assetsMissing",
  "streamFailed",
  "queue",
  "queueDropped",
  "search",
  "copiesRequested",
];

// The two function channels answer to the ABI export table — a profile
// export whose symbol ends in `frame_msg`/`key_msg` turns the contract's
// channel flag on. Their flat-parameter entries sit further down; no
// author-signature restatement belongs here, because an exported
// model-first function is a MODEL HELPER to the contract emitter.

export function albumsShowing(model: Model): boolean {
  return h_albumsShowing(model);
}
export function songsShowing(model: Model): boolean {
  return h_songsShowing(model);
}
export function detailPage(model: Model): boolean {
  return h_detailPage(model);
}
export function searchText(model: Model): Uint8Array {
  return h_searchText(model);
}
export function visibleAlbums(model: Model): AlbumCell[] {
  return h_visibleAlbums(model) as AlbumCell[];
}
// Classed helper returns prove at this boundary: bind the helper's
// value, range-guard it (an ordered comparison excludes NaN), and state
// wholeness with Math.trunc at the return.
export function gridColumns(model: Model): number {
  const count = h_gridColumns(model);
  if (count >= -9007199254740991 && count <= 9007199254740991) return Math.trunc(count);
  trap("a helper return is NaN or past ±(2^53 − 1) — the i64 slot has no honest value for it");
}
export function gridShownColumns(model: Model): number {
  const count = h_gridShownColumns(model);
  if (count >= -9007199254740991 && count <= 9007199254740991) return Math.trunc(count);
  trap("a helper return is NaN or past ±(2^53 − 1) — the i64 slot has no honest value for it");
}
export function gridTileWidth(model: Model): number {
  return h_gridTileWidth(model);
}
export function gridRowWidth(model: Model): number {
  return h_gridRowWidth(model);
}
export function gridCoverSize(model: Model): number {
  return h_gridCoverSize(model);
}
export function gridTileHeight(model: Model): number {
  return h_gridTileHeight(model);
}
export function visibleTracks(model: Model): TrackRow[] {
  return h_visibleTracks(model) as TrackRow[];
}
export function openAlbumRows(model: Model): TrackRow[] {
  return h_openAlbumRows(model) as TrackRow[];
}
export function visibleAlbumCount(model: Model): number {
  const count = h_visibleAlbumCount(model);
  if (count >= -9007199254740991 && count <= 9007199254740991) return Math.trunc(count);
  trap("a helper return is NaN or past ±(2^53 − 1) — the i64 slot has no honest value for it");
}
export function albumCount(model: Model): number {
  const count = h_albumCount(model);
  if (count >= -9007199254740991 && count <= 9007199254740991) return Math.trunc(count);
  trap("a helper return is NaN or past ±(2^53 − 1) — the i64 slot has no honest value for it");
}
export function visibleTrackCount(model: Model): number {
  const count = h_visibleTrackCount(model);
  if (count >= -9007199254740991 && count <= 9007199254740991) return Math.trunc(count);
  trap("a helper return is NaN or past ±(2^53 − 1) — the i64 slot has no honest value for it");
}
export function trackCount(model: Model): number {
  const count = h_trackCount(model);
  if (count >= -9007199254740991 && count <= 9007199254740991) return Math.trunc(count);
  trap("a helper return is NaN or past ±(2^53 − 1) — the i64 slot has no honest value for it");
}
export function noAlbumMatches(model: Model): boolean {
  return h_noAlbumMatches(model);
}
export function noTrackMatches(model: Model): boolean {
  return h_noTrackMatches(model);
}
export function noMatchesLabel(model: Model): Uint8Array {
  return h_noMatchesLabel(model);
}
export function openAlbumId(model: Model): number {
  const id = h_openAlbumId(model);
  if (id >= -9007199254740991 && id <= 9007199254740991) return Math.trunc(id);
  trap("a helper return is NaN or past ±(2^53 − 1) — the i64 slot has no honest value for it");
}
export function openAlbumTitle(model: Model): Uint8Array {
  return h_openAlbumTitle(model);
}
export function openAlbumInitials(model: Model): Uint8Array {
  return h_openAlbumInitials(model);
}
export function openAlbumCover(model: Model): number {
  const cover = h_openAlbumCover(model);
  if (cover >= -9007199254740991 && cover <= 9007199254740991) return Math.trunc(cover);
  trap("a helper return is NaN or past ±(2^53 − 1) — the i64 slot has no honest value for it");
}
export function openAlbumMeta(model: Model): Uint8Array {
  return h_openAlbumMeta(model);
}
export function idle(model: Model): boolean {
  return h_idle(model);
}
export function nowPlayingTitle(model: Model): Uint8Array {
  return h_nowPlayingTitle(model);
}
export function nowPlayingArtist(model: Model): Uint8Array {
  return h_nowPlayingArtist(model);
}
export function nowPlayingInitials(model: Model): Uint8Array {
  return h_nowPlayingInitials(model);
}
export function nowPlayingCover(model: Model): number {
  const cover = h_nowPlayingCover(model);
  if (cover >= -9007199254740991 && cover <= 9007199254740991) return Math.trunc(cover);
  trap("a helper return is NaN or past ±(2^53 − 1) — the i64 slot has no honest value for it");
}
export function playPauseIcon(model: Model): Uint8Array {
  return h_playPauseIcon(model);
}
export function progressFraction(model: Model): number {
  return h_progressFraction(model);
}
export function elapsedLabel(model: Model): Uint8Array {
  return h_elapsedLabel(model);
}
export function durationLabel(model: Model): Uint8Array {
  return h_durationLabel(model);
}
export function queueLen(model: Model): number {
  const len = h_queueLen(model);
  if (len >= -9007199254740991 && len <= 9007199254740991) return Math.trunc(len);
  trap("a helper return is NaN or past ±(2^53 − 1) — the i64 slot has no honest value for it");
}

// The designated shape-flag exports: init returns the bare model
// (init_returns_cmd false), update returns [model, cmd bytes]
// (update_returns_cmd true).
export function init(): Model {
  return initialModel();
}

// Declaration-order wire tags (the contract sidecar is the tag
// authority; a skewed table cannot survive the paired battery's byte
// comparison or the mirror's boot fence).
const armNames = [
  "show_albums",
  "show_songs",
  "open_album",
  "close_album",
  "play_album",
  "play_track",
  "toggle_play",
  "next_track",
  "prev_track",
  "queue_track",
  "copy_title",
  "search_edit",
  "audio_event",
  "clock_tick",
  "scrubbed",
  "library_scrolled",
  "canvas_resized",
  "url_base_set",
  "chrome_changed",
];

const TAG_show_albums = 0;
const TAG_show_songs = 1;
const TAG_open_album = 2;
const TAG_close_album = 3;
const TAG_play_album = 4;
const TAG_play_track = 5;
const TAG_toggle_play = 6;
const TAG_next_track = 7;
const TAG_prev_track = 8;
const TAG_queue_track = 9;
const TAG_copy_title = 10;
const TAG_search_edit = 11;
const TAG_audio_event = 12;
const TAG_clock_tick = 13;
const TAG_scrubbed = 14;
const TAG_library_scrolled = 15;
const TAG_canvas_resized = 16;
const TAG_url_base_set = 17;
const TAG_chrome_changed = 18;

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
  return new Uint8Array(0);
}

export function dispatch_void(tag: number): Uint8Array {
  if (tag === TAG_show_albums) return commit(coreUpdate(committed, { kind: "show_albums" }));
  if (tag === TAG_show_songs) return commit(coreUpdate(committed, { kind: "show_songs" }));
  if (tag === TAG_close_album) return commit(coreUpdate(committed, { kind: "close_album" }));
  if (tag === TAG_toggle_play) return commit(coreUpdate(committed, { kind: "toggle_play" }));
  if (tag === TAG_next_track) return commit(coreUpdate(committed, { kind: "next_track" }));
  if (tag === TAG_prev_track) return commit(coreUpdate(committed, { kind: "prev_track" }));
  trapUnknownTag("bare", tag);
}

export function dispatch_bytes(tag: number, payload: Uint8Array): Uint8Array {
  if (tag === TAG_url_base_set) return commit(coreUpdate(committed, { kind: "url_base_set", value: payload }));
  trapUnknownTag("bytes", tag);
}

export function dispatch_number(tag: number, value: number): Uint8Array {
  // These arms remain f64-classed in the contract: preserve the value
  // exactly instead of routing it through the integer proof below.
  if (tag === TAG_clock_tick) return commit(coreUpdate(committed, { kind: "clock_tick", at: value }));
  if (tag === TAG_scrubbed) return commit(coreUpdate(committed, { kind: "scrubbed", fraction: value }));
  if (tag === TAG_canvas_resized) return commit(coreUpdate(committed, { kind: "canvas_resized", width: value }));

  // The id arms are i64-classed and prove in place: range-guard the raw
  // f64 (an ordered comparison excludes NaN) and state wholeness with
  // Math.trunc at the write.
  if (tag === TAG_open_album || tag === TAG_play_album || tag === TAG_play_track || tag === TAG_queue_track || tag === TAG_copy_title) {
    if (value >= -9007199254740991 && value <= 9007199254740991) {
      const whole = Math.trunc(value);
      if (tag === TAG_open_album) return commit(coreUpdate(committed, { kind: "open_album", openAlbumId: whole }));
      if (tag === TAG_play_album) return commit(coreUpdate(committed, { kind: "play_album", playAlbumId: whole }));
      if (tag === TAG_play_track) return commit(coreUpdate(committed, { kind: "play_track", playTrackId: whole }));
      if (tag === TAG_queue_track) return commit(coreUpdate(committed, { kind: "queue_track", queueTrackId: whole }));
      return commit(coreUpdate(committed, { kind: "copy_title", copyTitleId: whole }));
    }
    trap("a numeric dispatch value is NaN or past ±(2^53 − 1) — an i64 slot has no honest value for it");
  }
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

const audioStates = ["loaded", "position", "completed", "failed", "rejected", "spectrum"];
const tabs = ["albums", "songs"];

function decodeScrollState(bytes: Uint8Array, at: number): ScrollState {
  return {
    offsetX: readF64(bytes, at),
    offsetY: readF64(bytes, at + 8),
    velocityX: readF64(bytes, at + 16),
    velocityY: readF64(bytes, at + 24),
    viewportExtentX: readF64(bytes, at + 32),
    viewportExtentY: readF64(bytes, at + 40),
    contentExtentX: readF64(bytes, at + 48),
    contentExtentY: readF64(bytes, at + 56),
  };
}

export function dispatch_record(tag: number, fields: Uint8Array): Uint8Array {
  if (tag === TAG_audio_event) {
    const state = readU32(fields, 0);
    if (state >= audioStates.length) {
      trap("member index " + state + " does not name an AudioState member — the host and this core disagree about the contract");
    }
    const bandsLen = readU32(fields, 22);
    assertConsumed(fields, 26 + bandsLen);
    // The clock slots are i64-classed: range-guard each decoded value (an
    // ordered comparison excludes NaN) and state wholeness with Math.trunc
    // at the write.
    const positionMs = readI64(fields, 4);
    const durationMs = readI64(fields, 12);
    if (positionMs >= -9007199254740991 && positionMs <= 9007199254740991 && durationMs >= -9007199254740991 && durationMs <= 9007199254740991) {
      return commit(coreUpdate(committed, {
        kind: "audio_event",
        state: audioStates[state]! as "loaded",
        positionMs: Math.trunc(positionMs),
        durationMs: Math.trunc(durationMs),
        playing: readBool(fields, 20),
        buffering: readBool(fields, 21),
        bands: readBytesBody(fields, 26, bandsLen),
      }));
    }
    trap("an audio clock value is NaN or past ±(2^53 − 1) — an i64 slot has no honest value for it");
  }
  if (tag === TAG_library_scrolled) {
    assertConsumed(fields, 64);
    return commit(coreUpdate(committed, { kind: "library_scrolled", scroll: decodeScrollState(fields, 0) }));
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
  if (tag === TAG_search_edit) {
    // The emitted contract stores this union's record payloads by
    // reference, so the mirror routes the arm through the generic record
    // entry; the canonical union encoding is the same either way.
    return commit(coreUpdate(committed, { kind: "search_edit", edit: decodeTextInputEvent(fields) }));
  }
  trapUnknownTag("record", tag);
}

export function dispatch_text_input(tag: number, event: Uint8Array): Uint8Array {
  if (tag === TAG_search_edit) {
    return commit(coreUpdate(committed, { kind: "search_edit", edit: decodeTextInputEvent(event) }));
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
  if (tag === TAG_library_scrolled) {
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
    return commit(coreUpdate(committed, { kind: "library_scrolled", scroll: scroll }));
  }
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

function asciiString(bytes: Uint8Array): string {
  let out = "";
  for (let i = 0; i < bytes.length; i++) out = out + String.fromCharCode(bytes[i]!);
  return out;
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

// --------------------------------------------------------- post-cycle

export function subscriptions(): Uint8Array {
  return coreSubscriptions(committed);
}

// The canonical committed-model encoding (snapshot format 1): the Model
// record's fields in declaration order, enums as u32 member indices,
// optionals as a one-byte present flag plus the inner value when
// present, records inline, slices as u32 count + elements — the same
// bytes the transpiler lane's canonical encoder emits for this model.

function wEnum(sink: Sink, members: string[], value: string): void {
  for (let i = 0; i < members.length; i++) {
    if (members[i] === value) {
      wU32(sink, i);
      return;
    }
  }
  trap("a model enum slot carries an undeclared member — the author module and this adapter disagree");
}

function wOptionalBytes(sink: Sink, value: Uint8Array | null): void {
  if (value === null) {
    wBool(sink, false);
    return;
  }
  wBool(sink, true);
  wBytes(sink, value);
}

function wOptionalI64(sink: Sink, value: number | null): void {
  if (value === null) {
    wBool(sink, false);
    return;
  }
  wBool(sink, true);
  wI64(sink, value);
}

export function model_snapshot(): Uint8Array {
  const sink = newSink();
  const model = committed;
  wEnum(sink, tabs, model.tab);
  wOptionalI64(sink, model.openAlbum);
  wOptionalI64(sink, model.now);
  wBool(sink, model.playing);
  wI64(sink, model.elapsedMs);
  wI64(sink, model.nowDurationMs);
  wI64(sink, model.platformDurationMs);
  wBool(sink, model.loadPending);
  wBool(sink, model.buffering);
  wBool(sink, model.assetsMissing);
  wBool(sink, model.streamFailed);
  wU32(sink, model.queue.length);
  for (let i = 0; i < model.queue.length; i++) {
    wI64(sink, model.queue[i]!.id);
  }
  wI64(sink, model.queueDropped);
  wBytes(sink, model.search.bytes);
  wI64(sink, model.search.anchor);
  wI64(sink, model.search.focus);
  wI64(sink, model.search.compStart);
  wI64(sink, model.search.compEnd);
  wI64(sink, model.copiesRequested);
  wF64(sink, model.libraryScrollTop);
  wF64(sink, model.canvasWidth);
  wOptionalBytes(sink, model.urlBase);
  wF64(sink, model.chromeLeading);
  wF64(sink, model.chromeTrailing);
  wF64(sink, model.headerHeight);
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

function numberResult(value: number): Uint8Array {
  const sink = newSink();
  wF64(sink, value);
  return finish(sink);
}

function intResult(value: number): Uint8Array {
  const sink = newSink();
  wI64(sink, value);
  return finish(sink);
}

function albumCellsResult(rows: AlbumCell[]): Uint8Array {
  const sink = newSink();
  wU32(sink, rows.length);
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i]!;
    wI64(sink, row.id);
    wBytes(sink, row.title);
    wBytes(sink, row.artist);
    wBytes(sink, row.initials);
    wI64(sink, row.cover);
    wBool(sink, row.playing);
  }
  return finish(sink);
}

function trackRowsResult(rows: TrackRow[]): Uint8Array {
  const sink = newSink();
  wU32(sink, rows.length);
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i]!;
    wI64(sink, row.id);
    wI64(sink, row.number);
    wBytes(sink, row.title);
    wBytes(sink, row.subtitle);
    wBytes(sink, row.duration);
    wBool(sink, row.now);
    wBool(sink, row.playing);
    wBytes(sink, row.stateIcon);
    wBool(sink, row.queued);
  }
  return finish(sink);
}

export function helper_call(helper: number, args: Uint8Array): Uint8Array {
  assertConsumed(args, 0);
  if (helper === 0) return boolResult(h_albumsShowing(committed));
  if (helper === 1) return boolResult(h_songsShowing(committed));
  if (helper === 2) return boolResult(h_detailPage(committed));
  if (helper === 3) return bytesResult(h_searchText(committed));
  if (helper === 4) return albumCellsResult(h_visibleAlbums(committed) as AlbumCell[]);
  if (helper === 5) return intResult(gridColumns(committed));
  if (helper === 6) return intResult(gridShownColumns(committed));
  if (helper === 7) return numberResult(h_gridTileWidth(committed));
  if (helper === 8) return numberResult(h_gridRowWidth(committed));
  if (helper === 9) return numberResult(h_gridCoverSize(committed));
  if (helper === 10) return numberResult(h_gridTileHeight(committed));
  if (helper === 11) return trackRowsResult(h_visibleTracks(committed) as TrackRow[]);
  if (helper === 12) return trackRowsResult(h_openAlbumRows(committed) as TrackRow[]);
  if (helper === 13) return intResult(visibleAlbumCount(committed));
  if (helper === 14) return intResult(albumCount(committed));
  if (helper === 15) return intResult(visibleTrackCount(committed));
  if (helper === 16) return intResult(trackCount(committed));
  if (helper === 17) return boolResult(h_noAlbumMatches(committed));
  if (helper === 18) return boolResult(h_noTrackMatches(committed));
  if (helper === 19) return bytesResult(h_noMatchesLabel(committed));
  if (helper === 20) return intResult(openAlbumId(committed));
  if (helper === 21) return bytesResult(h_openAlbumTitle(committed));
  if (helper === 22) return bytesResult(h_openAlbumInitials(committed));
  if (helper === 23) return intResult(openAlbumCover(committed));
  if (helper === 24) return bytesResult(h_openAlbumMeta(committed));
  if (helper === 25) return boolResult(h_idle(committed));
  if (helper === 26) return bytesResult(h_nowPlayingTitle(committed));
  if (helper === 27) return bytesResult(h_nowPlayingArtist(committed));
  if (helper === 28) return bytesResult(h_nowPlayingInitials(committed));
  if (helper === 29) return intResult(nowPlayingCover(committed));
  if (helper === 30) return bytesResult(h_playPauseIcon(committed));
  if (helper === 31) return numberResult(h_progressFraction(committed));
  if (helper === 32) return bytesResult(h_elapsedLabel(committed));
  if (helper === 33) return bytesResult(h_durationLabel(committed));
  if (helper === 34) return intResult(queueLen(committed));
  trap("helper index " + helper + " does not name an exported model helper of this core — the host and this core disagree about the contract");
}

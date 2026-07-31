// The compiled-core adapters' shared wire codec: the canonical value
// encoding (little-endian, headerless, schema-driven — the encoding the
// mirror's decoder and the facade's encoders state) plus the v3
// command/subscription wire format the host consumes
// (packages/core/rt/rt.zig, cmd_format_version 3). Adapters are the
// interim hand-authored stand-in for compile-mode wiring: each fixture's
// adapter decodes inbound dispatch payloads with these readers, runs the
// author's update, and encodes the returned Cmd/Sub data with these
// encoders — byte-identical to what the transpiler lane emits, proven by
// the paired e2e batteries.

import type { Cmd, Sub, FetchMethod } from "./sdk/core.ts";
import type { TextCaretDirection, TextInputEvent } from "./sdk/text.ts";

// ------------------------------------------------------------- readers

export function trap(teaching: string): never {
  throw new Error(teaching);
}

export function readU32(bytes: Uint8Array, at: number): number {
  if (at + 4 > bytes.length) {
    trap("a dispatch payload ended mid-value — the host and this core disagree about a type's layout");
  }
  return bytes[at]! + bytes[at + 1]! * 256 + bytes[at + 2]! * 65536 + bytes[at + 3]! * 16777216;
}

export function readF64(bytes: Uint8Array, at: number): number {
  if (at + 8 > bytes.length) {
    trap("a dispatch payload ended mid-value — the host and this core disagree about a type's layout");
  }
  const buf = Buffer.alloc(8);
  for (let i = 0; i < 8; i++) {
    buf[i] = bytes[at + i]!;
  }
  return buf.readDoubleLE(0);
}

export function readI64(bytes: Uint8Array, at: number): number {
  const lo = readU32(bytes, at);
  const hi = readU32(bytes, at + 4);
  const hiSigned = hi >= 2147483648 ? hi - 4294967296 : hi;
  const value = hiSigned * 4294967296 + lo;
  if (value > 9007199254740991 || value < -9007199254740991) {
    trap("an integer payload is at or past 2^53 — the f64 number model has no honest value for it");
  }
  return value;
}

/// An i64 payload saturated into the f64-exact window: values at or
/// past ±2^53 clamp to ±(2^53 − 1). Selection offsets ride this reader
/// because the host's select-all synthesizes the maxInt "to the end"
/// sentinel, which every consumer snaps to the text's length.
export function readI64Saturating(bytes: Uint8Array, at: number): number {
  const lo = readU32(bytes, at);
  const hi = readU32(bytes, at + 4);
  const hiSigned = hi >= 2147483648 ? hi - 4294967296 : hi;
  const value = hiSigned * 4294967296 + lo;
  if (value > 9007199254740991) return 9007199254740991;
  if (value < -9007199254740991) return -9007199254740991;
  return value;
}

export function readBool(bytes: Uint8Array, at: number): boolean {
  if (at >= bytes.length) {
    trap("a dispatch payload ended mid-value — the host and this core disagree about a type's layout");
  }
  const raw = bytes[at]!;
  if (raw > 1) {
    trap("a dispatch payload carries a boolean discriminant past 1 — the host and this core disagree about a type's layout");
  }
  return raw === 1;
}

export function readBytesBody(bytes: Uint8Array, at: number, len: number): Uint8Array {
  if (at + len > bytes.length) {
    trap("a dispatch payload ended mid-value — the host and this core disagree about a type's layout");
  }
  const out = new Uint8Array(len);
  for (let i = 0; i < len; i++) {
    out[i] = bytes[at + i]!;
  }
  return out;
}

export function assertConsumed(bytes: Uint8Array, at: number): void {
  if (at !== bytes.length) {
    trap("a dispatch payload carries bytes past the decoded value — the host and this core disagree about a type's layout");
  }
}

/// An i64-classed arm narrows core-side by truncation toward zero
/// (producers guarantee integer-classed values are exact below 2^53).
export function truncTowardZero(value: number): number {
  return value < 0 ? -Math.floor(-value) : Math.floor(value);
}

// ------------------------------------------------------------- writers
// A sink is a plain byte accumulator; `finish` snapshots it.

export type Sink = number[];

export function newSink(): Sink {
  return [];
}

export function finish(sink: Sink): Uint8Array {
  const out = new Uint8Array(sink.length);
  for (let i = 0; i < sink.length; i++) {
    out[i] = sink[i]!;
  }
  return out;
}

export function wU8(sink: Sink, value: number): void {
  sink.push(value);
}

export function wU32(sink: Sink, value: number): void {
  sink.push(value % 256);
  sink.push(Math.floor(value / 256) % 256);
  sink.push(Math.floor(value / 65536) % 256);
  sink.push(Math.floor(value / 16777216) % 256);
}

export function wF64(sink: Sink, value: number): void {
  const buf = Buffer.alloc(8);
  buf.writeDoubleLE(value, 0);
  for (let i = 0; i < 8; i++) {
    sink.push(buf[i]!);
  }
}

/// Two's-complement i64, exact for every integer within +-(2^53 - 1).
export function wI64(sink: Sink, value: number): void {
  if (value > 9007199254740991 || value < -9007199254740991 || value !== truncTowardZero(value)) {
    trap("an integer slot carries a non-integer or out-of-range value — the i64 encoding has no honest bytes for it");
  }
  const hi = Math.floor(value / 4294967296);
  const lo = value - hi * 4294967296;
  const hiWire = hi < 0 ? hi + 4294967296 : hi;
  wU32(sink, lo);
  wU32(sink, hiWire);
}

export function wBool(sink: Sink, value: boolean): void {
  sink.push(value ? 1 : 0);
}

/// A u32-length-prefixed bytes value (the canonical bytes encoding, and
/// the wire format's long-bytes field).
export function wBytes(sink: Sink, bytes: Uint8Array): void {
  wU32(sink, bytes.length);
  for (let i = 0; i < bytes.length; i++) {
    sink.push(bytes[i]!);
  }
}

function textBytes(text: string): Uint8Array {
  const out = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) {
    out[i] = text.charCodeAt(i);
  }
  return out;
}

/// A u8-length-prefixed short text field (names, keys, labels).
function wShortText(sink: Sink, text: string): void {
  const bytes = textBytes(text);
  if (bytes.length > 255) {
    trap("a command name or key is over 255 bytes — the wire's short-text fields cannot carry it");
  }
  sink.push(bytes.length);
  for (let i = 0; i < bytes.length; i++) {
    sink.push(bytes[i]!);
  }
}

// ------------------------------------------- the text-input union wire
// The canonical encoding of the SDK's TextInputEvent (arm index u8 +
// payload), decoded into the author-level member names sdk/text.ts
// declares.

const caretDirections: readonly TextCaretDirection[] = ["previous", "next", "previous_word", "next_word", "start", "end"];

export function decodeTextInputEvent(bytes: Uint8Array): TextInputEvent {
  if (bytes.length === 0) {
    trap("a text-input payload carries no arm byte — the host and this core disagree about the contract");
  }
  const arm = bytes[0]!;
  switch (arm) {
    case 0: {
      const len = readU32(bytes, 1);
      const text = readBytesBody(bytes, 5, len);
      assertConsumed(bytes, 5 + len);
      return { kind: "insert_text", text: text };
    }
    case 1:
      assertConsumed(bytes, 1);
      return { kind: "delete_backward" };
    case 2:
      assertConsumed(bytes, 1);
      return { kind: "delete_forward" };
    case 3:
      assertConsumed(bytes, 1);
      return { kind: "delete_word_backward" };
    case 4:
      assertConsumed(bytes, 1);
      return { kind: "delete_word_forward" };
    case 5:
      assertConsumed(bytes, 1);
      return { kind: "clear" };
    case 6: {
      const member = readU32(bytes, 1);
      if (member >= caretDirections.length) {
        trap("a text-input payload carries an enum member index past the declared members — the host and this core disagree about the contract");
      }
      const extend = readBool(bytes, 5);
      assertConsumed(bytes, 6);
      return { kind: "move_caret", move: { direction: caretDirections[member]!, extend: extend } };
    }
    case 7: {
      // Selection indices are i64-classed slots and ride the i64
      // encoding (saturating: select-all sends the maxInt "to the end"
      // sentinel): bind the decoded values, range-guard them (an
      // ordered comparison excludes NaN), and state wholeness with
      // Math.trunc at the write.
      const anchor = readI64Saturating(bytes, 1);
      const focus = readI64Saturating(bytes, 9);
      assertConsumed(bytes, 17);
      if (anchor >= -9007199254740991 && anchor <= 9007199254740991 && focus >= -9007199254740991 && focus <= 9007199254740991) {
        return { kind: "set_selection", selection: { anchor: Math.trunc(anchor), focus: Math.trunc(focus) } };
      }
      trap("a selection index is NaN or past ±(2^53 − 1) — the i64 slot has no honest value for it");
    }
    case 8: {
      const len = readU32(bytes, 1);
      const text = readBytesBody(bytes, 5, len);
      let at = 5 + len;
      const present = readBool(bytes, at);
      at = at + 1;
      if (present) {
        // The cursor is an i64-classed optional slot: range-guard the
        // decoded value (an ordered comparison excludes NaN) and state
        // wholeness with Math.trunc at the write.
        const cursor = readI64(bytes, at);
        assertConsumed(bytes, at + 8);
        if (cursor >= -9007199254740991 && cursor <= 9007199254740991) {
          return { kind: "set_composition", text: text, cursor: Math.trunc(cursor) };
        }
        trap("a composition cursor is NaN or past ±(2^53 − 1) — an i64 slot has no honest value for it");
      }
      assertConsumed(bytes, at);
      return { kind: "set_composition", text: text, cursor: null };
    }
    case 9:
      assertConsumed(bytes, 1);
      return { kind: "commit_composition" };
    case 10:
      assertConsumed(bytes, 1);
      return { kind: "cancel_composition" };
    default:
      trap("a text-input payload carries a union arm index past the declared arms — the host and this core disagree about the contract");
  }
}

// ---------------------------------------------------- the cmd/sub wire
// Encoders for the inert Cmd/Sub data the author's update returns —
// byte-for-byte the layouts packages/core/rt/rt.zig builds. `tagOf`
// maps a Msg arm name onto its declaration-order wire tag (the facade's
// tag constants are the authority; each adapter supplies the map).

const fetchMethods: readonly FetchMethod[] = ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD"];
const audioVerbs = ["pause", "resume", "stop", "seek", "volume"] as const;
const videoVerbs = ["play", "pause", "stop", "seek", "volume", "muted", "loop"] as const;

function enumIndex(members: readonly string[], value: string, what: string): number {
  for (let i = 0; i < members.length; i++) {
    if (members[i] === value) return i;
  }
  trap("a command carries an unknown " + what + " member — the SDK and this adapter disagree");
}

export function encodeCmd(sink: Sink, cmd: Cmd<never>, tagOf: (kind: string) => number): void {
  switch (cmd.op) {
    case "none":
      return;
    case "persist":
      wU8(sink, 0x01);
      return;
    case "now":
      wU8(sink, 0x02);
      wU8(sink, tagOf(cmd.msgKind));
      return;
    case "host": {
      wU8(sink, 0x03);
      wShortText(sink, cmd.name);
      if (cmd.args.length > 255) {
        trap("a host command carries over 255 scalar args — the wire's arg block cannot carry it");
      }
      wU8(sink, cmd.args.length);
      for (let i = 0; i < cmd.args.length; i++) {
        wF64(sink, cmd.args[i]!);
      }
      return;
    }
    case "host_bytes":
      wU8(sink, 0x04);
      wShortText(sink, cmd.name);
      wBytes(sink, cmd.payload);
      return;
    case "request":
      wU8(sink, 0x05);
      wShortText(sink, cmd.name);
      wShortText(sink, cmd.key);
      wU8(sink, tagOf(cmd.okKind));
      wU8(sink, tagOf(cmd.errKind));
      wBytes(sink, cmd.payload);
      return;
    case "cancel":
      wU8(sink, 0x06);
      wShortText(sink, cmd.key);
      return;
    case "read_file":
      wU8(sink, 0x07);
      wShortText(sink, cmd.key);
      wU8(sink, tagOf(cmd.okKind));
      wU8(sink, tagOf(cmd.errKind));
      wBytes(sink, cmd.path);
      return;
    case "write_file":
      wU8(sink, 0x08);
      wShortText(sink, cmd.key);
      wU8(sink, tagOf(cmd.okKind));
      wU8(sink, tagOf(cmd.errKind));
      wBytes(sink, cmd.path);
      wBytes(sink, cmd.bytes);
      return;
    case "fetch": {
      wU8(sink, 0x09);
      wShortText(sink, cmd.key);
      wU8(sink, tagOf(cmd.okKind));
      wU8(sink, tagOf(cmd.errKind));
      wU8(sink, enumIndex(fetchMethods, cmd.method, "fetch method"));
      wU32(sink, cmd.timeoutMs);
      wBytes(sink, cmd.url);
      if (cmd.headers.length > 255) {
        trap("a fetch carries over 255 headers — the wire's header block cannot carry it");
      }
      wU8(sink, cmd.headers.length);
      for (let i = 0; i < cmd.headers.length; i++) {
        const header = cmd.headers[i]!;
        wShortText(sink, header.name);
        const value = header.value;
        wBytes(sink, typeof value === "string" ? textBytes(value) : value);
      }
      wBytes(sink, cmd.body);
      return;
    }
    case "clip_write":
      wU8(sink, 0x0a);
      wBytes(sink, cmd.bytes);
      return;
    case "clip_read":
      wU8(sink, 0x0b);
      wShortText(sink, cmd.key);
      wU8(sink, tagOf(cmd.okKind));
      wU8(sink, tagOf(cmd.errKind));
      return;
    case "delay":
      wU8(sink, 0x0c);
      wShortText(sink, cmd.key);
      wF64(sink, cmd.afterMs);
      wU8(sink, tagOf(cmd.msgKind));
      return;
    case "spawn": {
      wU8(sink, 0x0d);
      wShortText(sink, cmd.key);
      wU8(sink, cmd.lineKind === "" ? 0xff : tagOf(cmd.lineKind));
      wU8(sink, tagOf(cmd.exitKind));
      wU8(sink, tagOf(cmd.errKind));
      wU8(sink, cmd.collect ? 1 : 0);
      if (cmd.argv.length === 0 || cmd.argv.length > 255) {
        trap("a spawn carries no argv or over 255 argv entries — the wire's argv block cannot carry it");
      }
      wU8(sink, cmd.argv.length);
      for (let i = 0; i < cmd.argv.length; i++) {
        wBytes(sink, cmd.argv[i]!);
      }
      wBytes(sink, cmd.stdin);
      return;
    }
    case "audio_play":
      wU8(sink, 0x0e);
      wShortText(sink, cmd.key);
      wU8(sink, tagOf(cmd.eventKind));
      wBytes(sink, cmd.path);
      wBytes(sink, cmd.url);
      wBytes(sink, cmd.cachePath);
      wF64(sink, cmd.expectedBytes);
      return;
    case "audio_ctl":
      wU8(sink, 0x0f);
      wShortText(sink, cmd.key);
      wU8(sink, enumIndex(audioVerbs, cmd.verb, "audio verb"));
      wF64(sink, cmd.value);
      return;
    case "window_show":
      wU8(sink, 0x10);
      wShortText(sink, cmd.label);
      return;
    case "quit_app":
      wU8(sink, 0x11);
      return;
    case "image_load":
      wU8(sink, 0x12);
      wF64(sink, cmd.id);
      wU8(sink, tagOf(cmd.eventKind));
      wBytes(sink, cmd.path);
      wBytes(sink, cmd.url);
      wBytes(sink, cmd.cachePath);
      wF64(sink, cmd.expectedBytes);
      return;
    case "image_cancel":
      wU8(sink, 0x13);
      wF64(sink, cmd.id);
      return;
    case "image_unregister":
      wU8(sink, 0x14);
      wF64(sink, cmd.id);
      return;
    case "channel_open":
      wU8(sink, 0x15);
      wF64(sink, cmd.key);
      wU8(sink, tagOf(cmd.eventKind));
      return;
    case "channel_close":
      wU8(sink, 0x16);
      wF64(sink, cmd.key);
      return;
    case "video_load": {
      wU8(sink, 0x17);
      wShortText(sink, cmd.key);
      wU8(sink, tagOf(cmd.eventKind));
      wF64(sink, cmd.surface);
      wBytes(sink, cmd.path);
      wBytes(sink, cmd.url);
      // Wire flags: bit0 = autoplay, bit1 = loop, bit2 = muted.
      let flags = 0;
      if (cmd.autoplay) flags = flags + 1;
      if (cmd.loop) flags = flags + 2;
      if (cmd.muted) flags = flags + 4;
      wU8(sink, flags);
      return;
    }
    case "video_ctl":
      wU8(sink, 0x18);
      wShortText(sink, cmd.key);
      wU8(sink, enumIndex(videoVerbs, cmd.verb, "video verb"));
      wF64(sink, cmd.value);
      return;
    case "pty_spawn": {
      wU8(sink, 0x19);
      wShortText(sink, cmd.key);
      wU8(sink, tagOf(cmd.eventKind));
      wF64(sink, cmd.cols);
      wF64(sink, cmd.rows);
      wShortText(sink, cmd.term);
      if (cmd.argv.length === 0 || cmd.argv.length > 255) {
        trap("a pty spawn carries no argv or over 255 argv entries — the wire's argv block cannot carry it");
      }
      wU8(sink, cmd.argv.length);
      for (let i = 0; i < cmd.argv.length; i++) {
        wBytes(sink, cmd.argv[i]!);
      }
      return;
    }
    case "pty_write":
      wU8(sink, 0x1a);
      wShortText(sink, cmd.key);
      wBytes(sink, cmd.bytes);
      return;
    case "pty_resize":
      wU8(sink, 0x1b);
      wShortText(sink, cmd.key);
      wF64(sink, cmd.cols);
      wF64(sink, cmd.rows);
      return;
    case "pty_kill":
      wU8(sink, 0x1c);
      wShortText(sink, cmd.key);
      return;
    case "batch":
      for (let i = 0; i < cmd.cmds.length; i++) {
        encodeCmd(sink, cmd.cmds[i]!, tagOf);
      }
      return;
  }
}

export function cmdBytes(cmd: Cmd<never>, tagOf: (kind: string) => number): Uint8Array {
  const sink = newSink();
  encodeCmd(sink, cmd, tagOf);
  return finish(sink);
}

export function encodeSub(sink: Sink, sub: Sub<never>, tagOf: (kind: string) => number): void {
  switch (sub.op) {
    case "none":
      return;
    case "timer":
      wU8(sink, 0x01);
      wShortText(sink, sub.key);
      wF64(sink, sub.everyMs);
      wU8(sink, tagOf(sub.msgKind));
      return;
    case "batch":
      for (let i = 0; i < sub.subs.length; i++) {
        encodeSub(sink, sub.subs[i]!, tagOf);
      }
      return;
  }
}

export function subBytes(sub: Sub<never>, tagOf: (kind: string) => number): Uint8Array {
  const sink = newSink();
  encodeSub(sink, sub, tagOf);
  return finish(sink);
}

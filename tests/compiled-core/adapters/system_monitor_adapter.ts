// The system-monitor fixture's compiled-core entry module — the interim
// hand-authored stand-in for compile-mode wiring: it imports the
// AUTHOR'S core (examples/system-monitor-ts/src/core.ts, staged beside
// this file with its SDK imports resolved locally), owns the committed
// model in module state, and exports the profile-declared dispatch
// surface. Inbound payloads decode through the shared wire codec; the
// returned Cmd and Sub data encode through the same codec's v3 wires.
// The paired e2e battery holds every byte of this module to the
// transpiler lane's output.

import {
  initialModel,
  update,
  subscriptions as coreSubs,
  headerStatus as h_headerStatus,
  cpuValue as h_cpuValue,
  cpuDetail as h_cpuDetail,
  memValue as h_memValue,
  memDetail as h_memDetail,
  procValue as h_procValue,
  uptimeValue as h_uptimeValue,
  cpuSpark as h_cpuSpark,
  memSpark as h_memSpark,
  procSpark as h_procSpark,
  pauseLabel as h_pauseLabel,
  pauseIcon as h_pauseIcon,
  searchText as h_searchText,
  sortDirectionIcon as h_sortDirectionIcon,
  sortDirectionLabel as h_sortDirectionLabel,
  visibleRows as h_visibleRows,
  matchCount as h_matchCount,
  shownCount as h_shownCount,
  emptyTitle as h_emptyTitle,
  emptyHint as h_emptyHint,
  statusLine as h_statusLine,
  confirmingKill as h_confirmingKill,
  killPrompt as h_killPrompt,
  type Model,
  type Msg,
} from "./core.ts";
import type { TableRow } from "./table.ts";
import type { Cmd, Sub } from "./sdk/core.ts";
import type { ScrollState } from "./sdk/events.ts";
import {
  assertConsumed,
  cmdBytes,
  decodeTextInputEvent,
  finish,
  newSink,
  readBool,
  readF64,
  subBytes,
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
// contract's tables reach (the emitter reads the entry module's exported
// declarations).
export type { Model, Msg, SearchDraft, SamplerPhase, MemCommand, PendingKill } from "./core.ts";
export type { ParsedProcess } from "./parsers.ts";
export type { SortKey, TableRow } from "./table.ts";
export type { ScrollState, ChromeInsets, ChromeButtons } from "./sdk/events.ts";
export type { TextInputEvent, TextCaretMove, TextCaretDirection, TextSelection } from "./sdk/text.ts";

// The exported-const channel conventions and the model helpers must be
// DECLARED here (the sidecar emitter reads the entry module's own
// declarations; re-exports do not join its tables). The helper wrappers
// stand in declaration order — the contract's model_helpers table and
// helper_call's index space both derive from it — and the paired
// battery's comptime channel checks hold these restatements equal to the
// author's.
export const chromeMsg = "chrome_changed";

export const viewUnbound = [
  "tick",
  "info_done",
  "info_err",
  "info2_done",
  "info2_err",
  "ps_done",
  "ps_err",
  "mem_done",
  "mem_err",
  "stamped",
  "kill_done",
  "kill_err",
  "chrome_changed",
  "phase",
  "memCommand",
  "paused",
  "ticksSkipped",
  "psInflight",
  "memInflight",
  "samplesTaken",
  "sampledAtDayMs",
  "cores",
  "memTotalBytes",
  "cpuPercentTenths",
  "memUsedBytes",
  "processCount",
  "uptimeSeconds",
  "rows",
  "parseFailures",
  "cpuHistory",
  "memHistory",
  "procHistory",
  "search",
  "sortDescending",
  "pendingKill",
  "note",
  "noteClearsOnSample",
  "sampleGeneration",
  "noteStampGeneration",
];

export function headerStatus(model: Model): Uint8Array {
  return h_headerStatus(model);
}
export function cpuValue(model: Model): Uint8Array {
  return h_cpuValue(model);
}
export function cpuDetail(model: Model): Uint8Array {
  return h_cpuDetail(model);
}
export function memValue(model: Model): Uint8Array {
  return h_memValue(model);
}
export function memDetail(model: Model): Uint8Array {
  return h_memDetail(model);
}
export function procValue(model: Model): Uint8Array {
  return h_procValue(model);
}
export function uptimeValue(model: Model): Uint8Array {
  return h_uptimeValue(model);
}
export function cpuSpark(model: Model): number[] {
  return h_cpuSpark(model) as number[];
}
export function memSpark(model: Model): number[] {
  return h_memSpark(model) as number[];
}
export function procSpark(model: Model): number[] {
  return h_procSpark(model) as number[];
}
export function pauseLabel(model: Model): Uint8Array {
  return h_pauseLabel(model);
}
export function pauseIcon(model: Model): Uint8Array {
  return h_pauseIcon(model);
}
export function searchText(model: Model): Uint8Array {
  return h_searchText(model);
}
export function sortDirectionIcon(model: Model): Uint8Array {
  return h_sortDirectionIcon(model);
}
export function sortDirectionLabel(model: Model): Uint8Array {
  return h_sortDirectionLabel(model);
}
export function visibleRows(model: Model): TableRow[] {
  return h_visibleRows(model) as TableRow[];
}
export function matchCount(model: Model): number {
  return h_matchCount(model);
}
export function shownCount(model: Model): number {
  return h_shownCount(model);
}
export function emptyTitle(model: Model): Uint8Array {
  return h_emptyTitle(model);
}
export function emptyHint(model: Model): Uint8Array {
  return h_emptyHint(model);
}
export function statusLine(model: Model): Uint8Array {
  return h_statusLine(model);
}
export function confirmingKill(model: Model): boolean {
  return h_confirmingKill(model);
}
export function killPrompt(model: Model): Uint8Array {
  return h_killPrompt(model);
}

// The designated shape-flag exports: init returns [model, cmd bytes]
// (init_returns_cmd true — this core probes the host at boot), update
// returns the same pair shape.
export function init(): [Model, Uint8Array] {
  const pair = initialModel();
  return [pair[0], cmdBytes(pair[1] as Cmd<never>, tagOf)];
}

// Declaration-order wire tags (the contract sidecar is the tag
// authority; a skewed table cannot survive the paired battery's byte
// comparison or the mirror's boot fence).
const armNames = [
  "tick",
  "info_done",
  "info_err",
  "info2_done",
  "info2_err",
  "ps_done",
  "ps_err",
  "mem_done",
  "mem_err",
  "stamped",
  "toggle_sampling",
  "search_edit",
  "table_scrolled",
  "sort_cpu",
  "sort_mem",
  "sort_pid",
  "sort_name",
  "row_pressed",
  "request_kill",
  "cancel_kill",
  "confirm_kill",
  "kill_done",
  "kill_err",
  "copy_name",
  "chrome_changed",
];

const TAG_tick = 0;
const TAG_info_done = 1;
const TAG_info_err = 2;
const TAG_info2_done = 3;
const TAG_info2_err = 4;
const TAG_ps_done = 5;
const TAG_ps_err = 6;
const TAG_mem_done = 7;
const TAG_mem_err = 8;
const TAG_stamped = 9;
const TAG_toggle_sampling = 10;
const TAG_search_edit = 11;
const TAG_table_scrolled = 12;
const TAG_sort_cpu = 13;
const TAG_sort_mem = 14;
const TAG_sort_pid = 15;
const TAG_sort_name = 16;
const TAG_row_pressed = 17;
const TAG_request_kill = 18;
const TAG_cancel_kill = 19;
const TAG_confirm_kill = 20;
const TAG_kill_done = 21;
const TAG_kill_err = 22;
const TAG_copy_name = 23;
const TAG_chrome_changed = 24;

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
  if (tag === TAG_toggle_sampling) return commit(coreUpdate(committed, { kind: "toggle_sampling" }));
  if (tag === TAG_sort_cpu) return commit(coreUpdate(committed, { kind: "sort_cpu" }));
  if (tag === TAG_sort_mem) return commit(coreUpdate(committed, { kind: "sort_mem" }));
  if (tag === TAG_sort_pid) return commit(coreUpdate(committed, { kind: "sort_pid" }));
  if (tag === TAG_sort_name) return commit(coreUpdate(committed, { kind: "sort_name" }));
  if (tag === TAG_row_pressed) return commit(coreUpdate(committed, { kind: "row_pressed" }));
  if (tag === TAG_cancel_kill) return commit(coreUpdate(committed, { kind: "cancel_kill" }));
  if (tag === TAG_confirm_kill) return commit(coreUpdate(committed, { kind: "confirm_kill" }));
  trapUnknownTag("bare", tag);
}

export function dispatch_bytes(tag: number, payload: Uint8Array): Uint8Array {
  if (tag === TAG_info_err) return commit(coreUpdate(committed, { kind: "info_err", reason: payload }));
  if (tag === TAG_info2_err) return commit(coreUpdate(committed, { kind: "info2_err", reason: payload }));
  if (tag === TAG_ps_err) return commit(coreUpdate(committed, { kind: "ps_err", reason: payload }));
  if (tag === TAG_mem_err) return commit(coreUpdate(committed, { kind: "mem_err", reason: payload }));
  if (tag === TAG_kill_err) return commit(coreUpdate(committed, { kind: "kill_err", reason: payload }));
  trapUnknownTag("bytes", tag);
}

export function dispatch_number(tag: number, value: number): Uint8Array {
  if (tag === TAG_tick) return commit(coreUpdate(committed, { kind: "tick", at: value }));
  if (tag === TAG_stamped) return commit(coreUpdate(committed, { kind: "stamped", at: value }));
  if (tag === TAG_request_kill) return commit(coreUpdate(committed, { kind: "request_kill", pid: truncTowardZero(value) }));
  if (tag === TAG_copy_name) return commit(coreUpdate(committed, { kind: "copy_name", pid: truncTowardZero(value) }));
  trapUnknownTag("number", tag);
}

export function dispatch_number_bytes(tag: number, value: number, payload: Uint8Array): Uint8Array {
  if (tag === TAG_info_done) {
    return commit(coreUpdate(committed, { kind: "info_done", code: truncTowardZero(value), output: payload }));
  }
  if (tag === TAG_info2_done) {
    return commit(coreUpdate(committed, { kind: "info2_done", code: truncTowardZero(value), output: payload }));
  }
  if (tag === TAG_ps_done) {
    return commit(coreUpdate(committed, { kind: "ps_done", code: truncTowardZero(value), output: payload }));
  }
  if (tag === TAG_mem_done) {
    return commit(coreUpdate(committed, { kind: "mem_done", code: truncTowardZero(value), output: payload }));
  }
  if (tag === TAG_kill_done) {
    return commit(coreUpdate(committed, { kind: "kill_done", code: truncTowardZero(value), output: payload }));
  }
  trapUnknownTag("number-with-bytes", tag);
}

export function dispatch_bool(tag: number, value: number): Uint8Array {
  trapUnknownTag("boolean", tag);
}

export function dispatch_enum(tag: number, member: number): Uint8Array {
  trapUnknownTag("enum", tag);
}

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
  if (tag === TAG_table_scrolled) {
    assertConsumed(fields, 64);
    return commit(coreUpdate(committed, { kind: "table_scrolled", scroll: decodeScrollState(fields, 0) }));
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
  if (tag === TAG_table_scrolled) {
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
    return commit(coreUpdate(committed, { kind: "table_scrolled", scroll: scroll }));
  }
  trapUnknownTag("scroll-state", tag);
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

const samplerPhases = ["probing", "ready", "unsupported"];
const memCommands = ["vmstat", "meminfo"];
const sortKeys = ["cpu", "mem", "pid", "name"];

function wEnum(sink: Sink, members: string[], value: string): void {
  for (let i = 0; i < members.length; i++) {
    if (members[i] === value) {
      wU32(sink, i);
      return;
    }
  }
  trap("a model enum slot carries an undeclared member — the author module and this adapter disagree");
}

function wNumbers(sink: Sink, values: number[]): void {
  wU32(sink, values.length);
  for (let i = 0; i < values.length; i++) {
    wF64(sink, values[i]!);
  }
}

export function model_snapshot(): Uint8Array {
  const sink = newSink();
  const model = committed;
  wEnum(sink, samplerPhases, model.phase);
  wEnum(sink, memCommands, model.memCommand);
  wBool(sink, model.paused);
  wF64(sink, model.ticksSkipped);
  wBool(sink, model.psInflight);
  wBool(sink, model.memInflight);
  wF64(sink, model.samplesTaken);
  wF64(sink, model.sampledAtDayMs);
  wF64(sink, model.cores);
  wF64(sink, model.memTotalBytes);
  wF64(sink, model.cpuPercentTenths);
  wF64(sink, model.memUsedBytes);
  wF64(sink, model.processCount);
  wF64(sink, model.uptimeSeconds);
  wU32(sink, model.rows.length);
  for (let i = 0; i < model.rows.length; i++) {
    const row = model.rows[i]!;
    wF64(sink, row.pid);
    wF64(sink, row.cpuTenths);
    wF64(sink, row.memTenths);
    wF64(sink, row.rssKb);
    wBytes(sink, row.name);
  }
  wF64(sink, model.parseFailures);
  wNumbers(sink, model.cpuHistory as number[]);
  wNumbers(sink, model.memHistory as number[]);
  wNumbers(sink, model.procHistory as number[]);
  wBytes(sink, model.search.bytes);
  wF64(sink, model.search.anchor);
  wF64(sink, model.search.focus);
  wF64(sink, model.search.compStart);
  wF64(sink, model.search.compEnd);
  wEnum(sink, sortKeys, model.sortKey);
  wBool(sink, model.sortDescending);
  const pending = model.pendingKill;
  if (pending === null) {
    wBool(sink, false);
  } else {
    wBool(sink, true);
    wF64(sink, pending.pid);
    wBytes(sink, pending.name);
  }
  wF64(sink, model.tableScroll);
  wBytes(sink, model.note);
  wBool(sink, model.noteClearsOnSample);
  wF64(sink, model.sampleGeneration);
  wF64(sink, model.noteStampGeneration);
  wF64(sink, model.chromeLeading);
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

function numbersResult(values: number[]): Uint8Array {
  const sink = newSink();
  wNumbers(sink, values);
  return finish(sink);
}

function tableRowsResult(rows: TableRow[]): Uint8Array {
  const sink = newSink();
  wU32(sink, rows.length);
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i]!;
    wF64(sink, row.pid);
    wBytes(sink, row.pidText);
    wBytes(sink, row.name);
    wBytes(sink, row.cpuText);
    wBytes(sink, row.memText);
    wBytes(sink, row.rowLabel);
  }
  return finish(sink);
}

export function helper_call(helper: number, args: Uint8Array): Uint8Array {
  assertConsumed(args, 0);
  if (helper === 0) return bytesResult(h_headerStatus(committed));
  if (helper === 1) return bytesResult(h_cpuValue(committed));
  if (helper === 2) return bytesResult(h_cpuDetail(committed));
  if (helper === 3) return bytesResult(h_memValue(committed));
  if (helper === 4) return bytesResult(h_memDetail(committed));
  if (helper === 5) return bytesResult(h_procValue(committed));
  if (helper === 6) return bytesResult(h_uptimeValue(committed));
  if (helper === 7) return numbersResult(h_cpuSpark(committed) as number[]);
  if (helper === 8) return numbersResult(h_memSpark(committed) as number[]);
  if (helper === 9) return numbersResult(h_procSpark(committed) as number[]);
  if (helper === 10) return bytesResult(h_pauseLabel(committed));
  if (helper === 11) return bytesResult(h_pauseIcon(committed));
  if (helper === 12) return bytesResult(h_searchText(committed));
  if (helper === 13) return bytesResult(h_sortDirectionIcon(committed));
  if (helper === 14) return bytesResult(h_sortDirectionLabel(committed));
  if (helper === 15) return tableRowsResult(h_visibleRows(committed) as TableRow[]);
  if (helper === 16) return numberResult(h_matchCount(committed));
  if (helper === 17) return numberResult(h_shownCount(committed));
  if (helper === 18) return bytesResult(h_emptyTitle(committed));
  if (helper === 19) return bytesResult(h_emptyHint(committed));
  if (helper === 20) return bytesResult(h_statusLine(committed));
  if (helper === 21) return boolResult(h_confirmingKill(committed));
  if (helper === 22) return bytesResult(h_killPrompt(committed));
  trap("helper index " + helper + " does not name an exported model helper of this core — the host and this core disagree about the contract");
}

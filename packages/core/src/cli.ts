#!/usr/bin/env node
// @native-sdk/core: transpile an app-core subset TypeScript module to Zig.
//
//   native-core <entry.ts> -o <out.zig> [--frame-cap <bytes>] [--heap-cap <bytes>]
//               [--contract <out.contract.json>] [--contract-entry <spelling>]
//
// --frame-cap / --heap-cap set the emitted core's rt kernel capacities (the
// frame arena and the per-space model heap) as comptime constants; omitted,
// the rt defaults apply.
//
// --contract also writes the contract sidecar (core.contract.json, schema
// format 1) emitted directly from the checked program — the document an
// external core toolchain's projections consume. --contract-entry sets the
// entry spelling the document states (default: the entry argument as
// given, POSIX separators); the transpile still runs in full, so every
// transpile-time teaching gates the contract too.
//
// Exit codes: 0 emitted; 1 subset/type errors (teaching diagnostics on
// stderr); 2 usage.

import { transpileFile, formatDiagnostic, type TranspileOptions } from "./transpile.ts";
import fs from "node:fs";

function parseByteCount(flag: string, raw: string | undefined): number | null {
  const v = raw === undefined ? NaN : Number(raw);
  if (!Number.isSafeInteger(v) || v <= 0) {
    console.error(`${flag} needs a positive integer byte count, got ${raw ?? "<missing>"}`);
    return null;
  }
  return v;
}

function main(argv: string[]): number {
  const args = argv.slice(2);
  let entry: string | null = null;
  let out: string | null = null;
  let contractOut: string | null = null;
  let contractEntry: string | null = null;
  let frameCap: number | undefined;
  let heapCap: number | undefined;
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "-o" || args[i] === "--out") {
      out = args[++i] ?? null;
    } else if (args[i] === "--contract") {
      contractOut = args[++i] ?? null;
    } else if (args[i] === "--contract-entry") {
      contractEntry = args[++i] ?? null;
    } else if (args[i] === "--frame-cap") {
      const v = parseByteCount("--frame-cap", args[++i]);
      if (v === null) return 2;
      frameCap = v;
    } else if (args[i] === "--heap-cap") {
      const v = parseByteCount("--heap-cap", args[++i]);
      if (v === null) return 2;
      heapCap = v;
    } else if (!args[i].startsWith("-")) {
      entry = args[i];
    } else {
      console.error(`unknown flag ${args[i]}`);
      return 2;
    }
  }
  if (!entry) {
    console.error(
      "usage: native-core <entry.ts> -o <out.zig> [--frame-cap <bytes>] [--heap-cap <bytes>] [--contract <out.contract.json>] [--contract-entry <spelling>]",
    );
    return 2;
  }
  const options: TranspileOptions = {
    frameCap,
    heapCap,
    // The document's entry spelling defaults to the argument's own,
    // POSIX separators (the sidecar/facade contract is platform-free).
    contractEntry: contractOut !== null ? (contractEntry ?? entry.split("\\").join("/")) : undefined,
  };
  const result = transpileFile(entry, options);
  for (const e of result.typeErrors) console.error(e);
  for (const d of result.diagnostics) console.error(formatDiagnostic(d));
  // Teaching notices (NS1028): printed, never failing the build.
  for (const w of result.warnings) console.error(formatDiagnostic(w, "warning"));
  if (!result.ok || result.zig === null) return 1;
  if (contractOut !== null) {
    if (result.contract === null) {
      console.error("internal: the transpile produced no contract sidecar");
      return 1;
    }
    fs.writeFileSync(contractOut, result.contract);
  }
  if (out) {
    fs.writeFileSync(out, result.zig);
  } else {
    process.stdout.write(result.zig);
  }
  return 0;
}

process.exit(main(process.argv));

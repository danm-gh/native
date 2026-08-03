#!/usr/bin/env node
// Contract-equivalence pin: hold the frontend-emitted contract sidecar
// byte-identical to the extraction-path document (tools/corewire/
// extract.zig over the transpiled module). Byte equality is the pin —
// the two producers construct the same document by design, identity
// hashes included; on divergence the report walks the parsed trees and
// names the first differing path so the drift reads as a fact, not a
// wall of JSON.
//
//   node contract_diff.mjs <extracted.contract.json> <frontend.contract.json>

import fs from "node:fs";

function walk(a, b, path, report) {
  if (report.length >= 20) return;
  if (typeof a !== typeof b) {
    report.push(`${path}: ${typeof a} vs ${typeof b}`);
    return;
  }
  if (a === null || b === null || typeof a !== "object") {
    if (a !== b) report.push(`${path}: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`);
    return;
  }
  if (Array.isArray(a) !== Array.isArray(b)) {
    report.push(`${path}: array vs object`);
    return;
  }
  if (Array.isArray(a)) {
    if (a.length !== b.length) report.push(`${path}: length ${a.length} vs ${b.length}`);
    const n = Math.min(a.length, b.length);
    for (let i = 0; i < n; i++) walk(a[i], b[i], `${path}[${i}]`, report);
    return;
  }
  const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
  for (const k of keys) {
    if (!(k in a)) report.push(`${path}.${k}: only in the frontend document`);
    else if (!(k in b)) report.push(`${path}.${k}: only in the extracted document`);
    else walk(a[k], b[k], `${path}.${k}`, report);
  }
}

const [extractedPath, frontendPath] = process.argv.slice(2);
if (!extractedPath || !frontendPath) {
  console.error("usage: contract_diff.mjs <extracted.contract.json> <frontend.contract.json>");
  process.exit(2);
}
const extracted = fs.readFileSync(extractedPath, "utf8");
const frontend = fs.readFileSync(frontendPath, "utf8");
if (extracted === frontend) process.exit(0);

const report = [];
try {
  walk(JSON.parse(extracted), JSON.parse(frontend), "$", report);
} catch (e) {
  report.push(`unparseable document: ${e}`);
}
if (report.length === 0) report.push("byte-level difference only (formatting/ordering)");
console.error(`the frontend-emitted contract diverges from the extraction-path document (${extractedPath} vs ${frontendPath}):`);
for (const line of report) console.error(`  ${line}`);
process.exit(1);

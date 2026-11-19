#!/usr/bin/env node
/**
 * Harvest deduplicated Windows UIA `--compact` tree snapshots from live desktop apps
 * using `scripts/computer-control.mjs` (leverages warm zcc-worker for low latency).
 *
 * Usage:
 *   node training/scripts/capture-snapshots.mjs --once
 *   node training/scripts/capture-snapshots.mjs --watch --interval 2500 --duration 120
 *   node training/scripts/capture-snapshots.mjs --watch --app notepad
 */

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { appendFile, mkdir, readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const execFileAsync = promisify(execFile);
const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, "..", "..");
const CLI_ENTRY = resolve(REPO_ROOT, "scripts", "computer-control.mjs");
const DEFAULT_OUT = resolve(REPO_ROOT, "training", "data", "raw_snapshots.jsonl");

const DEFAULT_IGNORE_PROCESSES = new Set([
  "textinputhost",
  "applicationframehost",
  "shellexperiencehost",
  "startmenuexperiencehost",
  "searchhost",
  "lockapp",
  "program manager",
]);

function parseCli(argv) {
  const opts = {
    watch: false,
    intervalMs: 2500,
    durationSec: 0,
    minElements: 5,
    maxElements: 600,
    appFilter: null,
    foregroundOnly: false,
    out: DEFAULT_OUT,
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--watch") opts.watch = true;
    else if (arg === "--once") opts.watch = false;
    else if (arg === "--foreground-only") opts.foregroundOnly = true;
    else if (arg === "--interval") opts.intervalMs = Number(argv[++i] ?? 2500);
    else if (arg === "--duration") opts.durationSec = Number(argv[++i] ?? 0);
    else if (arg === "--min-elements") opts.minElements = Number(argv[++i] ?? 5);
    else if (arg === "--max-elements") opts.maxElements = Number(argv[++i] ?? 600);
    else if (arg === "--app") opts.appFilter = String(argv[++i] ?? "").toLowerCase();
    else if (arg === "--out") opts.out = resolve(argv[++i]);
    else if (arg === "-h" || arg === "--help") {
      console.log(
        [
          "Usage: node training/scripts/capture-snapshots.mjs [options]",
          "  --once                Capture all open windows once (default)",
          "  --watch               Continuously poll while you browse menus/dialogs",
          "  --foreground-only     Only inspect the current foreground window",
          "  --interval <ms>       Poll interval in watch mode (default: 2500)",
          "  --duration <sec>      Auto-stop after N seconds in watch mode (0 = until Ctrl+C)",
          "  --min-elements <n>    Skip windows with fewer than N UIA elements (default: 5)",
          "  --max-elements <n>    Max UIA elements per snapshot (default: 600)",
          "  --app <substr>        Only capture windows matching process/title substring",
          "  --out <path>          Output JSONL path (default: training/data/raw_snapshots.jsonl)",
        ].join("\n"),
      );
      process.exit(0);
    }
  }
  return opts;
}

async function runCua(args) {
  try {
    const { stdout } = await execFileAsync(process.execPath, [CLI_ENTRY, ...args], {
      cwd: REPO_ROOT,
      maxBuffer: 16 * 1024 * 1024,
      windowsHide: true,
    });
    return JSON.parse(stdout);
  } catch (err) {
    if (err?.stdout) {
      try {
        return JSON.parse(err.stdout);
      } catch {
        // fall through
      }
    }
    return { ok: false, error: { code: "exec_error", message: String(err?.message ?? err) } };
  }
}

async function loadExistingKeys(outPath) {
  const seen = new Set();
  try {
    const text = await readFile(outPath, "utf8");
    for (const line of text.split(/\r?\n/)) {
      if (!line.trim()) continue;
      try {
        const rec = JSON.parse(line);
        if (rec.state_id) seen.add(`${rec.window?.process ?? ""}|${rec.state_id}`);
      } catch {
        // ignore malformed trailing lines
      }
    }
  } catch (err) {
    if (err?.code !== "ENOENT") throw err;
  }
  return seen;
}

async function capturePass(opts, seen) {
  const listRes = await runCua(["list-apps"]);
  if (!listRes.ok) {
    console.error(`[list-apps failed] ${listRes.error?.code}: ${listRes.error?.message}`);
    return { captured: 0, scanned: 0 };
  }
  const windows = listRes.result?.windows ?? [];
  let captured = 0;
  let scanned = 0;

  for (const w of windows) {
    if (opts.foregroundOnly && !w.foreground) continue;
    const proc = String(w.process ?? "").toLowerCase();
    const title = String(w.title ?? "");
    if (!title.trim() || DEFAULT_IGNORE_PROCESSES.has(proc)) continue;
    if (opts.appFilter && !proc.includes(opts.appFilter) && !title.toLowerCase().includes(opts.appFilter)) {
      continue;
    }

    scanned++;
    const stateRes = await runCua([
      "get-app-state",
      "--app",
      `hwnd:${w.hwnd}`,
      "--compact",
      "--max-elements",
      String(opts.maxElements),
    ]);
    if (!stateRes.ok) continue;

    const r = stateRes.result;
    const count = Number(r.element_count ?? 0);
    if (count < opts.minElements || !r.text || !r.state_id) continue;

    const dedupKey = `${proc}|${r.state_id}`;
    if (seen.has(dedupKey)) continue;
    seen.add(dedupKey);

    const record = {
      captured_at: new Date().toISOString(),
      state_id: r.state_id,
      element_count: count,
      truncated: Boolean(r.truncated),
      window: {
        hwnd: r.app?.hwnd ?? w.hwnd,
        pid: r.app?.pid ?? w.pid,
        process: r.app?.process ?? w.process,
        title: r.app?.title ?? w.title,
        class: r.app?.class ?? w.class,
        bounds: r.app?.bounds ?? w.bounds,
      },
      tree_text: r.text,
    };

    await mkdir(dirname(opts.out), { recursive: true });
    await appendFile(opts.out, JSON.stringify(record) + "\n", "utf8");
    captured++;
    console.log(
      `[+1] ${record.window.process} | "${record.window.title.slice(0, 48)}" | elements=${count} | state=${record.state_id.slice(0, 8)}`,
    );
  }
  return { captured, scanned };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  const opts = parseCli(process.argv.slice(2));
  const seen = await loadExistingKeys(opts.out);
  console.log(`Output: ${opts.out} (existing unique snapshots: ${seen.size})`);

  if (!opts.watch) {
    const { captured, scanned } = await capturePass(opts, seen);
    console.log(`Done. Scanned ${scanned} windows, saved ${captured} new snapshots (total: ${seen.size}).`);
    return;
  }

  const deadline = opts.durationSec > 0 ? Date.now() + opts.durationSec * 1000 : Infinity;
  let totalNew = 0;
  console.log(`Watch mode active (interval=${opts.intervalMs}ms). Open/click through office apps & dialogs; press Ctrl+C to stop.`);

  let stopping = false;
  process.on("SIGINT", () => {
    stopping = true;
  });

  while (!stopping && Date.now() < deadline) {
    const { captured } = await capturePass(opts, seen);
    totalNew += captured;
    if (!stopping && Date.now() < deadline) {
      await sleep(opts.intervalMs);
    }
  }
  console.log(`Watch stopped. Saved ${totalNew} new snapshots (total unique: ${seen.size}).`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

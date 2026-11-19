// DSH Computer Use - CLI entry: argument parsing, command contract validation,
// platform dispatch, JSON envelope output.
import { probePlatform } from "./platform.mjs";
import { runWindowsCommand } from "./windows.mjs";
import { runMacCommand } from "./macos.mjs";
import { runLinuxCommand } from "./linux.mjs";

/**
 * Command contract. Every flag declares its type and whether it is required;
 * input validation happens before any backend call, so an invalid request can
 * never produce a side effect.
 *
 * Freshness flags (state-id / element-path / expect-change) and verification
 * flags (wait-for / wait-gone / wait-timeout) are shared by every mutating
 * command so the model learns one rule, not eight.
 */
const FRESHNESS_FLAGS = {
  "state-id": { type: "string" },
  "element-path": { type: "string" },
  "expect-change": { type: "bool" },
};

const WAIT_FLAGS = {
  "wait-for": { type: "string" },
  "wait-gone": { type: "string" },
  "wait-timeout": { type: "int", min: 100, max: 120_000 },
};

export const COMMAND_SPECS = {
  status: { flags: {}, mutating: false, summary: "Probe platform backend and capabilities" },
  "stop-worker": { flags: {}, mutating: false, summary: "Stop any warm Windows background worker process" },
  "list-apps": {
    flags: { all: { type: "bool" } },
    mutating: false,
    summary: "Enumerate controllable desktop windows (foreground first, z-order)",
  },
  "list-windows": {
    flags: { app: { type: "string", required: true }, all: { type: "bool" } },
    mutating: false,
    summary: "List the windows of one application",
  },
  "get-app-state": {
    flags: {
      app: { type: "string", required: true },
      "max-elements": { type: "int", min: 100, max: 5000 },
      compact: { type: "bool" },
      "scope-element": { type: "int" },
      "scope-path": { type: "string" },
    },
    mutating: false,
    summary: "Read the accessibility tree (index + path action targets) and cache it",
  },
  find: {
    flags: {
      app: { type: "string", required: true },
      role: { type: "string" },
      name: { type: "string" },
      "name-exact": { type: "bool" },
      value: { type: "string" },
      limit: { type: "int", min: 1, max: 500 },
      "use-cache": { type: "bool" },
      "max-age": { type: "int", min: 0, max: 600_000 },
    },
    mutating: false,
    summary: "Search elements by role/name/value without reading the whole tree",
  },
  wait: {
    flags: {
      app: { type: "string", required: true },
      for: { type: "string" },
      gone: { type: "string" },
      timeout: { type: "int", min: 100, max: 120_000 },
      interval: { type: "int", min: 50, max: 5000 },
    },
    mutating: false,
    summary: "Poll until a UI condition appears (--for) or disappears (--gone)",
  },
  screenshot: {
    flags: {
      app: { type: "string" },
      screen: { type: "bool" },
      element: { type: "int" },
      "element-path": { type: "string" },
      out: { type: "string" },
      inline: { type: "bool" },
      annotate: { type: "bool" },
      // bare --grid uses the default cell size (100); --grid 200 overrides it
      grid: { type: "int", min: 20, max: 500, defaultWhenBare: 100 },
    },
    mutating: false,
    summary: "Screenshot (window/element/screen) with optional --annotate / --grid",
  },
  focus: {
    flags: { app: { type: "string", required: true } },
    mutating: true,
    summary: "Bring the application window to the foreground",
  },
  click: {
    flags: {
      app: { type: "string", required: true },
      element: { type: "int" },
      ...FRESHNESS_FLAGS,
      x: { type: "int" },
      y: { type: "int" },
      button: { type: "enum", values: ["left", "right", "middle"] },
      double: { type: "bool" },
      ...WAIT_FLAGS,
    },
    mutating: true,
    summary: "Click an element (semantic first) or a screen coordinate, then optionally verify",
  },
  type: {
    flags: {
      app: { type: "string", required: true },
      text: { type: "string", required: true },
      element: { type: "int" },
      ...FRESHNESS_FLAGS,
      submit: { type: "bool" },
      "keep-clipboard": { type: "bool" },
      ...WAIT_FLAGS,
    },
    mutating: true,
    summary: "Type text (optional element focus, --submit Enter), clipboard preserved",
  },
  keypress: {
    flags: {
      app: { type: "string", required: true },
      keys: { type: "string", required: true },
      element: { type: "int" },
      ...FRESHNESS_FLAGS,
      ...WAIT_FLAGS,
    },
    mutating: true,
    summary: 'Send keys, e.g. "ctrl+s", "ctrl,shift,p", "down,enter"',
  },
  scroll: {
    flags: {
      app: { type: "string", required: true },
      direction: { type: "enum", values: ["up", "down", "left", "right"] },
      amount: { type: "int", min: 1, max: 20 },
      element: { type: "int" },
      ...FRESHNESS_FLAGS,
      x: { type: "int" },
      y: { type: "int" },
      ...WAIT_FLAGS,
    },
    mutating: true,
    summary: "Scroll an element (ScrollPattern first) or a coordinate",
  },
  drag: {
    flags: {
      app: { type: "string", required: true },
      path: { type: "string", required: true },
    },
    mutating: true,
    summary: 'Drag along a screen-pixel path "x1,y1>x2,y2>x3,y3"',
  },
  move: {
    flags: {
      app: { type: "string", required: true },
      element: { type: "int" },
      ...FRESHNESS_FLAGS,
      x: { type: "int" },
      y: { type: "int" },
      ...WAIT_FLAGS,
    },
    mutating: true,
    summary: "Move the cursor to element/coordinate without clicking (hover)",
  },
  "set-value": {
    flags: {
      app: { type: "string", required: true },
      element: { type: "int" },
      ...FRESHNESS_FLAGS,
      text: { type: "string", required: true },
      ...WAIT_FLAGS,
    },
    mutating: true,
    summary: "Set an edit's value via ValuePattern (no keystrokes, no focus steal)",
  },
};

const GLOBAL_FLAGS = ["pretty", "timeout", "help"];

const ALL_FLAG_NAMES = new Set(GLOBAL_FLAGS);
for (const spec of Object.values(COMMAND_SPECS)) {
  for (const name of Object.keys(spec.flags)) ALL_FLAG_NAMES.add(name);
}

class UsageError extends Error {
  constructor(message) {
    super(message);
    this.name = "UsageError";
    this.code = "invalid_arguments";
  }
}

export function parseArgs(argv) {
  const args = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (token === "--help" || token === "-h") {
      args.help = true;
      continue;
    }
    if (token === "--") {
      args._.push(...argv.slice(i + 1));
      break;
    }
    if (token.startsWith("--")) {
      const body = token.slice(2);
      const eq = body.indexOf("=");
      if (eq >= 0) {
        args[body.slice(0, eq)] = body.slice(eq + 1);
        continue;
      }
      const next = argv[i + 1];
      // A value that happens to start with "--" (e.g. --text "--flag") is a
      // value unless it is a flag this CLI actually knows.
      const nextLooksLikeFlag =
        next !== undefined && next.startsWith("--") && ALL_FLAG_NAMES.has(next.slice(2).split("=")[0]);
      if (next === undefined || nextLooksLikeFlag) {
        args[body] = true; // boolean flag
        continue;
      }
      args[body] = next;
      i += 1;
      continue;
    }
    args._.push(token);
  }
  return args;
}

export function coerceFlags(command, raw) {
  const spec = COMMAND_SPECS[command];
  const params = {};
  for (const name of Object.keys(raw)) {
    if (name === "_") continue;
    if (spec.flags[name]) continue; // coerced below
    if (GLOBAL_FLAGS.includes(name)) continue; // --pretty / --timeout / --help
    throw new UsageError(`unknown flag --${name} for '${command}'. Run with --help.`);
  }
  for (const [name, rule] of Object.entries(spec.flags)) {
    const value = raw[name];
    if (value === undefined || value === true) {
      if (rule.required) throw new UsageError(`${command} requires --${name}`);
      if (rule.type === "bool") params[name] = Boolean(value);
      // A bare value-taking flag (e.g. `--grid` with no number) falls back to
      // its declared default; without this it would be silently dropped.
      if (rule.type === "int" && value === true && rule.defaultWhenBare !== undefined) {
        params[name] = rule.defaultWhenBare;
      }
      continue;
    }
    switch (rule.type) {
      case "int": {
        const parsed = Number.parseInt(String(value), 10);
        if (!Number.isInteger(parsed)) {
          throw new UsageError(`--${name} expects an integer, got '${value}'`);
        }
        if (rule.min !== undefined && parsed < rule.min) {
          throw new UsageError(`--${name} must be >= ${rule.min}`);
        }
        if (rule.max !== undefined && parsed > rule.max) {
          throw new UsageError(`--${name} must be <= ${rule.max}`);
        }
        params[name] = parsed;
        break;
      }
      case "bool":
        params[name] = value === true || value === "true" || value === "1";
        break;
      case "enum":
        if (!rule.values.includes(String(value))) {
          throw new UsageError(`--${name} must be one of: ${rule.values.join(", ")}`);
        }
        params[name] = String(value);
        break;
      default:
        params[name] = String(value);
    }
  }
  return params;
}

/**
 * Cross-flag rules. These run before the backend so a contradictory request is
 * rejected without touching the desktop.
 */
export function validateCommand(command, params) {
  if (params.element !== undefined && params["element-path"] !== undefined) {
    throw new UsageError("provide either --element N or --element-path P, not both");
  }
  if (params["wait-for"] !== undefined && params["wait-gone"] !== undefined) {
    throw new UsageError("provide either --wait-for or --wait-gone, not both");
  }
  if (command === "get-app-state") {
    if (params["scope-element"] !== undefined && params["scope-path"] !== undefined) {
      throw new UsageError("provide either --scope-element N or --scope-path P, not both");
    }
  }
  if (command === "wait") {
    if (params.for !== undefined && params.gone !== undefined) {
      throw new UsageError("wait takes exactly one of --for or --gone");
    }
    if (params.for === undefined && params.gone === undefined) {
      throw new UsageError("wait requires --for <spec> or --gone <spec>");
    }
  }
  if (command === "find" && !params.role && !params.name && !params.value) {
    throw new UsageError("find requires at least one of --role, --name, --value");
  }
  if (command === "screenshot") {
    if (!params.app && !params.screen) throw new UsageError("screenshot requires --app or --screen");
    if (params.app && params.screen) throw new UsageError("provide either --app or --screen, not both");
    if (params.annotate && !params.app) throw new UsageError("--annotate requires --app");
  }
  if (command === "click" || command === "move") {
    const byElement = params.element !== undefined || params["element-path"] !== undefined;
    const byPoint = params.x !== undefined || params.y !== undefined;
    if (byElement && byPoint) throw new UsageError("provide either an element target or --x/--y, not both");
    if (!byElement && !byPoint) throw new UsageError(`${command} requires an element target or --x/--y`);
    if (byPoint && (params.x === undefined || params.y === undefined)) {
      throw new UsageError("--x and --y must be provided together");
    }
  }
  if (command === "scroll") {
    if ((params.x !== undefined) !== (params.y !== undefined)) {
      throw new UsageError("--x and --y must be provided together");
    }
  }
  if (command === "set-value" && params.element === undefined && params["element-path"] === undefined) {
    throw new UsageError("set-value requires --element N or --element-path P");
  }
}

function emit(envelope, { pretty }) {
  process.stdout.write(`${JSON.stringify(envelope, null, pretty ? 2 : 0)}\n`);
}

function emitError(command, code, message, { pretty, result }) {
  const envelope = { ok: false, command, platform: process.platform, error: { code, message } };
  // Actions that were sent but failed verification still report what happened,
  // so the caller can judge the partially-finished work instead of guessing.
  if (result !== undefined) {
    envelope.action_sent = true;
    envelope.result = result;
  }
  emit(envelope, { pretty });
  // Usage-level failures (bad/missing args, unknown command) exit 2; backend
  // failures exit 1. Callers can branch on the exit code without parsing text.
  process.exitCode = code === "invalid_arguments" || code === "unknown_command" ? 2 : 1;
}

function helpText() {
  const lines = ["dsh-computer-use - desktop GUI control for agents", "", "Usage: computer-control.mjs <command> [options]", "", "Commands:"];
  for (const [name, spec] of Object.entries(COMMAND_SPECS)) {
    const flags = Object.entries(spec.flags)
      .map(([flag, rule]) => `--${flag}${rule.required ? "*" : ""}`)
      .join(" ");
    lines.push(`  ${name.padEnd(15)} ${spec.summary}${flags ? `  [${flags}]` : ""}`);
  }
  lines.push(
    "",
    "Global options: --pretty; --timeout <ms>; --help",
    "",
    "App selector --app: pid:<n> | hwnd:<n> | name:<process substring> | title:<window title substring>",
    "Element target: --element N (index from get-app-state) or --element-path P (e.g. 0.2.1)",
    "Freshness: --state-id <id> rejects actions against a newer snapshot (stale_state)",
    "Verification: --wait-for 'role:button,name:Save' / --wait-gone ... / --expect-change",
  );
  return lines.join("\n");
}

export function backendTimeout(command, params, override) {
  if (override) return override;
  const mutating = COMMAND_SPECS[command]?.mutating;
  const base = mutating ? 60_000 : command === "get-app-state" || command === "find" ? 45_000 : 30_000;
  if (command === "wait") return Math.max(base, (params.timeout ?? 5000) + 15_000);
  const waiting = params["wait-for"] !== undefined || params["wait-gone"] !== undefined;
  if (!waiting) return base;
  return Math.max(base, (params["wait-timeout"] ?? 5000) + 20_000);
}

export async function main(argv) {
  const raw = parseArgs(argv);
  const pretty = Boolean(raw.pretty);
  if (raw.help || raw._.length === 0) {
    process.stdout.write(`${helpText()}\n`);
    return;
  }
  const command = raw._[0];
  const spec = COMMAND_SPECS[command];
  if (!spec) {
    emitError(command, "unknown_command", `unknown command '${command}'. Run with --help.`, { pretty });
    return;
  }

  let params;
  try {
    params = coerceFlags(command, raw);
    validateCommand(command, params);
  } catch (error) {
    if (error instanceof UsageError) {
      emitError(command, error.code, error.message, { pretty });
      return;
    }
    throw error;
  }

  const probe = await probePlatform();
  if (!probe.available) {
    emitError(
      command,
      "unsupported_platform",
      `platform ${probe.platform} is not available for computer control: ${probe.notes}`,
      { pretty },
    );
    return;
  }
  if (probe.capabilities.length > 0 && !probe.capabilities.includes(command)) {
    emitError(
      command,
      "capability_unavailable",
      `command '${command}' is not available on ${probe.platform} backend (${probe.backend}). Available: ${probe.capabilities.join(", ")}`,
      { pretty },
    );
    return;
  }
  // Freshness and verification are Windows-backend features. Accepting the
  // flags elsewhere and silently ignoring them would make the model believe it
  // got a guarantee it never had.
  if (probe.platform !== "win32") {
    const windowsOnly = [
      "state-id",
      "element-path",
      "wait-for",
      "wait-gone",
      "wait-timeout",
      "expect-change",
      "compact",
      "scope-element",
      "scope-path",
    ];
    const used = windowsOnly.filter((flag) => params[flag] !== undefined && params[flag] !== false);
    if (used.length > 0) {
      emitError(
        command,
        "capability_unavailable",
        `--${used.join(", --")} require the Windows backend; on ${probe.platform} target elements by index and verify with get-app-state/screenshot`,
        { pretty },
      );
      return;
    }
    if (probe.platform === "darwin" && command === "scroll" && (params.direction === "left" || params.direction === "right")) {
      emitError(
        command,
        "capability_unavailable",
        `scroll --direction ${params.direction} is not supported on macOS backend`,
        { pretty },
      );
      return;
    }
  }

  const timeoutMs = backendTimeout(
    command,
    params,
    // `wait --timeout` is a command flag, not the global execution override;
    // only commands that do not declare their own --timeout honour the global.
    spec.flags.timeout ? undefined : raw.timeout ? Number.parseInt(String(raw.timeout), 10) : undefined,
  );
  try {
    const envelope =
      probe.platform === "win32"
        ? await runWindowsCommand(command, params, { timeoutMs })
        : probe.platform === "darwin"
          ? await runMacCommand(command, params, { timeoutMs })
          : await runLinuxCommand(command, params, { timeoutMs });
    emit(envelope, { pretty });
  } catch (error) {
    emitError(command, error.code ?? "backend_error", error.message, { pretty, result: error.result });
  }
}
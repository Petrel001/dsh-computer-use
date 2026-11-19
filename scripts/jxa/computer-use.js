// DSH Computer Use - macOS JXA 后端脚本（由 lib/macos.mjs 通过 osascript -l JavaScript 调用）。
// 用法: osascript -l JavaScript computer-use.js <command> <paramsFile> <outFile>
// 只向 outFile 写入一个 JSON 信封（文件通道，避免管道 stdio 在受限沙箱下不可用）。
ObjC.import("Foundation");

const OUT_FILE = argv[2];

function writeOut(text) {
  const app = Application.currentApplication();
  app.includeStandardAdditions = true;
  app.write(text, { to: Path(OUT_FILE) });
}

function readParams(path) {
  const app = Application.currentApplication();
  app.includeStandardAdditions = true;
  return JSON.parse(app.read(Path(path)));
}

function emitOk(command, result, actionSent) {
  const envelope = { ok: true, command: command, platform: "darwin", action_sent: Boolean(actionSent), result: result };
  writeOut(JSON.stringify(envelope));
}

function emitError(command, code, message) {
  writeOut(JSON.stringify({ ok: false, command: command, platform: "darwin", error: { code: code, message: message } }));
}

const SystemEvents = Application("System Events");

function listProcesses() {
  return SystemEvents.processes.whose({ backgroundOnly: false })();
}

function resolveProcess(selector) {
  const kind = selector.kind;
  const value = String(selector.value || "");
  if (kind === "pid") {
    const pid = parseInt(value, 10);
    const found = listProcesses().filter((p) => p.unixId() === pid);
    if (found.length === 0) throw new Error("no process with pid " + pid);
    return found[0];
  }
  if (kind === "name") {
    const found = listProcesses().filter((p) => p.name().toLowerCase().includes(value.toLowerCase()));
    if (found.length === 0) throw new Error("no process matches name '" + value + "'");
    if (found.length > 1) throw new Error("selector name '" + value + "' matches " + found.length + " processes: " + found.map((p) => p.name()).join(", "));
    return found[0];
  }
  // title：窗口标题匹配（未指定 pid/hwnd/name 时按窗口标题）
  const procs = listProcesses();
  const hits = [];
  for (const p of procs) {
    let wins = [];
    try { wins = p.windows(); } catch (e) { continue; }
    for (const w of wins) {
      const title = safe(() => w.name(), "");
      if (title && title.toLowerCase().includes(value.toLowerCase())) hits.push({ process: p, window: w, title: title });
    }
  }
  if (hits.length === 0) throw new Error("no window matches title '" + value + "'");
  if (hits.length > 1) throw new Error("selector title '" + value + "' matches " + hits.length + " windows: " + hits.map((h) => h.title).join("; "));
  return hits[0].process;
}

function safe(fn, fallback) {
  try { const v = fn(); return v === undefined || v === null ? fallback : v; } catch (e) { return fallback; }
}

function elementEntry(el, index, depth, parent) {
  const role = safe(() => el.role(), "unknown");
  const subrole = safe(() => el.subrole(), "");
  const name = safe(() => el.name(), "");
  const value = safe(() => el.value(), null);
  const enabled = safe(() => el.enabled(), true);
  const entry = { index: index, role: role, depth: depth, parent: parent, name: name, enabled: Boolean(enabled) };
  if (subrole) entry.subrole = subrole;
  if (value !== null && value !== undefined && typeof value !== "object") entry.value = String(value);
  const actions = safe(() => el.actions().map((a) => a.name()), []);
  if (actions.length > 0) entry.actions = actions;
  return entry;
}

const AX_INTERACTIVE_ROLES = [
  "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXComboBox",
  "AXList", "AXRow", "AXCell", "AXMenuButton", "AXMenuItem", "AXMenu", "AXMenuBar",
  "AXMenuBarItem", "AXTabGroup", "AXTab", "AXLink", "AXSlider", "AXIncrementor",
  "AXPopUpButton", "AXToolbar", "AXGroup", "AXWindow", "AXSheet", "AXDrawer", "AXStaticText",
];

function isCollectedElement(el) {
  const role = safe(() => el.role(), "unknown");
  if (AX_INTERACTIVE_ROLES.includes(role)) return true;
  const name = safe(() => el.name(), "");
  const subrole = safe(() => el.subrole(), "");
  return Boolean(name || subrole);
}

function walkTree(el, state, depth, parent, path) {
  if (state.count >= 2000 || depth > 40) { state.truncated = true; return; }
  let myParent = parent;
  if (isCollectedElement(el)) {
    const index = state.count;
    state.count += 1;
    const entry = elementEntry(el, index, depth, parent);
    entry.path = path;
    state.elements.push(entry);
    const indent = "  ".repeat(Math.min(depth, 20));
    state.lines.push(indent + "[" + index + "] " + entry.role + (entry.name ? ' "' + entry.name + '"' : "") + (entry.value ? " =" + entry.value : "") + (entry.enabled ? "" : " {disabled}"));
    myParent = index;
  }
  const children = safe(() => el.uiElements(), []);
  for (let i = 0; i < children.length; i += 1) {
    walkTree(children[i], state, depth + 1, myParent, path + "." + i);
  }
}

function commandStatus() {
  const procs = listProcesses();
  emitOk("status", {
    platform: "darwin",
    backend: "applescript-jxa",
    capabilities: ["list-apps", "list-windows", "get-app-state", "screenshot", "focus", "click", "type", "keypress", "scroll"],
    process_count: procs.length,
    notes: "需要「辅助功能」与「屏幕录制」权限。",
  });
}

function commandListApps() {
  const procs = listProcesses();
  const apps = [];
  for (const p of procs) {
    const wins = safe(() => p.windows(), []);
    apps.push({
      pid: p.unixId(),
      process: p.name(),
      window_count: wins.length,
      frontmost: safe(() => p.frontmost(), false),
    });
  }
  emitOk("list-apps", { apps: apps, count: apps.length, truncated: apps.length >= 200 });
}

function commandListWindows(params) {
  const proc = resolveProcess(parseSelectorLocal(params.app));
  const wins = safe(() => proc.windows(), []);
  const entries = wins.map((w, i) => ({
    index: i + 1,
    pid: proc.unixId(),
    process: proc.name(),
    title: safe(() => w.name(), ""),
    position: safe(() => w.position(), null),
    size: safe(() => w.size(), null),
  }));
  emitOk("list-windows", { windows: entries, count: entries.length });
}

function parseSelectorLocal(selector) {
  const raw = String(selector || "").trim();
  const m = raw.match(/^(pid|hwnd|name|title):(.*)$/s);
  return m ? { kind: m[1], value: m[2] } : { kind: "title", value: raw };
}

function commandGetAppState(params) {
  const proc = resolveProcess(parseSelectorLocal(params.app));
  const state = { elements: [], lines: [], count: 0, truncated: false };
  walkTree(proc, state, 0, -1, "0");
  emitOk("get-app-state", {
    app: { pid: proc.unixId(), process: proc.name(), frontmost: safe(() => proc.frontmost(), false) },
    state_id: hashString(state.lines.join("\n")),
    element_count: state.elements.length,
    truncated: state.truncated,
    text: state.lines.join("\n"),
    elements: state.elements,
  });
}

function hashString(text) {
  let h = 0;
  for (let i = 0; i < text.length; i += 1) { h = (h * 31 + text.charCodeAt(i)) | 0; }
  return (h >>> 0).toString(16);
}

function commandFocus(params) {
  const proc = resolveProcess(parseSelectorLocal(params.app));
  proc.frontmost = true;
  emitOk("focus", { pid: proc.unixId(), process: proc.name() }, true);
}

function findElement(proc, index) {
  const holder = { found: null, count: 0 };
  const rewalk = (el, depth) => {
    if (holder.found || holder.count >= 2000 || depth > 40) return;
    if (isCollectedElement(el)) {
      if (holder.count === index) { holder.found = el; return; }
      holder.count += 1;
    }
    const children = safe(() => el.uiElements(), []);
    for (const child of children) {
      rewalk(child, depth + 1);
      if (holder.found) return;
    }
  };
  rewalk(proc, 0);
  return holder.found;
}

function commandClick(params) {
  const proc = resolveProcess(parseSelectorLocal(params.app));
  if (params.element !== undefined && params.element !== null) {
    const el = findElement(proc, parseInt(params.element, 10));
    if (!el) throw new Error("no element with index " + params.element + "; re-run get-app-state");
    const pressAction = safe(() => el.actions().filter((a) => a.name() === "AXPress"), []);
    if (pressAction.length > 0) {
      pressAction[0].perform();
      emitOk("click", { pid: proc.unixId(), method: "ax-press", element: parseInt(params.element, 10) }, true);
    } else {
      const pos = safe(() => el.position(), null);
      const size = safe(() => el.size(), null);
      if (!pos || !size) throw new Error("element has no AXPress action and no bounds");
      const x = pos[0] + Math.floor(size[0] / 2);
      const y = pos[1] + Math.floor(size[1] / 2);
      SystemEvents.click({ at: [x, y] });
      emitOk("click", { pid: proc.unixId(), method: "coordinate", element: parseInt(params.element, 10), target: { x: x, y: y } }, true);
    }
  } else if (params.x !== undefined && params.y !== undefined) {
    SystemEvents.click({ at: [parseInt(params.x, 10), parseInt(params.y, 10)] });
    emitOk("click", { pid: proc.unixId(), method: "coordinate", target: { x: parseInt(params.x, 10), y: parseInt(params.y, 10) } }, true);
  } else {
    emitError("click", "invalid_arguments", "click requires --element or --x/--y");
  }
}

function commandType(params) {
  if (!params.text) { emitError("type", "invalid_arguments", "type requires --text"); return; }
  const proc = resolveProcess(parseSelectorLocal(params.app));
  proc.frontmost = true;
  delay(0.1);
  if (params.element !== undefined && params.element !== null) {
    const el = findElement(proc, parseInt(params.element, 10));
    if (el) safe(() => el.focused = true, null);
  }
  SystemEvents.keystroke(String(params.text));
  if (params.submit) { delay(0.1); SystemEvents.keyCode(36); }
  emitOk("type", { pid: proc.unixId(), length: String(params.text).length, submitted: Boolean(params.submit) }, true);
}

const KEY_CODES = {
  enter: 36, return: 36, tab: 48, esc: 53, escape: 53, space: 49, backspace: 51, delete: 117,
  up: 126, down: 125, left: 123, right: 124, home: 115, end: 119, pageup: 116, pagedown: 121,
  f1: 122, f2: 120, f3: 99, f4: 118, f5: 96, f6: 97, f7: 98, f8: 100, f9: 101, f10: 109, f11: 103, f12: 111,
};

function commandKeypress(params) {
  if (!params.keys) { emitError("keypress", "invalid_arguments", "keypress requires --keys"); return; }
  const proc = resolveProcess(parseSelectorLocal(params.app));
  proc.frontmost = true;
  const chords = String(params.keys).split(",").map((s) => s.trim()).filter((s) => s.length > 0);
  for (const chord of chords) {
    const parts = chord.split("+").map((s) => s.trim().toLowerCase());
    const modifiers = [];
    let mainKey = null;
    let mainCode = null;
    for (const part of parts) {
      if (part === "ctrl" || part === "control") modifiers.push("control down");
      else if (part === "alt" || part === "option") modifiers.push("option down");
      else if (part === "shift") modifiers.push("shift down");
      else if (part === "cmd" || part === "command") modifiers.push("command down");
      else if (KEY_CODES[part] !== undefined) mainCode = KEY_CODES[part];
      else if (part.length === 1) mainKey = part;
      else throw new Error("unknown key '" + part + "'");
    }
    const using = modifiers.length > 0 ? { using: modifiers.join(", ") } : {};
    if (mainKey !== null) SystemEvents.keystroke(mainKey, using);
    else if (mainCode !== null) SystemEvents.keyCode(mainCode, using);
    else throw new Error("chord '" + chord + "' has no main key");
    delay(0.05);
  }
  emitOk("keypress", { pid: proc.unixId(), keys: params.keys }, true);
}

function commandScroll(params) {
  const proc = resolveProcess(parseSelectorLocal(params.app));
  const direction = params.direction || "down";
  const amount = params.amount || 3;
  const code = direction === "up" ? 30 : 31; // AXScrollUp / AXScrollDown via keyCode
  proc.frontmost = true;
  for (let i = 0; i < amount; i += 1) { SystemEvents.keyCode(code); delay(0.03); }
  emitOk("scroll", { pid: proc.unixId(), direction: direction, amount: amount }, true);
}

function commandScreenshot(params) {
  if (!params.app && !params.screen) { emitError("screenshot", "invalid_arguments", "screenshot requires --app or --screen"); return; }
  const app = Application.currentApplication();
  app.includeStandardAdditions = true;
  let outPath = params.out;
  if (!outPath) {
    const stamp = new Date().toISOString().replace(/[-:T]/g, "").slice(0, 15);
    outPath = "/tmp/dsh-computer-use-" + stamp + "-" + Math.random().toString(16).slice(2, 10) + ".png";
  }
  let args;
  if (params.screen) {
    args = ["-x", outPath];
  } else {
    const proc = resolveProcess(parseSelectorLocal(params.app));
    const wins = safe(() => proc.windows(), []);
    if (wins.length === 0) { emitError("screenshot", "window_not_found", "process has no windows"); return; }
    const pos = safe(() => wins[0].position(), [0, 0]);
    const size = safe(() => wins[0].size(), [0, 0]);
    args = ["-x", "-R", pos[0] + "," + pos[1] + "," + size[0] + "," + size[1], outPath];
  }
  app.doShellScript("screencapture " + args.map((a) => "'" + a + "'").join(" "));
  const stat = app.doShellScript("stat -f%z " + outPath);
  emitOk("screenshot", { path: outPath, bytes: parseInt(stat, 10), capture: params.screen ? "screen" : "window" });
}

function run(argv) {
  const command = argv[0];
  const params = readParams(argv[1]);
  switch (command) {
    case "status": commandStatus(); break;
    case "list-apps": commandListApps(); break;
    case "list-windows": commandListWindows(params); break;
    case "get-app-state": commandGetAppState(params); break;
    case "focus": commandFocus(params); break;
    case "click": commandClick(params); break;
    case "type": commandType(params); break;
    case "keypress": commandKeypress(params); break;
    case "scroll": commandScroll(params); break;
    case "screenshot": commandScreenshot(params); break;
    default: emitError(command, "unknown_command", "JXA backend does not handle '" + command + "'");
  }
}

try {
  run(argv);
} catch (error) {
  emitError(typeof argv !== "undefined" && argv[0] ? argv[0] : "unknown", "backend_error", String(error && error.message ? error.message : error));
}

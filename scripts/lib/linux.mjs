// DSH Computer Use - Linux 后端（xdotool + wmctrl + ImageMagick/scrot/gnome-screenshot）。
// 能力范围：list-apps / list-windows / screenshot / focus / click / type / keypress / scroll / drag。
// get-app-state 不可用（无 AT-SPI 绑定）：用 screenshot 辅助定位，以坐标驱动。
// 输出走文件通道（见 runner.mjs 沙箱说明）。
import { commandExists, readTextFile, runShellToFile, runToFile, withOutputFile } from "./runner.mjs";
import { parseSelector } from "./platform.mjs";

function fail(command, code, message) {
  const error = new Error(message);
  error.code = code;
  throw error;
}

export function parseWmctrlLine(line) {
  // wmctrl -lp: 0x04400006  0 12345  hostname  Window Title
  const withPid = line.match(/^(0x[0-9a-fA-F]+)\s+(-?\d+)\s+(-?\d+)\s+(\S+)\s+(.*)$/);
  if (withPid) {
    return {
      wid: withPid[1],
      desktop: withPid[2],
      pid: Number.parseInt(withPid[3], 10),
      host: withPid[4],
      title: withPid[5],
    };
  }
  // Fallback for wmctrl -l without PID column
  const match = line.match(/^(0x[0-9a-fA-F]+)\s+(-?\d+)\s+(\S+)\s+(.*)$/);
  if (!match) return null;
  return { wid: match[1], desktop: match[2], pid: null, host: match[3], title: match[4] };
}

async function listWindows(params = {}) {
  return await withOutputFile(async (outFile) => {
    await runShellToFile("wmctrl -lp", outFile, { timeoutMs: 10_000 });
    const stdout = await readTextFile(outFile);
    const entries = [];
    const selector = params.app ? parseSelector(params.app) : null;
    for (const line of stdout.split("\n")) {
      if (!line.trim()) continue;
      const parsed = parseWmctrlLine(line);
      if (!parsed) continue;
      if (selector) {
        const val = String(selector.value ?? "").trim();
        if (selector.kind === "pid") {
          const wantPid = Number.parseInt(val, 10);
          if (!Number.isInteger(wantPid) || parsed.pid !== wantPid) continue;
        } else if (selector.kind === "hwnd") {
          const widNorm = parsed.wid.toLowerCase();
          const wantHex = val.startsWith("0x") ? val.toLowerCase() : `0x${Number.parseInt(val, 10).toString(16)}`;
          if (widNorm !== wantHex && Number.parseInt(parsed.wid, 16) !== Number.parseInt(val, 10)) continue;
        } else {
          const needle = val.toLowerCase();
          if (!parsed.title.toLowerCase().includes(needle)) continue;
        }
      }
      const entry = { wid: parsed.wid, desktop: parsed.desktop, title: parsed.title };
      if (parsed.pid !== null) entry.pid = parsed.pid;
      entries.push(entry);
    }
    return entries;
  });
}

async function resolveWid(command, params) {
  const entries = await listWindows(params);
  if (entries.length === 0) {
    fail(command, "window_not_found", `no window matches selector '${params.app}'`);
  }
  if (entries.length > 1) {
    fail(
      command,
      "window_ambiguous",
      `selector '${params.app}' matches ${entries.length} windows: ${entries.map((e) => e.title).join("; ")}`,
    );
  }
  return entries[0].wid;
}

async function firstAvailable(commands) {
  for (const command of commands) {
    if (await commandExists(command)) return command;
  }
  return null;
}

export async function runLinuxCommand(command, params = {}, options = {}) {
  const timeoutMs = options.timeoutMs ?? 45_000;
  let result = {};
  let actionSent = false;

  switch (command) {
    case "status": {
      result = {
        platform: "linux",
        backend: "xdotool+wmctrl",
        capabilities: await probeLinuxCapabilities(),
        notes: "Linux 后端不支持无障碍元素树（get-app-state 不可用），请用截图辅助定位。",
      };
      break;
    }
    case "list-apps":
    case "list-windows": {
      const entries = await listWindows(command === "list-windows" ? params : {});
      result = { windows: entries, count: entries.length, truncated: false };
      break;
    }
    case "focus": {
      const wid = await resolveWid(command, params);
      await runToFile("wmctrl", ["-i", "-a", wid], { timeoutMs });
      result = { wid };
      actionSent = true;
      break;
    }
    case "click": {
      const wid = await resolveWid(command, params);
      await runToFile("wmctrl", ["-i", "-a", wid], { timeoutMs: 10_000 });
      let x; let y;
      if (params.x !== undefined && params.y !== undefined) {
        x = Number(params.x); y = Number(params.y);
      } else {
        const geometry = await withOutputFile(async (outFile) => {
          await runShellToFile(`xdotool getwindowgeometry --shell ${wid}`, outFile, { timeoutMs: 10_000 });
          return await readTextFile(outFile);
        });
        const gx = /X=(-?\d+)/.exec(geometry);
        const gy = /Y=(-?\d+)/.exec(geometry);
        const gw = /WIDTH=(\d+)/.exec(geometry);
        const gh = /HEIGHT=(\d+)/.exec(geometry);
        if (!gx || !gy || !gw || !gh) fail("click", "window_not_found", "cannot read window geometry");
        x = Number(gx[1]) + Math.floor(Number(gw[1]) / 2);
        y = Number(gy[1]) + Math.floor(Number(gh[1]) / 2);
      }
      const button = params.button === "right" ? 3 : params.button === "middle" ? 2 : 1;
      await runToFile("xdotool", ["mousemove", String(x), String(y), "click", String(button)], { timeoutMs });
      result = { wid, target: { x, y }, button };
      actionSent = true;
      break;
    }
    case "type": {
      if (params.text === undefined) fail("type", "invalid_arguments", "type requires --text");
      await runToFile("xdotool", ["type", "--clearmodifiers", "--delay", "20", String(params.text)], { timeoutMs });
      result = { length: String(params.text).length };
      actionSent = true;
      break;
    }
    case "keypress": {
      if (!params.keys) fail("keypress", "invalid_arguments", "keypress requires --keys");
      const spec = String(params.keys)
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean)
        .map((chord) =>
          chord
            .split("+")
            .map((part) => {
              const lower = part.trim().toLowerCase();
              const aliases = { control: "ctrl", option: "alt", cmd: "super", command: "super", win: "super" };
              return aliases[lower] ?? lower;
            })
            .join("+"),
        )
        .join(" ");
      await runToFile("xdotool", ["key", "--clearmodifiers", spec], { timeoutMs });
      result = { keys: params.keys, xdotool: spec };
      actionSent = true;
      break;
    }
    case "scroll": {
      const direction = params.direction ?? "down";
      const amount = Number(params.amount ?? 3);
      const buttonMap = { up: 4, down: 5, left: 6, right: 7 };
      const button = buttonMap[direction] ?? 5;
      const args = [];
      if (params.x !== undefined && params.y !== undefined) {
        args.push("mousemove", String(params.x), String(params.y));
      }
      for (let i = 0; i < amount; i += 1) args.push("click", String(button));
      await runToFile("xdotool", args, { timeoutMs });
      result = { direction, amount };
      actionSent = true;
      break;
    }
    case "move": {
      let x;
      let y;
      if (params.x !== undefined && params.y !== undefined) {
        x = Number(params.x);
        y = Number(params.y);
      } else {
        // No element tree on Linux: move to the window center by default.
        const wid = await resolveWid(command, params);
        const geometry = await withOutputFile(async (outFile) => {
          await runShellToFile(`xdotool getwindowgeometry --shell ${wid}`, outFile, { timeoutMs: 10_000 });
          return await readTextFile(outFile);
        });
        const gx = /X=(-?\d+)/.exec(geometry);
        const gy = /Y=(-?\d+)/.exec(geometry);
        const gw = /WIDTH=(\d+)/.exec(geometry);
        const gh = /HEIGHT=(\d+)/.exec(geometry);
        if (!gx || !gy || !gw || !gh) fail("move", "window_not_found", "cannot read window geometry");
        x = Number(gx[1]) + Math.floor(Number(gw[1]) / 2);
        y = Number(gy[1]) + Math.floor(Number(gh[1]) / 2);
      }
      await runToFile("xdotool", ["mousemove", String(x), String(y)], { timeoutMs });
      result = { target: { x, y }, method: "coordinate" };
      actionSent = true;
      break;
    }
    case "drag": {
      if (!params.path) fail("drag", "invalid_arguments", 'drag requires --path "x1,y1>x2,y2"');
      const points = String(params.path)
        .split(">")
        .map((seg) => seg.trim().split(",").map((n) => Number(n.trim())));
      if (points.length < 2 || points.some((p) => p.length !== 2 || p.some((n) => !Number.isFinite(n)))) {
        fail("drag", "invalid_arguments", 'drag path must be "x1,y1>x2,y2[...]"');
      }
      const args = ["mousemove", String(points[0][0]), String(points[0][1]), "mousedown", "1"];
      for (let i = 1; i < points.length; i += 1) {
        args.push("mousemove", String(points[i][0]), String(points[i][1]));
      }
      args.push("mouseup", "1");
      await runToFile("xdotool", args, { timeoutMs });
      result = { points };
      actionSent = true;
      break;
    }
    case "screenshot": {
      const outPath = params.out ?? `/tmp/dsh-computer-use-${Date.now()}.png`;
      const shot = await firstAvailable(["import", "scrot", "gnome-screenshot"]);
      if (!shot) fail("screenshot", "capability_unavailable", "no screenshot tool found (import/scrot/gnome-screenshot)");
      if (params.screen) {
        if (shot === "import") await runToFile("import", ["-window", "root", outPath], { timeoutMs });
        else if (shot === "scrot") await runToFile("scrot", ["-z", outPath], { timeoutMs });
        else await runToFile("gnome-screenshot", ["-f", outPath], { timeoutMs });
        result = { path: outPath, capture: "screen" };
      } else {
        const wid = await resolveWid(command, params);
        if (shot === "import") await runToFile("import", ["-window", wid, outPath], { timeoutMs });
        else if (shot === "scrot") await runToFile("scrot", ["-z", "-u", outPath], { timeoutMs });
        else await runToFile("gnome-screenshot", ["-w", "-f", outPath], { timeoutMs });
        result = { path: outPath, capture: "window", wid };
      }
      break;
    }
    default: {
      fail(command, "unknown_command", `unknown command '${command}'`);
    }
  }

  return {
    ok: true,
    command,
    platform: "linux",
    action_sent: actionSent,
    result,
  };
}

async function probeLinuxCapabilities() {
  const tools = {
    xdotool: await commandExists("xdotool"),
    wmctrl: await commandExists("wmctrl"),
    import: await commandExists("import"),
    scrot: await commandExists("scrot"),
    "gnome-screenshot": await commandExists("gnome-screenshot"),
  };
  const capabilities = [
    "status",
    "list-apps",
    "list-windows",
    "focus",
    "click",
    "type",
    "keypress",
    "scroll",
    "move",
    "drag",
  ];
  if (tools.import || tools.scrot || tools["gnome-screenshot"]) capabilities.push("screenshot");
  return capabilities;
}

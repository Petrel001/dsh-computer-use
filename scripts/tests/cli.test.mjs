import test from "node:test";
import assert from "node:assert/strict";
import { backendTimeout, coerceFlags, parseArgs, validateCommand } from "../lib/cli.mjs";
import { parseBackendJson, parseSelector } from "../lib/platform.mjs";
import { parseWmctrlLine } from "../lib/linux.mjs";

test("parseArgs handles bare flags, equals syntax, and '--' values", () => {
  const parsed = parseArgs([
    "type",
    "--app",
    "title:Notepad",
    "--text",
    "--not-a-flag",
    "--submit",
  ]);
  assert.equal(parsed._[0], "type");
  assert.equal(parsed.app, "title:Notepad");
  assert.equal(parsed.text, "--not-a-flag");
  assert.equal(parsed.submit, true);

  const bareGrid = parseArgs(["screenshot", "--app", "hwnd:1", "--grid"]);
  assert.equal(bareGrid.grid, true);

  const eq = parseArgs(["click", "--app=pid:42", "--element=7"]);
  assert.equal(eq.app, "pid:42");
  assert.equal(eq.element, "7");
});

test("coerceFlags handles defaults, ranges, and new v0.3 flags", () => {
  const shot = coerceFlags("screenshot", parseArgs(["screenshot", "--app", "hwnd:1", "--grid"]));
  assert.equal(shot.grid, 100);

  const state = coerceFlags(
    "get-app-state",
    parseArgs(["get-app-state", "--app", "pid:12", "--compact", "--scope-path", "0.2"]),
  );
  assert.equal(state.compact, true);
  assert.equal(state["scope-path"], "0.2");

  const scr = coerceFlags(
    "scroll",
    parseArgs(["scroll", "--app", "pid:12", "--direction", "right", "--amount", "2"]),
  );
  assert.equal(scr.direction, "right");
  assert.equal(scr.amount, 2);

  assert.throws(
    () => coerceFlags("scroll", parseArgs(["scroll", "--app", "pid:12", "--direction", "diagonal"])),
    /must be one of/,
  );
  assert.throws(
    () => coerceFlags("screenshot", parseArgs(["screenshot", "--screen", "--grid", "5"])),
    /must be >= 20/,
  );
  assert.throws(
    () => coerceFlags("click", parseArgs(["click", "--app", "pid:1", "--wait-fro", "name:x"])),
    /unknown flag/,
  );
});

test("validateCommand enforces mutual exclusions and required combinations", () => {
  assert.throws(
    () =>
      validateCommand(
        "get-app-state",
        coerceFlags(
          "get-app-state",
          parseArgs(["get-app-state", "--app", "pid:1", "--scope-element", "2", "--scope-path", "0.1"]),
        ),
      ),
    /either --scope-element N or --scope-path P/,
  );

  assert.throws(
    () =>
      validateCommand(
        "scroll",
        coerceFlags("scroll", parseArgs(["scroll", "--app", "pid:1", "--y", "100"])),
      ),
    /--x and --y must be provided together/,
  );

  assert.throws(
    () =>
      validateCommand(
        "click",
        coerceFlags("click", parseArgs(["click", "--app", "pid:1", "--element", "1", "--x", "10", "--y", "20"])),
      ),
    /not both/,
  );

  assert.doesNotThrow(() =>
    validateCommand("stop-worker", coerceFlags("stop-worker", parseArgs(["stop-worker"]))),
  );
});

test("backendTimeout scales wait and verification timeouts", () => {
  assert.equal(backendTimeout("wait", { timeout: 25000 }, undefined), 40000);
  assert.equal(
    backendTimeout("click", { "wait-for": "name:ok", "wait-timeout": 50000 }, undefined),
    70000,
  );
  assert.equal(backendTimeout("status", {}, 1234), 1234);
});

test("parseSelector and parseBackendJson behave deterministically", () => {
  assert.deepEqual(parseSelector("pid:123"), { kind: "pid", value: "123" });
  assert.deepEqual(parseSelector("hwnd:456"), { kind: "hwnd", value: "456" });
  assert.deepEqual(parseSelector("name:notepad"), { kind: "name", value: "notepad" });
  assert.deepEqual(parseSelector("Untitled - Notepad"), { kind: "title", value: "Untitled - Notepad" });

  assert.deepEqual(parseBackendJson('{"ok":true}', "status"), { ok: true });
  assert.throws(() => parseBackendJson("", "status"), { code: "backend_error" });
  assert.throws(() => parseBackendJson("not-json", "status"), { code: "backend_error" });
});

test("parseWmctrlLine supports wmctrl -lp and legacy wmctrl -l", () => {
  assert.deepEqual(parseWmctrlLine("0x04400006  0 12345  myhost  My Editor Window"), {
    wid: "0x04400006",
    desktop: "0",
    pid: 12345,
    host: "myhost",
    title: "My Editor Window",
  });
  assert.deepEqual(parseWmctrlLine("0x04400006  0 myhost  Legacy Title"), {
    wid: "0x04400006",
    desktop: "0",
    pid: null,
    host: "myhost",
    title: "Legacy Title",
  });
  assert.equal(parseWmctrlLine("invalid"), null);
});

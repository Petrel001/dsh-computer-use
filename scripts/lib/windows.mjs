// DSH Computer Use - Windows backend: maps commands to PowerShell scripts.
// The PowerShell scripts only touch this machine's desktop; this module owns
// process orchestration, environment plumbing and envelope normalization.
// Output uses the file channel (see the sandbox note in runner.mjs): PowerShell
// writes the JSON envelope to -OutFile.
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { statSync } from "node:fs";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { homedir } from "node:os";
import { parseBackendJson, probePlatform } from "./platform.mjs";
import {
  RunnerError,
  readTextFile,
  runToFile,
  withOutputFile,
  withParamsFile,
} from "./runner.mjs";

const SCRIPTS_DIR = join(dirname(fileURLToPath(import.meta.url)), "..", "powershell");
const WORKER_SCRIPT = join(SCRIPTS_DIR, "zcc-worker.ps1");
const WORKER_FILES = [
  "zcc-common.ps1",
  "zcc-apps.ps1",
  "zcc-state.ps1",
  "zcc-action.ps1",
  "zcc-screen.ps1",
  "zcc-worker.ps1",
];

function computeWorkerVersion() {
  return WORKER_FILES.map((file) => {
    try {
      const st = statSync(join(SCRIPTS_DIR, file));
      return `${file}:${st.size}:${Math.trunc(st.mtimeMs)}`;
    } catch {
      return `${file}:0`;
    }
  }).join("|");
}

// command -> the PowerShell script that serves it. One script serves several
// commands.
const COMMAND_SCRIPTS = {
  status: "zcc-apps.ps1",
  "list-apps": "zcc-apps.ps1",
  "list-windows": "zcc-apps.ps1",
  "get-app-state": "zcc-state.ps1",
  find: "zcc-state.ps1",
  wait: "zcc-state.ps1",
  focus: "zcc-action.ps1",
  click: "zcc-action.ps1",
  type: "zcc-action.ps1",
  keypress: "zcc-action.ps1",
  scroll: "zcc-action.ps1",
  drag: "zcc-action.ps1",
  "set-value": "zcc-action.ps1",
  move: "zcc-action.ps1",
  screenshot: "zcc-screen.ps1",
};

const MUTATING_COMMANDS = new Set([
  "focus",
  "click",
  "type",
  "keypress",
  "scroll",
  "drag",
  "set-value",
  "move",
]);

// Windows PowerShell first (always present), PowerShell 7 as the fallback.
// There is deliberately no separate "which shell exists" probe run before every
// command: that cost a full process launch per call. A spawn failure is
// unambiguous, so we just retry the next candidate on ENOENT.
const POWERSHELL_CANDIDATES = ["powershell.exe", "pwsh.exe"];

/**
 * State cache location shared by get-app-state and later actions. Node decides
 * it (not PowerShell) so both agree even when the scripts run with a different
 * profile environment.
 */
function defaultStateDir() {
  if (process.env.CUA_STATE_DIR) return process.env.CUA_STATE_DIR;
  const base = process.env.LOCALAPPDATA;
  if (base) return join(base, "dsh-computer-use", "state");
  return join(homedir(), ".cache", "dsh-computer-use", "state");
}

function unwrapEnvelope(stdout, command) {
  const envelope = parseBackendJson(stdout, command);
  if (envelope && envelope.ok === false) {
    const error = new Error(envelope.error?.message ?? "backend error");
    error.code = envelope.error?.code ?? "backend_error";
    // A failed verification still carries the action result; the CLI shows it
    // so the caller can see what was already done.
    error.result = envelope.result;
    throw error;
  }
  if (!envelope || envelope.ok !== true) {
    const error = new Error(`backend returned an unexpected envelope for '${command}': ${stdout.slice(0, 300)}`);
    error.code = "backend_error";
    throw error;
  }
  return envelope;
}

async function invokeScript(shell, scriptPath, command, paramsFile, outFile, timeoutMs, signal) {
  await runToFile(
    shell,
    [
      "-NoProfile",
      "-NonInteractive",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      scriptPath,
      "-Command",
      command,
      "-ParamsFile",
      paramsFile,
      "-OutFile",
      outFile,
    ],
    { timeoutMs, signal, env: { CUA_STATE_DIR: defaultStateDir() } },
  );
  let stdout;
  try {
    stdout = await readTextFile(outFile);
  } catch {
    const error = new Error(
      `backend produced no output file for '${command}' (powershell failed before writing the envelope)`,
    );
    error.code = "backend_error";
    throw error;
  }
  return unwrapEnvelope(stdout, command);
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function isPidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    return err?.code === "EPERM";
  }
}

async function readWorkerMeta(metaPath) {
  try {
    const raw = await readFile(metaPath, "utf8");
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

async function stopWorker(stateDir) {
  const workerRoot = join(stateDir, "worker");
  const metaPath = join(workerRoot, "worker.json");
  const stopFlag = join(workerRoot, "stop.flag");
  const meta = await readWorkerMeta(metaPath);
  if (!meta || !isPidAlive(meta.pid)) {
    await rm(metaPath, { force: true }).catch(() => undefined);
    return { stopped: false, previous_pid: meta?.pid ?? null };
  }
  await mkdir(workerRoot, { recursive: true });
  await writeFile(stopFlag, "1", "utf8");
  const deadline = Date.now() + 1500;
  while (Date.now() < deadline && isPidAlive(meta.pid)) {
    await sleep(25);
  }
  if (isPidAlive(meta.pid)) {
    try {
      process.kill(meta.pid);
    } catch {}
  }
  await rm(metaPath, { force: true }).catch(() => undefined);
  await rm(stopFlag, { force: true }).catch(() => undefined);
  return { stopped: true, previous_pid: meta.pid };
}

function spawnWorker(stateDir, version) {
  const idleMs = Number.parseInt(process.env.CUA_WORKER_IDLE_MS ?? "60000", 10) || 60000;
  for (const shell of POWERSHELL_CANDIDATES) {
    try {
      const child = spawn(
        shell,
        [
          "-NoProfile",
          "-NonInteractive",
          "-ExecutionPolicy",
          "Bypass",
          "-File",
          WORKER_SCRIPT,
          "-StateDir",
          stateDir,
          "-IdleMs",
          String(idleMs),
          "-Version",
          version,
        ],
        {
          // Do NOT set detached:true on Windows: DETACHED_PROCESS can cause
          // powershell.exe to exit immediately in sandboxed/hidden environments.
          // windowsHide + stdio:'ignore' + unref() already lets the CLI exit
          // while keeping the warm worker alive across calls.
          detached: false,
          windowsHide: true,
          stdio: "ignore",
          env: { ...process.env, CUA_STATE_DIR: stateDir },
        },
      );
      child.unref();
      return true;
    } catch {}
  }
  return false;
}

async function ensureWorker(stateDir, version) {
  const workerRoot = join(stateDir, "worker");
  const queueDir = join(workerRoot, "queue");
  const metaPath = join(workerRoot, "worker.json");
  const stopFlag = join(workerRoot, "stop.flag");

  let meta = await readWorkerMeta(metaPath);
  if (meta && isPidAlive(meta.pid) && meta.version === version) {
    await mkdir(queueDir, { recursive: true });
    return { queueDir, pid: meta.pid };
  }
  if (meta && isPidAlive(meta.pid) && meta.version !== version) {
    await stopWorker(stateDir);
  }
  await mkdir(queueDir, { recursive: true });
  await rm(stopFlag, { force: true }).catch(() => undefined);
  if (!spawnWorker(stateDir, version)) return null;

  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    meta = await readWorkerMeta(metaPath);
    if (meta && isPidAlive(meta.pid) && meta.version === version) {
      return { queueDir, pid: meta.pid };
    }
    await sleep(25);
  }
  return null;
}

function collectWorkerEnv(stateDir) {
  return {
    CUA_STATE_DIR: stateDir,
    CUA_AUDIT_PATH: process.env.CUA_AUDIT_PATH ?? null,
    CUA_DENY_TITLES: process.env.CUA_DENY_TITLES ?? null,
    CUA_DENY_PROCESSES: process.env.CUA_DENY_PROCESSES ?? null,
    CUA_TRAJECTORY_PATH: process.env.CUA_TRAJECTORY_PATH ?? null,
    CUA_TRAJECTORY_INCLUDE_TEXT: process.env.CUA_TRAJECTORY_INCLUDE_TEXT ?? null,
    CUA_TRACE_ID: process.env.CUA_TRACE_ID ?? null,
    CUA_SUBGOAL: process.env.CUA_SUBGOAL ?? null,
    CUA_STEP_ID: process.env.CUA_STEP_ID ?? null,
    CUA_DPI_AWARE: process.env.CUA_DPI_AWARE ?? null,
  };
}

async function runViaWorker(command, params, timeoutMs, signal) {
  const stateDir = defaultStateDir();
  const version = computeWorkerVersion();
  const worker = await ensureWorker(stateDir, version);
  if (!worker) return null;

  return await withOutputFile(async (outFile) => {
    const reqId = randomUUID();
    const tmpReq = join(worker.queueDir, `${reqId}.tmp`);
    const reqFile = join(worker.queueDir, `${reqId}.req.json`);
    const doneFile = join(worker.queueDir, `${reqId}.done`);
    const payload = {
      id: reqId,
      command,
      params,
      env: collectWorkerEnv(stateDir),
      outFile,
    };
    await writeFile(tmpReq, JSON.stringify(payload), "utf8");
    await rename(tmpReq, reqFile);

    const deadline = Date.now() + timeoutMs;
    try {
      while (Date.now() < deadline) {
        if (signal?.aborted) {
          throw new RunnerError("aborted", "command aborted");
        }
        let done = false;
        try {
          await readFile(doneFile);
          done = true;
        } catch (err) {
          if (err?.code && err.code !== "ENOENT") throw err;
        }
        if (done) {
          let stdout;
          try {
            stdout = await readTextFile(outFile);
          } catch {
            const error = new Error(
              `worker produced no output file for '${command}'`,
            );
            error.code = "backend_error";
            throw error;
          }
          return unwrapEnvelope(stdout, command);
        }
        if (!isPidAlive(worker.pid)) {
          return null; // worker died mid-flight; let caller fall back cleanly
        }
        await sleep(8);
      }
      throw new RunnerError("timeout", `worker command timed out after ${timeoutMs} ms: ${command}`);
    } finally {
      await rm(reqFile, { force: true }).catch(() => undefined);
      await rm(doneFile, { force: true }).catch(() => undefined);
    }
  });
}

/** Run one Windows command and return the normalized envelope { ok, result }. */
export async function runWindowsCommand(command, params = {}, options = {}) {
  if (command === "stop-worker") {
    const res = await stopWorker(defaultStateDir());
    return {
      ok: true,
      command: "stop-worker",
      platform: "win32",
      action_sent: false,
      result: res,
    };
  }

  const script = COMMAND_SCRIPTS[command];
  if (!script) {
    const error = new Error(`unknown command '${command}'`);
    error.code = "unknown_command";
    throw error;
  }
  const timeoutMs =
    options.timeoutMs ??
    (MUTATING_COMMANDS.has(command) ? 60_000 : command === "get-app-state" ? 45_000 : 30_000);

  if (process.env.CUA_WORKER !== "0") {
    const envelope = await runViaWorker(command, params, timeoutMs, options.signal);
    if (envelope) return envelope;
  }

  const scriptPath = join(SCRIPTS_DIR, script);
  return await withParamsFile(params, (paramsFile) =>
    withOutputFile(async (outFile) => {
      let lastError;
      for (const shell of POWERSHELL_CANDIDATES) {
        try {
          return await invokeScript(
            shell,
            scriptPath,
            command,
            paramsFile,
            outFile,
            timeoutMs,
            options.signal,
          );
        } catch (error) {
          // Missing executable is the only retryable failure: everything else
          // (timeout, backend error, envelope failure) is a real result.
          const missingShell =
            error instanceof RunnerError && error.code === "spawn_failed" && /ENOENT/.test(error.message);
          if (!missingShell) throw error;
          lastError = error;
        }
      }
      throw new RunnerError(
        "spawn_failed",
        `no PowerShell executable found (tried: ${POWERSHELL_CANDIDATES.join(", ")}): ${lastError?.message ?? ""}`,
      );
    }),
  );
}

export async function probeWindows() {
  return await probePlatform();
}
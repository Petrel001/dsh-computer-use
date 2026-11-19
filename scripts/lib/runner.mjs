// DSH Computer Use - 统一子进程执行层。
// 所有外部副作用（PowerShell / osascript / xdotool 等）都收敛到这里：
// 统一超时、退出码归一化、临时参数文件与输出文件生命周期。
//
// 输出通道刻意使用「后端写文件」而不是管道捕获：DSH 的 Windows 沙箱会阻止
// 子进程打开命名管道（Node child_process 默认 stdio:'pipe' 直接 EPERM），
// 而 stdio:'ignore' 的后台 spawn 不受影响。文件通道在沙箱内外行为一致。
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const DEFAULT_TIMEOUT_MS = 60_000;

function stripUndefined(env) {
  const out = {};
  for (const [key, value] of Object.entries(env)) {
    if (value !== undefined && value !== null) out[key] = String(value);
  }
  return out;
}

/** 稳定错误码：调用方不得依赖错误文本做流程判断。 */
export const RUNNER_ERROR_CODES = {
  timeout: "timeout",
  spawn_failed: "spawn_failed",
  backend_error: "backend_error",
  output_missing: "backend_error",
};

export class RunnerError extends Error {
  constructor(code, message, details = {}) {
    super(message);
    this.name = "RunnerError";
    this.code = code;
    this.details = details;
  }
}

/**
 * 以后台方式执行命令（stdio 全部 ignore），进程退出后由调用方读取 outputFile。
 * 返回 { exitCode }；spawn 失败/超时抛 RunnerError。
 */
export function runToFile(command, args, options = {}) {
  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  return new Promise((resolve, reject) => {
    let settled = false;
    let timer;
    const child = spawn(command, args, {
      windowsHide: true,
      stdio: "ignore",
      // Backend scripts inherit the caller's environment plus whatever the
      // command layer wants them to see (state cache dir, audit path, deny
      // lists). Undefined values must be dropped, not stringified.
      env: options.env ? { ...process.env, ...stripUndefined(options.env) } : process.env,
    });
    const finish = (fn, value) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      fn(value);
    };
    timer = setTimeout(() => {
      child.kill("SIGKILL");
      finish(reject, new RunnerError(RUNNER_ERROR_CODES.timeout, `command timed out after ${timeoutMs} ms: ${command}`));
    }, timeoutMs);
    if (timer.unref) timer.unref();
    child.on("error", (error) => {
      const code = error.code === "ENOENT" ? RUNNER_ERROR_CODES.spawn_failed : RUNNER_ERROR_CODES.backend_error;
      finish(reject, new RunnerError(code, `failed to start ${command}: ${error.message}`));
    });
    child.on("exit", (code) => {
      finish(resolve, { exitCode: code ?? -1 });
    });
    if (options.signal) {
      const onAbort = () => {
        child.kill("SIGKILL");
        finish(reject, new RunnerError("aborted", "command aborted"));
      };
      if (options.signal.aborted) onAbort();
      else options.signal.addEventListener("abort", onAbort, { once: true });
    }
  });
}

/**
 * 通过 shell 重定向把命令输出写进文件（POSIX/Linux 后端捕获外部命令输出用）。
 * outputFile 由调用方提供；命令的 stdout+stderr 都进同一文件。
 */
export async function runShellToFile(commandLine, outputFile, options = {}) {
  const isWin = process.platform === "win32";
  const shell = isWin ? "cmd.exe" : "/bin/sh";
  const shellFlag = isWin ? "/c" : "-c";
  const redirected = `${commandLine} > "${outputFile}" 2>&1`;
  const result = await runToFile(shell, [shellFlag, redirected], options);
  return result;
}

export async function readTextFile(path) {
  return await readFile(path, "utf8");
}

/**
 * 临时参数文件：把结构化参数落成 JSON 文件再把路径交给后端脚本，
 * 避免 Windows 命令行对含空格/引号的 JSON 参数做转义。
 * 带 UTF-8 BOM：PowerShell 5.1 在中文区域设置下把无 BOM 文件按 GBK 解码，
 * 含中文的参数会乱码甚至吞掉换行符（Get-Content 会剥掉 BOM，不影响解析）。
 */
export async function withParamsFile(params, body) {
  const dir = await mkdtemp(join(tmpdir(), "dsh-computer-use-"));
  const file = join(dir, "params.json");
  try {
    await writeFile(file, `\uFEFF${JSON.stringify(params ?? {})}`, "utf8");
    return await body(file);
  } finally {
    await rm(dir, { recursive: true, force: true }).catch(() => undefined);
  }
}

/** 临时输出文件：backend 把 JSON 信封写进来；结束时自动清理。 */
export async function withOutputFile(body) {
  const dir = await mkdtemp(join(tmpdir(), "dsh-computer-use-out-"));
  const file = join(dir, "output.json");
  try {
    return await body(file);
  } finally {
    await rm(dir, { recursive: true, force: true }).catch(() => undefined);
  }
}

/** 探测可执行文件是否在 PATH 中（跨平台，文件通道实现）。 */
export async function commandExists(command) {
  try {
    return await withOutputFile(async (outFile) => {
      const isWin = process.platform === "win32";
      const probe = isWin ? `where ${command}` : `command -v ${command}`;
      await runShellToFile(probe, outFile, { timeoutMs: 5_000 });
      const text = (await readTextFile(outFile)).trim();
      if (!text) return false;
      return !/not recognized|not found|no such file|cannot find/i.test(text);
    });
  } catch {
    return false;
  }
}

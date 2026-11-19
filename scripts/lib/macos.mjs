// DSH Computer Use - macOS 后端（JXA via osascript）。
// 能力范围：list-apps / list-windows / get-app-state / screenshot / focus / click / type / keypress / scroll。
// 需要系统权限：「辅助功能」（UI 控制）与「屏幕录制」（截图）；未授权时系统会弹窗或返回空树。
// 输出走文件通道：JXA 把 JSON 信封写入 argv[2] 指定的路径（见 runner.mjs 沙箱说明）。
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parseBackendJson } from "./platform.mjs";
import { readTextFile, runToFile, withOutputFile, withParamsFile } from "./runner.mjs";

const SCRIPTS_DIR = join(dirname(fileURLToPath(import.meta.url)), "..", "jxa");

export async function runMacCommand(command, params = {}, options = {}) {
  const timeoutMs = options.timeoutMs ?? 45_000;
  return await withParamsFile(params, (paramsFile) =>
    withOutputFile(async (outFile) => {
      await runToFile(
        "osascript",
        ["-l", "JavaScript", join(SCRIPTS_DIR, "computer-use.js"), command, paramsFile, outFile],
        { timeoutMs, signal: options.signal },
      );
      let stdout;
      try {
        stdout = await readTextFile(outFile);
      } catch {
        const error = new Error(
          `JXA backend produced no output file for '${command}' (osascript failed before writing the envelope)`,
        );
        error.code = "backend_error";
        throw error;
      }
      const envelope = parseBackendJson(stdout, command);
      if (envelope && envelope.ok === false) {
        const error = new Error(envelope.error?.message ?? "backend error");
        error.code = envelope.error?.code ?? "backend_error";
        throw error;
      }
      if (!envelope || envelope.ok !== true) {
        const error = new Error(`JXA backend returned an unexpected envelope for '${command}'`);
        error.code = "backend_error";
        throw error;
      }
      return envelope;
    }),
  );
}

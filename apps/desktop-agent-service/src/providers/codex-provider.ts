import { access } from "node:fs/promises";
import { constants } from "node:fs";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { ProviderStatus, TaskProcessSpec, TaskProvider } from "../provider-registry.js";

const execFileAsync = promisify(execFile);

type ExecRunner = (
  file: string,
  args: readonly string[]
) => Promise<{ stdout?: string | Buffer; stderr?: string | Buffer }>;

export function parseCodexLoginStatus(output: string): ProviderStatus {
  const normalized = output.trim().toLowerCase();

  if (!normalized) {
    return {
      status: "unknown",
      detail: "No login status output was returned."
    };
  }

  if (normalized.includes("not logged in") || normalized.includes("log in")) {
    return {
      status: "not-authenticated",
      detail: output.trim()
    };
  }

  if (normalized.includes("logged in")) {
    return {
      status: "connected",
      detail: output.trim()
    };
  }

  return {
    status: "unknown",
    detail: output.trim()
  };
}

async function executableExists(executablePath: string, execRunner: ExecRunner): Promise<boolean> {
  if (executablePath.includes("/")) {
    try {
      await access(executablePath, constants.X_OK);
      return true;
    } catch {
      return false;
    }
  }

  try {
    await execRunner("which", [executablePath]);
    return true;
  } catch {
    return false;
  }
}

export function createCodexProvider({
  executablePath = process.env.CODEX_BIN || "codex",
  execRunner = execFileAsync as ExecRunner
}: {
  executablePath?: string;
  execRunner?: ExecRunner;
} = {}): TaskProvider {
  return {
    id: "codex",
    label: "Codex",
    async getStatus() {
      const exists = await executableExists(executablePath, execRunner);
      if (!exists) {
        return {
          status: "unavailable",
          detail: `Executable not found: ${executablePath}`
        };
      }

      try {
        const { stdout = "", stderr = "" } = await execRunner(executablePath, ["login", "status"]);
        return parseCodexLoginStatus(String(stdout || stderr));
      } catch (error) {
        return {
          status: "error",
          detail: error instanceof Error ? error.message : String(error)
        };
      }
    },
    createTaskProcess({ task, project }): TaskProcessSpec {
      return {
        command: executablePath,
        args: [
          "-a",
          "never",
          "-s",
          "workspace-write",
          "exec",
          "--color",
          "never",
          "-C",
          project.repoPath,
          task.prompt
        ],
        cwd: project.repoPath,
        env: {}
      };
    }
  };
}

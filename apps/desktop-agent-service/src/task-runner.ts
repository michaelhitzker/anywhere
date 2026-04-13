import { spawn } from "node:child_process";
import type { Readable } from "node:stream";
import type { createProviderRegistry } from "./provider-registry.js";
import type { Project } from "./project-capabilities.js";
import type { createTaskStore } from "./task-store.js";

type TaskStore = ReturnType<typeof createTaskStore>;
type ProviderRegistry = ReturnType<typeof createProviderRegistry>;

type SpawnedProcessLike = {
  stdout: Readable | null;
  stderr: Readable | null;
  once(event: "spawn", listener: () => void): void;
  once(event: "error", listener: (error: Error) => void): void;
  once(event: "close", listener: (code: number | null) => void): void;
};

type SpawnProcess = (
  command: string,
  args: string[],
  options: {
    cwd: string;
    env: NodeJS.ProcessEnv;
    stdio: ["ignore", "pipe", "pipe"];
  }
) => SpawnedProcessLike;

function attachLogStream(stream: Readable, onLine: (line: string) => void) {
  let buffer = "";
  stream.setEncoding("utf8");

  stream.on("data", (chunk: string | Buffer) => {
    buffer += String(chunk);
    const lines = buffer.split(/\r?\n/);
    buffer = lines.pop() ?? "";
    for (const line of lines) {
      const trimmed = line.trim();
      if (trimmed) {
        onLine(trimmed);
      }
    }
  });

  stream.on("end", () => {
    const trimmed = buffer.trim();
    if (trimmed) {
      onLine(trimmed);
    }
  });
}

export function createTaskRunner({
  taskStore,
  providerRegistry,
  projectLookup,
  spawnProcess = spawn as SpawnProcess
}: {
  taskStore: TaskStore;
  providerRegistry: ProviderRegistry;
  projectLookup: (projectId: string) => Project | null;
  spawnProcess?: SpawnProcess;
}) {
  async function startTask(taskId: string) {
    const task = taskStore.getTask(taskId);
    if (!task) {
      throw new Error(`Unknown task: ${taskId}`);
    }

    const project = projectLookup(task.projectId);
    if (!project) {
      taskStore.markFailed(taskId, {
        summary: `Project ${task.projectId} was not found.`
      });
      taskStore.appendLog(taskId, `Unable to start task because project ${task.projectId} does not exist.`);
      return;
    }

    const provider = providerRegistry.getProvider(task.providerId);
    taskStore.markRunning(taskId, {
      summary: `${provider.label} is running against ${project.name}.`,
      worktreePath: project.repoPath,
      nextActions: ["Watch live logs", "Inspect repo changes", "Collect preview artifacts"]
    });
    taskStore.appendLog(taskId, `Starting ${provider.label} in ${project.repoPath}.`);

    let spec;
    try {
      spec = provider.createTaskProcess({ task, project });
    } catch (error) {
      taskStore.appendLog(taskId, `Provider ${provider.id} could not build a task process.`);
      taskStore.markFailed(taskId, {
        summary: error instanceof Error ? error.message : String(error)
      });
      return;
    }

    await new Promise<void>((resolve) => {
      let finished = false;

      function finalize(callback: () => void) {
        if (finished) {
          return;
        }
        finished = true;
        callback();
        resolve();
      }

      const child = spawnProcess(spec.command, spec.args, {
        cwd: spec.cwd,
        env: {
          ...process.env,
          ...spec.env
        },
        stdio: ["ignore", "pipe", "pipe"]
      });

      if (child.stdout) {
        attachLogStream(child.stdout, (line) => {
          taskStore.appendLog(taskId, `[stdout] ${line}`);
        });
      }

      if (child.stderr) {
        attachLogStream(child.stderr, (line) => {
          taskStore.appendLog(taskId, `[stderr] ${line}`);
        });
      }

      child.once("spawn", () => {
        taskStore.appendLog(taskId, `Spawned ${spec.command}.`);
      });

      child.once("error", (error) => {
        finalize(() => {
          taskStore.appendLog(taskId, `Process launch failed: ${error.message}`);
          taskStore.markFailed(taskId, {
            summary: `${provider.label} failed to launch.`
          });
        });
      });

      child.once("close", (code) => {
        finalize(() => {
          if (code === 0) {
            taskStore.appendLog(taskId, `${provider.label} finished successfully.`);
            taskStore.markDone(taskId, {
              summary: `${provider.label} completed the task successfully.`,
              nextActions: ["Review logs", "Inspect git diff", "Add preview adapters next"]
            });
            return;
          }

          taskStore.appendLog(taskId, `${provider.label} exited with status ${code}.`);
          taskStore.markFailed(taskId, {
            summary: `${provider.label} exited with status ${code}.`
          });
        });
      });
    });
  }

  function submitTask({
    projectId,
    prompt,
    providerId = providerRegistry.defaultProviderId
  }: {
    projectId: string;
    prompt: string;
    providerId?: string;
  }) {
    const task = taskStore.createTask({
      projectId,
      prompt,
      providerId
    });

    queueMicrotask(() => {
      void startTask(task.id);
    });

    return task;
  }

  return {
    submitTask,
    startTask
  };
}

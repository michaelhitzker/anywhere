import test from "node:test";
import assert from "node:assert/strict";
import { PassThrough } from "node:stream";
import { EventEmitter } from "node:events";
import { createTaskStore } from "../src/task-store.js";
import { createProviderRegistry } from "../src/provider-registry.js";
import { createTaskRunner } from "../src/task-runner.js";

function createSuccessfulChild() {
  const child = new EventEmitter() as EventEmitter & {
    stdout: PassThrough;
    stderr: PassThrough;
  };
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();

  queueMicrotask(() => {
    child.emit("spawn");
    child.stdout.write("first line\n");
    child.stderr.write("warning line\n");
    child.stdout.end();
    child.stderr.end();
    child.emit("close", 0);
  });

  return child;
}

test("task runner executes a provider process and stores streamed logs", async () => {
  const store = createTaskStore();
  const registry = createProviderRegistry({
    providers: [
      {
        id: "codex",
        label: "Codex",
        createTaskProcess() {
          return {
            command: "codex",
            args: ["exec"],
            cwd: "/tmp/charty",
            env: {}
          };
        }
      }
    ],
    defaultProviderId: "codex"
  });

  const runner = createTaskRunner({
    taskStore: store,
    providerRegistry: registry,
    projectLookup(projectId) {
      return {
        id: projectId,
        name: "Charty",
        repoPath: "/tmp/charty",
        platform: "mobile",
        supportsIosRun: false,
        previewModes: []
      };
    },
    spawnProcess() {
      return createSuccessfulChild() as never;
    }
  });

  const task = runner.submitTask({
    projectId: "charty",
    prompt: "Implement a feature"
  });

  await new Promise((resolve) => setTimeout(resolve, 10));

  const updated = store.getTask(task.id);
  assert.equal(updated?.status, "done");
  assert.ok(updated?.logs.some((entry) => entry.message.includes("[stdout] first line")));
  assert.ok(updated?.logs.some((entry) => entry.message.includes("[stderr] warning line")));
});

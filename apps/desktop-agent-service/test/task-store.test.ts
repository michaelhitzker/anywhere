import test from "node:test";
import assert from "node:assert/strict";
import { createTaskStore } from "../src/task-store.js";

test("task store creates tasks and tracks lifecycle transitions", () => {
  const store = createTaskStore();
  const task = store.createTask({
    projectId: "charty",
    prompt: "Add a scrubber",
    providerId: "codex"
  });

  assert.equal(task.status, "queued");
  assert.equal(task.providerId, "codex");

  store.appendLog(task.id, "Starting provider.");
  store.markRunning(task.id, { summary: "Running now." });
  store.markDone(task.id, { summary: "Finished." });

  const updated = store.getTask(task.id);
  assert.equal(updated?.status, "done");
  assert.equal(updated?.summary, "Finished.");
  assert.equal(updated?.logs.at(-1)?.message, "Starting provider.");
});

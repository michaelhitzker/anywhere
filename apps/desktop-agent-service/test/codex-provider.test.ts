import test from "node:test";
import assert from "node:assert/strict";
import { createCodexProvider, parseCodexLoginStatus } from "../src/providers/codex-provider.js";

test("codex provider builds a non-interactive exec command", () => {
  const provider = createCodexProvider({ executablePath: "/usr/local/bin/codex" });
  const spec = provider.createTaskProcess({
    task: {
      id: "task-1",
      title: "Implement a feature",
      projectId: "charty",
      prompt: "Implement a feature",
      providerId: "codex",
      branchName: null,
      worktreePath: null,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
      status: "queued",
      summary: "",
      messages: [],
      changedFiles: [],
      latestTurnCount: null,
      undoAvailable: false,
      logs: [],
      artifacts: [],
      nextActions: []
    },
    project: {
      id: "charty",
      name: "Charty",
      repoPath: "/tmp/charty",
      platform: "mobile",
      supportsIosRun: false,
      previewModes: []
    }
  });

  assert.equal(spec.command, "/usr/local/bin/codex");
  assert.deepEqual(spec.args, [
    "-a",
    "never",
    "-s",
    "workspace-write",
    "exec",
    "--color",
    "never",
    "-C",
    "/tmp/charty",
    "Implement a feature"
  ]);
  assert.equal(spec.cwd, "/tmp/charty");
});

test("codex login status parser recognizes a connected session", () => {
  const status = parseCodexLoginStatus("Logged in using ChatGPT\n");
  assert.equal(status.status, "connected");
});

test("codex login status parser recognizes an unauthenticated session", () => {
  const status = parseCodexLoginStatus("Not logged in\n");
  assert.equal(status.status, "not-authenticated");
});

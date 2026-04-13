import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createSettingsStore } from "../src/settings-store.js";

function createTempDir() {
  return mkdtempSync(join(tmpdir(), "anywhere-settings-"));
}

test("settings store seeds defaults and persists updates", () => {
  const tempDir = createTempDir();

  try {
    const storagePath = join(tempDir, "settings.json");
    const store = createSettingsStore({ storagePath });

    const defaults = store.getSettings();
    assert.equal(defaults.t3.host, "127.0.0.1");
    assert.equal(defaults.t3.port, 3773);

    const updated = store.updateSettings({
      t3: {
        companionRepoPath: "/tmp/t3code-companion",
        baseDir: "/tmp/.t3",
        host: "0.0.0.0",
        port: 4123,
        autoStartServer: false
      }
    });

    assert.equal(updated.t3.companionRepoPath, "/tmp/t3code-companion");
    assert.equal(updated.t3.baseDir, "/tmp/.t3");
    assert.equal(updated.t3.host, "0.0.0.0");
    assert.equal(updated.t3.port, 4123);
    assert.equal(updated.t3.autoStartServer, false);

    const reloaded = createSettingsStore({ storagePath }).getSettings();
    assert.deepEqual(reloaded, updated);
    assert.match(readFileSync(storagePath, "utf8"), /t3code-companion/);
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
});

import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createProjectMetadataStore } from "../src/project-metadata-store.js";

function createTempDir() {
  return mkdtempSync(join(tmpdir(), "anywhere-metadata-"));
}

test("project metadata store returns defaults and persists custom metadata", () => {
  const tempDir = createTempDir();

  try {
    const storagePath = join(tempDir, "project-metadata.json");
    const store = createProjectMetadataStore({ storagePath });

    assert.deepEqual(store.get("/tmp/charty"), {
      platform: "mobile",
      previewModes: ["artifacts", "web-preview"]
    });

    const saved = store.set("/tmp/charty", {
      platform: "full-stack",
      previewModes: ["artifacts", "remote-desktop", "artifacts"]
    });

    assert.deepEqual(saved, {
      platform: "full-stack",
      previewModes: ["artifacts", "remote-desktop"]
    });

    const reloadedStore = createProjectMetadataStore({ storagePath });
    assert.deepEqual(reloadedStore.get("/tmp/charty"), saved);
    assert.equal(reloadedStore.remove("/tmp/charty"), true);
    assert.equal(reloadedStore.remove("/tmp/charty"), false);
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
});

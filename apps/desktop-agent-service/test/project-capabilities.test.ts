import test from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { hasXcodeContainer, isIosAppProject, projectSupportsIosRun } from "../src/project-capabilities.js";

function createTempDir() {
  return mkdtempSync(join(tmpdir(), "anywhere-project-capabilities-"));
}

test("project helper detects explicit iOS apps", () => {
  assert.equal(isIosAppProject({ platform: "ios" }), true);
  assert.equal(isIosAppProject({ platform: "iOS" }), true);
  assert.equal(isIosAppProject({ platform: "mobile" }), false);
  assert.equal(isIosAppProject({ platform: "web" }), false);
});

test("project helper detects Xcode containers for iOS run support", () => {
  const tempDir = createTempDir();

  try {
    const projectRoot = join(tempDir, "sample-app");
    mkdirSync(join(projectRoot, "SampleApp.xcodeproj"), { recursive: true });

    assert.equal(hasXcodeContainer(projectRoot), true);
    assert.equal(projectSupportsIosRun({ repoPath: projectRoot, platform: "mobile" }), true);
    assert.equal(projectSupportsIosRun({ repoPath: join(tempDir, "web-app"), platform: "web" }), false);
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
});

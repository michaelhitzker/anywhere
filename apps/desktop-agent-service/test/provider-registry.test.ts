import test from "node:test";
import assert from "node:assert/strict";
import { createProviderRegistry } from "../src/provider-registry.js";

test("provider registry returns the default provider and provider list", async () => {
  const registry = createProviderRegistry({
    providers: [
      {
        id: "codex",
        label: "Codex",
        async getStatus() {
          return { status: "connected", detail: "ready" };
        },
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

  assert.equal(registry.getDefaultProvider().id, "codex");
  assert.deepEqual(registry.listProviders(), [{ id: "codex", label: "Codex" }]);

  const status = await registry.getProviderStatus("codex");
  assert.equal(status.status, "connected");
  assert.equal(status.detail, "ready");
});

test("provider registry rejects an unknown default provider", () => {
  assert.throws(() => {
    createProviderRegistry({
      providers: [],
      defaultProviderId: "codex"
    });
  }, /Unknown default provider/);
});

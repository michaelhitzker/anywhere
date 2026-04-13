import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createPairingStore } from "../src/pairing-store.js";

function createTempDir() {
  return mkdtempSync(join(tmpdir(), "anywhere-pairing-"));
}

function payloadFromTicket(ticket: { qrPayload: string }) {
  return JSON.parse(ticket.qrPayload) as {
    pairingId: string;
    pairingSecret: string;
    credentialExpiresAt: string;
  };
}

test("pairing tickets create a 30 day client credential", () => {
  const tempDir = createTempDir();

  try {
    const now = new Date("2026-04-11T12:00:00.000Z");
    const store = createPairingStore({ storagePath: join(tempDir, "pairing.json") });
    const ticket = store.createTicket({
      desktopName: "MacBook",
      apiBaseUrl: "http://192.168.1.10:4242/",
      now
    });
    const payload = payloadFromTicket(ticket);

    assert.equal(store.getStatus(now).credentialTtlDays, 30);
    assert.equal(payload.credentialExpiresAt, "2026-05-11T12:00:00.000Z");

    const paired = store.completePairing({
      pairingId: payload.pairingId,
      pairingSecret: payload.pairingSecret,
      clientName: "Michael's iPhone",
      now
    });

    assert.equal(paired.client.name, "Michael's iPhone");
    assert.equal(paired.client.expiresAt, "2026-05-11T12:00:00.000Z");
    assert.ok(paired.token.length > 20);
    assert.equal(store.validateClientToken(paired.token, now)?.id, paired.client.id);

    const stored = readFileSync(join(tempDir, "pairing.json"), "utf8");
    assert.doesNotMatch(stored, new RegExp(payload.pairingSecret, "u"));
    assert.doesNotMatch(stored, new RegExp(paired.token, "u"));
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
});

test("pairing tickets are one time use and client credentials expire", () => {
  const tempDir = createTempDir();

  try {
    const now = new Date("2026-04-11T12:00:00.000Z");
    const store = createPairingStore({ storagePath: join(tempDir, "pairing.json") });
    const payload = payloadFromTicket(store.createTicket({ now }));
    const paired = store.completePairing({
      pairingId: payload.pairingId,
      pairingSecret: payload.pairingSecret,
      now
    });

    assert.throws(() => {
      store.completePairing({
        pairingId: payload.pairingId,
        pairingSecret: payload.pairingSecret,
        now
      });
    }, /Invalid or expired pairing code/u);

    assert.equal(
      store.validateClientToken(paired.token, new Date("2026-05-12T12:00:00.000Z")),
      null
    );
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
});

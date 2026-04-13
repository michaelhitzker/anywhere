import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { hostname } from "node:os";
import { dirname } from "node:path";

export const PAIRED_CLIENT_TTL_MS = 30 * 24 * 60 * 60 * 1000;
const PAIRING_TICKET_TTL_MS = 10 * 60 * 1000;

type PairingTicketRecord = {
  id: string;
  secretHash: string;
  createdAt: string;
  expiresAt: string;
  credentialExpiresAt: string;
  qrPayload: string;
};

type PairedClientRecord = {
  id: string;
  name: string;
  tokenHash: string;
  createdAt: string;
  expiresAt: string;
  lastSeenAt?: string;
};

type PairingStoreData = {
  tickets: PairingTicketRecord[];
  clients: PairedClientRecord[];
};

export type PairingTicket = Omit<PairingTicketRecord, "secretHash">;

export type PairedClient = Omit<PairedClientRecord, "tokenHash"> & {
  isExpired: boolean;
};

export type PairingPayload = {
  type: "anywhere-pairing";
  version: 1;
  pairingId: string;
  pairingSecret: string;
  desktopName: string;
  apiBaseUrl?: string;
  relayUrl?: string;
  expiresAt: string;
  credentialExpiresAt: string;
};

export type PairingTicketInput = {
  desktopName?: string;
  apiBaseUrl?: string;
  relayUrl?: string;
  now?: Date;
};

export type CompletePairingInput = {
  pairingId: string;
  pairingSecret: string;
  clientName?: string;
  now?: Date;
};

const EMPTY_DATA: PairingStoreData = {
  tickets: [],
  clients: []
};

function cloneData(data: PairingStoreData): PairingStoreData {
  return JSON.parse(JSON.stringify(data)) as PairingStoreData;
}

function hashSecret(secret: string): string {
  return createHash("sha256").update(secret).digest("hex");
}

function safeHashEqual(expectedHash: string, secret: string): boolean {
  const expected = Buffer.from(expectedHash, "hex");
  const actual = Buffer.from(hashSecret(secret), "hex");

  if (expected.length !== actual.length) {
    return false;
  }

  return timingSafeEqual(expected, actual);
}

function randomToken(byteLength = 32): string {
  return randomBytes(byteLength).toString("base64url");
}

function normalizeUrl(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  if (!trimmed) {
    return undefined;
  }

  try {
    return new URL(trimmed).toString().replace(/\/$/u, "");
  } catch {
    return undefined;
  }
}

function normalizeClientName(value: string | undefined): string {
  const trimmed = value?.trim();
  return trimmed ? trimmed.slice(0, 80) : "Phone";
}

function normalizeDesktopName(value: string | undefined): string {
  const trimmed = value?.trim();
  return trimmed ? trimmed.slice(0, 80) : hostname();
}

function isFuture(value: string, now: Date): boolean {
  return Date.parse(value) > now.getTime();
}

function publicTicket(ticket: PairingTicketRecord): PairingTicket {
  const { secretHash: _secretHash, ...safeTicket } = ticket;
  return safeTicket;
}

function publicClient(client: PairedClientRecord, now: Date): PairedClient {
  const { tokenHash: _tokenHash, ...safeClient } = client;
  return {
    ...safeClient,
    isExpired: !isFuture(client.expiresAt, now)
  };
}

function loadData(storagePath: string): PairingStoreData {
  if (!existsSync(storagePath)) {
    return cloneData(EMPTY_DATA);
  }

  try {
    const parsed = JSON.parse(readFileSync(storagePath, "utf8")) as Partial<PairingStoreData>;
    return {
      tickets: Array.isArray(parsed.tickets) ? parsed.tickets : [],
      clients: Array.isArray(parsed.clients) ? parsed.clients : []
    };
  } catch {
    return cloneData(EMPTY_DATA);
  }
}

function writeData(storagePath: string, data: PairingStoreData) {
  mkdirSync(dirname(storagePath), { recursive: true });
  writeFileSync(storagePath, `${JSON.stringify(data, null, 2)}\n`, "utf8");
}

export function createPairingStore({ storagePath }: { storagePath: string }) {
  let data = loadData(storagePath);

  function persist(nextData: PairingStoreData) {
    data = nextData;
    writeData(storagePath, data);
  }

  function prune(now = new Date()) {
    const nextData = {
      tickets: data.tickets.filter((ticket) => isFuture(ticket.expiresAt, now)),
      clients: data.clients.filter((client) => isFuture(client.expiresAt, now))
    };

    if (
      nextData.tickets.length !== data.tickets.length ||
      nextData.clients.length !== data.clients.length
    ) {
      persist(nextData);
    }
  }

  return {
    createTicket(input: PairingTicketInput = {}): PairingTicket {
      const now = input.now ?? new Date();
      prune(now);

      const pairingSecret = randomToken();
      const ticketExpiresAt = new Date(now.getTime() + PAIRING_TICKET_TTL_MS).toISOString();
      const credentialExpiresAt = new Date(now.getTime() + PAIRED_CLIENT_TTL_MS).toISOString();
      const payload: PairingPayload = {
        type: "anywhere-pairing",
        version: 1,
        pairingId: randomToken(16),
        pairingSecret,
        desktopName: normalizeDesktopName(input.desktopName),
        apiBaseUrl: normalizeUrl(input.apiBaseUrl),
        relayUrl: normalizeUrl(input.relayUrl),
        expiresAt: ticketExpiresAt,
        credentialExpiresAt
      };

      const qrPayload = JSON.stringify(payload);
      const ticket: PairingTicketRecord = {
        id: payload.pairingId,
        secretHash: hashSecret(pairingSecret),
        createdAt: now.toISOString(),
        expiresAt: ticketExpiresAt,
        credentialExpiresAt,
        qrPayload
      };

      persist({
        tickets: [ticket],
        clients: data.clients
      });

      return publicTicket(ticket);
    },

    completePairing(input: CompletePairingInput): { client: PairedClient; token: string } {
      const now = input.now ?? new Date();
      prune(now);

      const ticket = data.tickets.find((candidate) => candidate.id === input.pairingId);
      if (!ticket || !safeHashEqual(ticket.secretHash, input.pairingSecret)) {
        throw new Error("Invalid or expired pairing code.");
      }

      const token = randomToken();
      const client: PairedClientRecord = {
        id: randomToken(16),
        name: normalizeClientName(input.clientName),
        tokenHash: hashSecret(token),
        createdAt: now.toISOString(),
        expiresAt: ticket.credentialExpiresAt
      };

      persist({
        tickets: data.tickets.filter((candidate) => candidate.id !== ticket.id),
        clients: [client, ...data.clients]
      });

      return {
        client: publicClient(client, now),
        token
      };
    },

    validateClientToken(token: string | undefined, now = new Date()): PairedClient | null {
      const normalizedToken = token?.trim();
      if (!normalizedToken) {
        return null;
      }

      prune(now);

      const client = data.clients.find((candidate) => safeHashEqual(candidate.tokenHash, normalizedToken));
      if (!client || !isFuture(client.expiresAt, now)) {
        return null;
      }

      client.lastSeenAt = now.toISOString();
      writeData(storagePath, data);
      return publicClient(client, now);
    },

    revokeClient(clientId: string): PairedClient | null {
      const now = new Date();
      prune(now);

      const client = data.clients.find((candidate) => candidate.id === clientId);
      if (!client) {
        return null;
      }

      persist({
        tickets: data.tickets,
        clients: data.clients.filter((candidate) => candidate.id !== clientId)
      });
      return publicClient(client, now);
    },

    getStatus(now = new Date()) {
      prune(now);

      return {
        credentialTtlDays: Math.round(PAIRED_CLIENT_TTL_MS / (24 * 60 * 60 * 1000)),
        ticketTtlMinutes: Math.round(PAIRING_TICKET_TTL_MS / (60 * 1000)),
        activeTicket: data.tickets[0] ? publicTicket(data.tickets[0]) : null,
        clients: data.clients.map((client) => publicClient(client, now))
      };
    },

    storagePath
  };
}

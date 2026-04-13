import { createServer } from "node:http";
import { join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { createProjectMetadataStore } from "./project-metadata-store.js";
import { createSettingsStore } from "./settings-store.js";
import { createPairingStore } from "./pairing-store.js";
import { createT3Bridge } from "./t3-bridge.js";
import { startCompanionBonjourAdvertiser } from "./bonjour-advertiser.js";
import { createIosRunManager, type IosRunEvent } from "./ios-run-manager.js";

const __dirname = fileURLToPath(new URL(".", import.meta.url));
const projectRoot = normalize(join(__dirname, "..", "..", ".."));
const settingsPath = join(projectRoot, ".anywhere", "settings.json");
const projectMetadataPath = join(projectRoot, ".anywhere", "project-metadata.json");
const pairingPath = join(projectRoot, ".anywhere", "pairing.json");
const port = Number(process.env.PORT || 4242);
const host = process.env.HOST || "0.0.0.0";
const settingsStore = createSettingsStore({ storagePath: settingsPath });
const projectMetadataStore = createProjectMetadataStore({ storagePath: projectMetadataPath });
const pairingStore = createPairingStore({ storagePath: pairingPath });
const t3Bridge = createT3Bridge({
  settingsStore,
  projectMetadataStore
});
const iosRunManager = createIosRunManager({
  projectLookup: async (projectId) => {
    const projects = await t3Bridge.listProjects();
    return projects.find((project) => project.id === projectId) ?? null;
  }
});
let bonjourAdvertiser: Awaited<ReturnType<typeof startCompanionBonjourAdvertiser>> | null = null;
let isShuttingDown = false;

function decodeTaskSummaryId(pathname: string): string | null {
  const match = /^\/api\/tasks\/([^/]+)\/summary\.txt$/u.exec(pathname);
  return match?.[1] ? decodeURIComponent(match[1]) : null;
}

function decodeTaskTurnId(pathname: string): string | null {
  const match = /^\/api\/tasks\/([^/]+)\/turns$/u.exec(pathname);
  return match?.[1] ? decodeURIComponent(match[1]) : null;
}

function decodeTaskDiffId(pathname: string): string | null {
  const match = /^\/api\/tasks\/([^/]+)\/diff\.txt$/u.exec(pathname);
  return match?.[1] ? decodeURIComponent(match[1]) : null;
}

function decodeTaskUndoId(pathname: string): string | null {
  const match = /^\/api\/tasks\/([^/]+)\/undo$/u.exec(pathname);
  return match?.[1] ? decodeURIComponent(match[1]) : null;
}

function decodeProjectRunId(pathname: string): string | null {
  const match = /^\/api\/projects\/([^/]+)\/runs$/u.exec(pathname);
  return match?.[1] ? decodeURIComponent(match[1]) : null;
}

function decodeRunId(pathname: string): string | null {
  const match = /^\/api\/runs\/([^/]+)$/u.exec(pathname);
  return match?.[1] ? decodeURIComponent(match[1]) : null;
}

function decodeRunEventsId(pathname: string): string | null {
  const match = /^\/api\/runs\/([^/]+)\/events$/u.exec(pathname);
  return match?.[1] ? decodeURIComponent(match[1]) : null;
}

function decodeRunCancelId(pathname: string): string | null {
  const match = /^\/api\/runs\/([^/]+)\/cancel$/u.exec(pathname);
  return match?.[1] ? decodeURIComponent(match[1]) : null;
}

function decodePairingClientId(pathname: string): string | null {
  const match = /^\/api\/pairing\/clients\/([^/]+)$/u.exec(pathname);
  return match?.[1] ? decodeURIComponent(match[1]) : null;
}

function readJsonBody<T>(request: import("node:http").IncomingMessage): Promise<T> {
  return new Promise((resolve, reject) => {
    let raw = "";
    request.on("data", (chunk: Buffer | string) => {
      raw += chunk;
    });
    request.on("end", () => {
      try {
        resolve(JSON.parse(raw) as T);
      } catch {
        reject(new Error("Invalid JSON body"));
      }
    });
    request.on("error", reject);
  });
}

function json(response: import("node:http").ServerResponse, statusCode: number, payload: unknown) {
  response.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type, Authorization"
  });
  response.end(JSON.stringify(payload, null, 2));
}

function text(
  response: import("node:http").ServerResponse,
  statusCode: number,
  payload: string,
  contentType = "text/plain; charset=utf-8"
) {
  response.writeHead(statusCode, {
    "Content-Type": contentType,
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type, Authorization"
  });
  response.end(payload);
}

function writeSseEvent(response: import("node:http").ServerResponse, event: IosRunEvent) {
  response.write(`id: ${event.id}\n`);
  response.write(`event: ${event.event}\n`);
  response.write(`data: ${JSON.stringify({ at: event.at, ...event.data })}\n\n`);
}

function isLoopbackAddress(address: string | undefined): boolean {
  return address === "127.0.0.1" ||
    address === "::1" ||
    address === "::ffff:127.0.0.1";
}

function isLoopbackRequest(request: import("node:http").IncomingMessage): boolean {
  return isLoopbackAddress(request.socket.remoteAddress);
}

function bearerToken(request: import("node:http").IncomingMessage): string | undefined {
  const authorization = request.headers.authorization?.trim();
  const match = /^Bearer\s+(.+)$/iu.exec(authorization ?? "");
  return match?.[1];
}

function requiresPairedClient(
  request: import("node:http").IncomingMessage,
  pathname: string
): boolean {
  if (isLoopbackRequest(request)) {
    return false;
  }

  if (request.method === "GET" && pathname === "/api/health") {
    return false;
  }

  if (request.method === "POST" && pathname === "/api/pairing/complete") {
    return false;
  }

  return pathname.startsWith("/api/");
}

function requiresLocalPairingControl(
  request: import("node:http").IncomingMessage,
  pathname: string
): boolean {
  if (isLoopbackRequest(request)) {
    return false;
  }

  return (request.method === "GET" && pathname === "/api/pairing/status") ||
    (request.method === "POST" && pathname === "/api/pairing/tickets") ||
    (request.method === "DELETE" && decodePairingClientId(pathname) !== null);
}

const server = createServer(async (request, response) => {
  const url = new URL(request.url || "/", `http://${request.headers.host}`);

  if (request.method === "OPTIONS") {
    response.writeHead(204, {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET,POST,DELETE,OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type, Authorization"
    });
    response.end();
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/health") {
    const t3Health = await t3Bridge.getHealth();
    const settings = settingsStore.getSettings();
    json(response, 200, {
      ok: true,
      service: "anywhere-bridge",
      codexAuth: t3Health.status,
      transport: "local-http",
      pairing: {
        required: true,
        credentialTtlDays: pairingStore.getStatus().credentialTtlDays
      },
      provider: {
        id: "t3code",
        label: "T3 Code",
        detail: t3Health.detail
      },
      providers: [
        {
          id: "t3code",
          label: "T3 Code",
          status: t3Health.status,
          detail: t3Health.detail
        }
      ],
      integrations: {
        t3: {
          origin: t3Health.origin,
          ...settings.t3
        }
      }
    });
    return;
  }

  if (requiresLocalPairingControl(request, url.pathname)) {
    json(response, 403, {
      error: "Pairing controls are only available from the Mac."
    });
    return;
  }

  if (requiresPairedClient(request, url.pathname)) {
    const client = pairingStore.validateClientToken(bearerToken(request));
    if (!client) {
      json(response, 401, {
        error: "Pair this phone with the Anywhere Bridge before using this API."
      });
      return;
    }
  }

  if (request.method === "GET" && url.pathname === "/api/pairing/status") {
    json(response, 200, pairingStore.getStatus());
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/pairing/tickets") {
    try {
      const body = await readJsonBody<{
        desktopName?: string;
        apiBaseUrl?: string;
        relayUrl?: string;
      }>(request);

      json(response, 201, {
        ticket: pairingStore.createTicket({
          desktopName: body.desktopName,
          apiBaseUrl: body.apiBaseUrl,
          relayUrl: body.relayUrl
        })
      });
    } catch (error) {
      json(response, 400, {
        error: error instanceof Error ? error.message : "Unable to create a pairing ticket."
      });
    }
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/pairing/complete") {
    try {
      const body = await readJsonBody<{
        pairingId?: string;
        pairingSecret?: string;
        clientName?: string;
      }>(request);

      if (!body.pairingId || !body.pairingSecret) {
        json(response, 400, { error: "pairingId and pairingSecret are required" });
        return;
      }

      json(response, 201, pairingStore.completePairing({
        pairingId: body.pairingId,
        pairingSecret: body.pairingSecret,
        clientName: body.clientName
      }));
    } catch (error) {
      json(response, 400, {
        error: error instanceof Error ? error.message : "Unable to pair this phone."
      });
    }
    return;
  }

  if (request.method === "DELETE") {
    const clientId = decodePairingClientId(url.pathname);
    if (clientId) {
      const removedClient = pairingStore.revokeClient(clientId);
      if (!removedClient) {
        json(response, 404, { error: `Unknown paired client: ${clientId}` });
        return;
      }

      json(response, 200, {
        removedClient,
        ...pairingStore.getStatus()
      });
      return;
    }
  }

  if (request.method === "GET" && url.pathname === "/api/settings") {
    json(response, 200, settingsStore.getSettings());
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/settings") {
    try {
      const body = await readJsonBody<{
        t3?: {
          companionRepoPath?: string;
          baseDir?: string;
          host?: string;
          port?: number;
          autoStartServer?: boolean;
        };
      }>(request);
      json(response, 200, settingsStore.updateSettings(body));
    } catch (error) {
      json(response, 400, {
        error: error instanceof Error ? error.message : "Unable to update settings."
      });
    }
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/projects") {
    try {
      json(response, 200, { projects: await t3Bridge.listProjects() });
    } catch (error) {
      json(response, 503, {
        error: error instanceof Error ? error.message : "Unable to load T3 Code projects."
      });
    }
    return;
  }

  if (request.method === "POST") {
    const projectId = decodeProjectRunId(url.pathname);
    if (projectId) {
      try {
        const run = await iosRunManager.startRun(projectId);
        json(response, 201, { run });
      } catch (error) {
        const statusCode = error instanceof Error && error.message.includes("Unknown project")
          ? 404
          : 400;
        json(response, statusCode, {
          error: error instanceof Error ? error.message : "Unable to start the iOS run."
        });
      }
      return;
    }
  }

  if (request.method === "GET" && url.pathname === "/api/tasks") {
    try {
      json(response, 200, { tasks: await t3Bridge.listTasks() });
    } catch (error) {
      json(response, 503, {
        error: error instanceof Error ? error.message : "Unable to load T3 Code tasks."
      });
    }
    return;
  }

  if (request.method === "GET") {
    const runEventsId = decodeRunEventsId(url.pathname);
    if (runEventsId) {
      if (!iosRunManager.getRun(runEventsId)) {
        json(response, 404, { error: `Unknown run: ${runEventsId}` });
        return;
      }

      response.writeHead(200, {
        "Content-Type": "text/event-stream; charset=utf-8",
        "Cache-Control": "no-cache, no-transform",
        Connection: "keep-alive",
        "Access-Control-Allow-Origin": "*"
      });
      response.write(": connected\n\n");

      for (const event of iosRunManager.listRunEvents(runEventsId)) {
        writeSseEvent(response, event);
      }

      const unsubscribe = iosRunManager.subscribe(runEventsId, (event) => {
        writeSseEvent(response, event);
      });
      request.on("close", unsubscribe);
      return;
    }

    const runId = decodeRunId(url.pathname);
    if (runId) {
      const run = iosRunManager.getRun(runId);
      if (!run) {
        json(response, 404, { error: `Unknown run: ${runId}` });
        return;
      }

      json(response, 200, { run });
      return;
    }
  }

  if (request.method === "POST") {
    const runId = decodeRunCancelId(url.pathname);
    if (runId) {
      const run = iosRunManager.cancelRun(runId);
      if (!run) {
        json(response, 404, { error: `Unknown run: ${runId}` });
        return;
      }

      json(response, 200, { run });
      return;
    }
  }

  if (request.method === "POST" && url.pathname === "/api/tasks") {
    try {
      const { projectId, prompt, interactionMode, reasoningEffort } = await readJsonBody<{
        projectId?: string;
        prompt?: string;
        interactionMode?: string;
        reasoningEffort?: string;
      }>(request);

      if (!projectId || !prompt) {
        json(response, 400, { error: "projectId and prompt are required" });
        return;
      }

      const task = await t3Bridge.submitTask({
        projectId,
        prompt,
        interactionMode,
        reasoningEffort
      });

      json(response, 201, {
        task,
        tasks: await t3Bridge.listTasks()
      });
    } catch (error) {
      const statusCode = error instanceof Error && error.message.includes("Unknown T3 Code project")
        ? 404
        : 400;
      json(response, statusCode, {
        error: error instanceof Error ? error.message : "Unable to submit task."
      });
    }
    return;
  }

  if (request.method === "POST") {
    const taskId = decodeTaskTurnId(url.pathname);
    if (taskId) {
      try {
        const { prompt, interactionMode, reasoningEffort } = await readJsonBody<{
          prompt?: string;
          interactionMode?: string;
          reasoningEffort?: string;
        }>(request);

        if (!prompt) {
          json(response, 400, { error: "prompt is required" });
          return;
        }

        const task = await t3Bridge.continueTask({
          taskId,
          prompt,
          interactionMode,
          reasoningEffort
        });

        json(response, 201, {
          task,
          tasks: await t3Bridge.listTasks()
        });
      } catch (error) {
        const statusCode = error instanceof Error && error.message.includes("Unknown T3 Code")
          ? 404
          : 400;
        json(response, statusCode, {
          error: error instanceof Error ? error.message : "Unable to continue the T3 Code thread."
        });
      }
      return;
    }
  }

  if (request.method === "POST") {
    const taskId = decodeTaskUndoId(url.pathname);
    if (taskId) {
      try {
        const task = await t3Bridge.undoLatestTaskTurn(taskId);
        json(response, 200, {
          task,
          tasks: await t3Bridge.listTasks()
        });
      } catch (error) {
        const statusCode = error instanceof Error && error.message.includes("Unknown T3 Code")
          ? 404
          : 400;
        json(response, statusCode, {
          error: error instanceof Error ? error.message : "Unable to undo the latest T3 Code turn."
        });
      }
      return;
    }
  }

  if (request.method === "GET") {
    const diffTaskId = decodeTaskDiffId(url.pathname);
    if (diffTaskId) {
      const filePath = url.searchParams.get("path") ?? "";
      if (!filePath) {
        json(response, 400, { error: "path is required" });
        return;
      }

      try {
        const diff = await t3Bridge.renderTaskFileDiff(diffTaskId, filePath);
        if (!diff) {
          text(response, 404, "Not found");
          return;
        }

        text(response, 200, diff, "text/plain; charset=utf-8");
      } catch (error) {
        text(
          response,
          500,
          error instanceof Error ? error.message : "Unable to load the task diff."
        );
      }
      return;
    }

    const taskId = decodeTaskSummaryId(url.pathname);
    if (taskId) {
      try {
        const summary = await t3Bridge.renderTaskSummary(taskId);
        if (!summary) {
          text(response, 404, "Not found");
          return;
        }

        text(response, 200, summary, "text/plain; charset=utf-8");
      } catch (error) {
        text(
          response,
          500,
          error instanceof Error ? error.message : "Unable to load the task summary."
        );
      }
      return;
    }
  }

  text(response, 404, "Not found");
});

server.listen(port, host, () => {
  console.log(`anywhere-bridge service listening on http://${host}:${port}`);
  bonjourAdvertiser = startCompanionBonjourAdvertiser(port);
  console.log(`anywhere-bridge service advertising via Bonjour as _anywhere-bridge._tcp`);
});

async function shutdown() {
  if (isShuttingDown) {
    return;
  }

  isShuttingDown = true;
  server.close();
  await bonjourAdvertiser?.stop();
}

process.on("SIGINT", () => {
  void shutdown().finally(() => {
    process.exit(0);
  });
});

process.on("SIGTERM", () => {
  void shutdown().finally(() => {
    process.exit(0);
  });
});

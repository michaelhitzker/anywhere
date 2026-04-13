import { execFile, spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { basename, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { projectSupportsIosRun, type Project } from "./project-capabilities.js";
import type { createProjectMetadataStore } from "./project-metadata-store.js";
import type { createSettingsStore } from "./settings-store.js";
import type { T3IntegrationSettings } from "./settings-store.js";
import type {
  ProviderTask,
  TaskArtifact,
  TaskChangedFile,
  TaskLogEntry,
  TaskMessage
} from "./provider-registry.js";

const execFileAsync = promisify(execFile);
const DEFAULT_MODEL_SELECTION = {
  provider: "codex",
  model: "gpt-5-codex"
} as const;
const bridgeWorkspaceRoot = normalize(
  join(fileURLToPath(new URL(".", import.meta.url)), "..", "..", "..")
);

type SettingsStore = ReturnType<typeof createSettingsStore>;
type ProjectMetadataStore = ReturnType<typeof createProjectMetadataStore>;

type T3ModelSelection = {
  provider: string;
  model: string;
  options?: {
    reasoningEffort?: T3ReasoningEffort;
  } & Record<string, unknown>;
};

type T3InteractionMode = "default" | "plan";
type T3ReasoningEffort = "low" | "medium" | "high";

const T3_INTERACTION_MODES = new Set<T3InteractionMode>(["default", "plan"]);
const T3_REASONING_EFFORTS = new Set<T3ReasoningEffort>(["low", "medium", "high"]);

function normalizeInteractionMode(value: string | undefined): T3InteractionMode {
  const normalized = value === "chat" || value === "code" || value === undefined ? "default" : value;
  if (T3_INTERACTION_MODES.has(normalized as T3InteractionMode)) {
    return normalized as T3InteractionMode;
  }

  throw new Error(`Unknown T3 Code interaction mode: ${value}`);
}

function normalizeReasoningEffort(value: string | undefined): T3ReasoningEffort | undefined {
  if (!value || value === "automatic") {
    return undefined;
  }

  if (T3_REASONING_EFFORTS.has(value as T3ReasoningEffort)) {
    return value as T3ReasoningEffort;
  }

  throw new Error(`Unknown T3 Code reasoning effort: ${value}`);
}

function modelSelectionWithReasoningEffort(
  modelSelection: T3ModelSelection,
  reasoningEffort: T3ReasoningEffort | undefined
): T3ModelSelection {
  if (!reasoningEffort) {
    return modelSelection;
  }

  return {
    ...modelSelection,
    options: {
      ...modelSelection.options,
      reasoningEffort
    }
  };
}

type T3Project = {
  id: string;
  title: string;
  workspaceRoot: string;
  defaultModelSelection?: T3ModelSelection | null;
  deletedAt: string | null;
};

type T3Message = {
  id: string;
  role: string;
  text: string;
  createdAt: string;
  updatedAt: string;
  turnId: string | null;
  streaming?: boolean;
};

type T3Activity = {
  id: string;
  kind: string;
  summary: string;
  createdAt: string;
};

type T3CheckpointFile = {
  path: string;
  kind?: string;
  status?: string;
  additions?: number;
  deletions?: number;
};

type T3Checkpoint = {
  turnId: string;
  checkpointTurnCount: number;
  checkpointRef: string | null;
  status: "ready" | "missing" | "error";
  files: T3CheckpointFile[];
  assistantMessageId: string | null;
  completedAt: string;
};

type T3Session = {
  status: string;
  activeTurnId: string | null;
  updatedAt: string;
};

type T3LatestTurn = {
  turnId: string;
  state: string;
  requestedAt: string;
  startedAt: string | null;
  completedAt: string | null;
  assistantMessageId: string | null;
};

type T3Thread = {
  id: string;
  projectId: string;
  title: string;
  modelSelection?: T3ModelSelection | null;
  runtimeMode: string;
  interactionMode: string;
  branch: string | null;
  worktreePath: string | null;
  createdAt: string;
  updatedAt: string;
  archivedAt: string | null;
  deletedAt: string | null;
  latestTurn: T3LatestTurn | null;
  messages: T3Message[];
  session: T3Session | null;
  activities: T3Activity[];
  checkpoints: T3Checkpoint[];
};

type T3Snapshot = {
  snapshotSequence: number;
  updatedAt: string;
  projects: T3Project[];
  threads: T3Thread[];
};

type T3Health = {
  status: string;
  detail: string;
  origin: string | null;
};

type RuntimeStateKind = "dev" | "userdata";

type RuntimeTarget = {
  kind: RuntimeStateKind;
  origin: string;
};

type PersistedRuntimeState = {
  origin?: string;
  stateDirName?: string;
};

function truncate(value: string, maxLength: number): string {
  const trimmed = value.trim();
  if (trimmed.length <= maxLength) {
    return trimmed;
  }

  return `${trimmed.slice(0, maxLength - 1).trimEnd()}...`;
}

function titleFromPrompt(prompt: string): string {
  const singleLine = prompt.replace(/\s+/g, " ").trim();
  if (!singleLine) {
    return "Phone Task";
  }

  return truncate(singleLine, 72);
}

function normalizeRuntimeOrigin(origin: string | undefined): string | null {
  return typeof origin === "string" && origin.trim().length > 0
    ? origin.replace(/\/+$/u, "")
    : null;
}

function readRuntimeOrigin(baseDir: string, kind: RuntimeStateKind): string | null {
  const runtimeStatePath = join(baseDir, kind, "server-runtime.json");

  if (!existsSync(runtimeStatePath)) {
    return null;
  }

  try {
    const parsed = JSON.parse(readFileSync(runtimeStatePath, "utf8")) as PersistedRuntimeState;
    return normalizeRuntimeOrigin(parsed.origin);
  } catch {
    return null;
  }
}

function readActiveRuntimeTarget(baseDir: string): RuntimeTarget | null {
  const runtimeStatePath = join(baseDir, "server-runtime.json");

  if (!existsSync(runtimeStatePath)) {
    return null;
  }

  try {
    const parsed = JSON.parse(readFileSync(runtimeStatePath, "utf8")) as PersistedRuntimeState;
    const origin = normalizeRuntimeOrigin(parsed.origin);
    if (!origin) {
      return null;
    }

    return {
      kind: parsed.stateDirName === "dev" ? "dev" : "userdata",
      origin
    };
  } catch {
    return null;
  }
}

function configuredOrigin(host: string, port: number): string {
  return `http://${host}:${port}`;
}

async function findFallbackDevOrigin(settings: T3IntegrationSettings): Promise<string | null> {
  for (let offset = 1; offset <= 5; offset += 1) {
    const candidateOrigin = configuredOrigin(settings.host, settings.port + offset);
    if (await isOriginReachable(candidateOrigin)) {
      return candidateOrigin;
    }
  }

  return null;
}

function t3ScriptPath(companionRepoPath: string): string {
  return join(companionRepoPath, "apps", "server", "src", "bin.ts");
}

function t3ScriptExists(companionRepoPath: string): boolean {
  return existsSync(t3ScriptPath(companionRepoPath));
}

async function isOriginReachable(origin: string): Promise<boolean> {
  try {
    const response = await fetch(`${origin}/.well-known/t3/environment`, {
      signal: AbortSignal.timeout(1_500)
    });
    return response.ok;
  } catch {
    return false;
  }
}

async function resolvePreferredRuntimeTarget(settings: T3IntegrationSettings): Promise<RuntimeTarget> {
  const activeTarget = readActiveRuntimeTarget(settings.baseDir);
  if (activeTarget && (await isOriginReachable(activeTarget.origin))) {
    return activeTarget;
  }

  const devOrigin = readRuntimeOrigin(settings.baseDir, "dev");
  if (devOrigin && (await isOriginReachable(devOrigin))) {
    return {
      kind: "dev",
      origin: devOrigin
    };
  }

  const fallbackDevOrigin = await findFallbackDevOrigin(settings);
  if (fallbackDevOrigin) {
    return {
      kind: "dev",
      origin: fallbackDevOrigin
    };
  }

  const userdataOrigin = readRuntimeOrigin(settings.baseDir, "userdata");
  if (userdataOrigin && (await isOriginReachable(userdataOrigin))) {
    return {
      kind: "userdata",
      origin: userdataOrigin
    };
  }

  return {
    kind: "userdata",
    origin: configuredOrigin(settings.host, settings.port)
  };
}

function compareIso(left: string, right: string): number {
  return left.localeCompare(right);
}

function sortDescendingByIso<T extends { createdAt: string }>(values: T[]): T[] {
  return [...values].sort((left, right) => compareIso(right.createdAt, left.createdAt));
}

function deriveTaskStatus(thread: T3Thread): ProviderTask["status"] {
  if (thread.session?.status === "running" || thread.latestTurn?.state === "running") {
    return "running";
  }

  if (thread.latestTurn?.state === "completed") {
    return "done";
  }

  if (thread.latestTurn?.state === "error" || thread.latestTurn?.state === "interrupted") {
    return "failed";
  }

  return "queued";
}

function latestUserPrompt(thread: T3Thread): string {
  const lastUserMessage = [...thread.messages]
    .reverse()
    .find((message) => message.role === "user" && message.text.trim().length > 0);
  return lastUserMessage ? truncate(lastUserMessage.text, 180) : thread.title;
}

function latestAssistantSummary(thread: T3Thread): string | null {
  const lastAssistantMessage = [...thread.messages]
    .reverse()
    .find((message) => message.role === "assistant" && message.text.trim().length > 0);
  return lastAssistantMessage ? truncate(lastAssistantMessage.text, 240) : null;
}

function latestCheckpoint(thread: T3Thread): T3Checkpoint | null {
  return [...thread.checkpoints].sort((left, right) => compareIso(right.completedAt, left.completedAt))[0] ?? null;
}

function checkpointRefForThreadTurn(threadId: string, turnCount: number): string {
  return `refs/t3/checkpoints/${Buffer.from(threadId).toString("base64url")}/turn/${turnCount}`;
}

function buildTaskMessages(thread: T3Thread): TaskMessage[] {
  return thread.messages
    .filter((message) => message.text.trim().length > 0)
    .sort((left, right) => compareIso(left.createdAt, right.createdAt))
    .map((message) => ({
      id: message.id,
      role: message.role,
      text: message.text,
      createdAt: message.createdAt,
      updatedAt: message.updatedAt
    }));
}

function buildChangedFiles(thread: T3Thread): TaskChangedFile[] {
  const checkpoint = latestCheckpoint(thread);
  return (checkpoint?.files ?? []).map((file) => ({
    path: file.path,
    status: file.status ?? file.kind ?? null,
    additions: file.additions ?? 0,
    deletions: file.deletions ?? 0
  }));
}

function buildTaskArtifacts(thread: T3Thread): TaskArtifact[] {
  const checkpoint = latestCheckpoint(thread);
  if (!checkpoint) {
    return [];
  }

  return [
    {
      id: `summary-${thread.id}`,
      type: "change-summary",
      label: "Latest change summary",
      url: `/api/tasks/${encodeURIComponent(thread.id)}/summary.txt`,
      note:
        checkpoint.files.length > 0
          ? `${checkpoint.files.length} file(s) captured${thread.branch ? ` on ${thread.branch}` : ""}.`
          : "Checkpoint captured without a file list."
    }
  ];
}

function buildTaskLogs(thread: T3Thread): TaskLogEntry[] {
  const messageLogs = thread.messages
    .filter((message) => message.text.trim().length > 0)
    .map((message) => ({
      at: message.updatedAt || message.createdAt,
      message: `[${message.role}] ${truncate(message.text, 180)}`
    }));

  const activityLogs = thread.activities.map((activity) => ({
    at: activity.createdAt,
    message: `[activity:${activity.kind}] ${activity.summary}`
  }));

  return [...messageLogs, ...activityLogs]
    .sort((left, right) => compareIso(left.at, right.at))
    .slice(-12);
}

function buildNextActions(thread: T3Thread, status: ProviderTask["status"]): string[] {
  const actions = new Set<string>();
  const checkpoint = latestCheckpoint(thread);

  if (status === "running") {
    actions.add("Watch the current T3 Code turn");
  }

  if (checkpoint) {
    actions.add("Open the latest change summary");
  }

  if (thread.worktreePath) {
    actions.add(`Inspect ${basename(thread.worktreePath)}`);
  }

  if (thread.branch) {
    actions.add(`Review branch ${thread.branch}`);
  }

  if (status === "failed") {
    actions.add("Retry with a tighter mobile-focused prompt");
  }

  if (!actions.size) {
    actions.add("Open the thread in T3 Code on the Mac");
  }

  return Array.from(actions);
}

function buildTaskSummary(thread: T3Thread, status: ProviderTask["status"]): string {
  const assistantSummary = latestAssistantSummary(thread);
  if (assistantSummary && status !== "running") {
    return assistantSummary;
  }

  const checkpoint = latestCheckpoint(thread);
  if (checkpoint) {
    return checkpoint.files.length > 0
      ? `Latest checkpoint captured ${checkpoint.files.length} changed file(s).`
      : "Latest checkpoint captured without a file list.";
  }

  const latestActivity = [...thread.activities].sort((left, right) => compareIso(right.createdAt, left.createdAt))[0];
  if (latestActivity) {
    return latestActivity.summary;
  }

  if (status === "running") {
    return "T3 Code is currently working on this request.";
  }

  return "Thread is ready in T3 Code.";
}

function mapThreadToTask(thread: T3Thread): ProviderTask {
  const status = deriveTaskStatus(thread);
  const checkpoint = latestCheckpoint(thread);

  return {
    id: thread.id,
    title: thread.title,
    projectId: thread.projectId,
    prompt: latestUserPrompt(thread),
    providerId: "t3code",
    branchName: thread.branch,
    worktreePath: thread.worktreePath,
    createdAt: thread.createdAt,
    updatedAt: thread.updatedAt,
    status,
    summary: buildTaskSummary(thread, status),
    messages: buildTaskMessages(thread),
    changedFiles: buildChangedFiles(thread),
    latestTurnCount: checkpoint?.checkpointTurnCount ?? null,
    undoAvailable: (checkpoint?.checkpointTurnCount ?? 0) > 0,
    logs: buildTaskLogs(thread),
    artifacts: buildTaskArtifacts(thread),
    nextActions: buildNextActions(thread, status)
  };
}

function findVisibleThread(snapshot: T3Snapshot, taskId: string): T3Thread | null {
  return snapshot.threads.find((candidate) => candidate.id === taskId && candidate.deletedAt === null) ?? null;
}

function findThreadProject(snapshot: T3Snapshot, thread: T3Thread): T3Project | null {
  return snapshot.projects.find((candidate) => candidate.id === thread.projectId && candidate.deletedAt === null) ?? null;
}

function taskWorkspaceRoot(snapshot: T3Snapshot, thread: T3Thread): string | null {
  return thread.worktreePath ?? findThreadProject(snapshot, thread)?.workspaceRoot ?? null;
}

function renderThreadSummary(snapshot: T3Snapshot, thread: T3Thread): string {
  const project = snapshot.projects.find((candidate) => candidate.id === thread.projectId);
  const checkpoint = latestCheckpoint(thread);
  const assistantSummary = latestAssistantSummary(thread);
  const files = checkpoint?.files ?? [];

  return [
    `Thread: ${thread.title}`,
    `Project: ${project?.title ?? thread.projectId}`,
    `Status: ${deriveTaskStatus(thread)}`,
    `Branch: ${thread.branch ?? "n/a"}`,
    `Worktree: ${thread.worktreePath ?? "n/a"}`,
    "",
    assistantSummary ? `Latest assistant summary:\n${assistantSummary}` : "Latest assistant summary:\n(none yet)",
    "",
    checkpoint
      ? `Latest checkpoint: ${checkpoint.status} at ${checkpoint.completedAt}`
      : "Latest checkpoint: none",
    files.length
      ? `Changed files:\n${files.map((file) => `- ${file.path}${file.status ? ` (${file.status})` : ""}`).join("\n")}`
      : "Changed files:\n(none captured yet)",
    "",
    "Recent activity:",
    ...buildTaskLogs(thread)
      .slice(-8)
      .map((entry) => `- ${entry.at} ${entry.message}`)
  ].join("\n");
}

export function createT3Bridge({
  settingsStore,
  projectMetadataStore
}: {
  settingsStore: SettingsStore;
  projectMetadataStore: ProjectMetadataStore;
}) {
  let managedServerProcess: ReturnType<typeof spawn> | null = null;
  let managedServerStartPromise: Promise<string> | null = null;

  function currentSettings() {
    return settingsStore.getSettings().t3;
  }

  async function runT3Cli(args: string[]) {
    const settings = currentSettings();
    if (!settings.companionRepoPath) {
      throw new Error("Configure the T3 companion repository path first.");
    }

    if (!t3ScriptExists(settings.companionRepoPath)) {
      throw new Error(`T3 companion script not found at ${t3ScriptPath(settings.companionRepoPath)}`);
    }

    const { stdout, stderr } = await execFileAsync(
      process.execPath,
      ["--import", "tsx", t3ScriptPath(settings.companionRepoPath), ...args],
      {
        cwd: bridgeWorkspaceRoot,
        env: process.env
      }
    );

    const output = `${String(stdout ?? "")}${String(stderr ?? "")}`.trim();
    return output;
  }

  async function waitForOrigin(origin: string): Promise<string> {
    for (let attempt = 0; attempt < 30; attempt += 1) {
      if (await isOriginReachable(origin)) {
        return origin;
      }

      await new Promise((resolve) => setTimeout(resolve, 250));
    }

    throw new Error(`Timed out waiting for T3 Code at ${origin}.`);
  }

  function attachProcessOutput(stream: NodeJS.ReadableStream | null, prefix: string) {
    if (!stream) {
      return;
    }

    stream.setEncoding("utf8");
    stream.on("data", (chunk) => {
      const message = String(chunk)
        .split(/\r?\n/u)
        .map((line) => line.trim())
        .filter(Boolean);

      for (const line of message) {
        console.log(`[t3:${prefix}] ${line}`);
      }
    });
  }

  async function ensureServerOrigin(): Promise<string> {
    const settings = currentSettings();
    const preferredRuntimeTarget = await resolvePreferredRuntimeTarget(settings);
    if (await isOriginReachable(preferredRuntimeTarget.origin)) {
      return preferredRuntimeTarget.origin;
    }

    const origin = configuredOrigin(settings.host, settings.port);
    if (await isOriginReachable(origin)) {
      return origin;
    }

    if (!settings.autoStartServer) {
      throw new Error(`T3 Code is unavailable at ${origin}. Enable auto-start or launch it manually.`);
    }

    if (managedServerStartPromise) {
      return managedServerStartPromise;
    }

    managedServerStartPromise = (async () => {
      if (!settings.companionRepoPath) {
        throw new Error("Configure the T3 companion repository path first.");
      }

      if (!t3ScriptExists(settings.companionRepoPath)) {
        throw new Error(`T3 companion script not found at ${t3ScriptPath(settings.companionRepoPath)}`);
      }

      if (managedServerProcess?.exitCode === null && managedServerProcess.killed === false) {
        return waitForOrigin(origin);
      }

      const inheritedDevArgs =
        preferredRuntimeTarget.kind === "dev"
          ? ["--dev-url", preferredRuntimeTarget.origin]
          : [];

      managedServerProcess = spawn(
        process.execPath,
        [
          "--import",
          "tsx",
          t3ScriptPath(settings.companionRepoPath),
          "serve",
          "--host",
          settings.host,
          "--port",
          String(settings.port),
          "--base-dir",
          settings.baseDir,
          ...inheritedDevArgs
        ],
        {
          cwd: bridgeWorkspaceRoot,
          env: {
            ...process.env,
            T3CODE_NO_BROWSER: "true"
          },
          stdio: ["ignore", "pipe", "pipe"]
        }
      );

      attachProcessOutput(managedServerProcess.stdout, "stdout");
      attachProcessOutput(managedServerProcess.stderr, "stderr");

      managedServerProcess.once("exit", (code) => {
        console.log(`[t3] managed server exited with status ${code}`);
        managedServerProcess = null;
      });

      managedServerProcess.once("error", (error) => {
        console.log(`[t3] managed server failed to launch: ${error.message}`);
      });

      return waitForOrigin(origin);
    })();

    try {
      return await managedServerStartPromise;
    } finally {
      managedServerStartPromise = null;
    }
  }

  async function issueOwnerToken(): Promise<string> {
    const settings = currentSettings();
    const runtimeTarget = await resolvePreferredRuntimeTarget(settings);
    const devArgs =
      runtimeTarget.kind === "dev"
        ? ["--dev-url", runtimeTarget.origin]
        : [];
    const output = await runT3Cli([
      "auth",
      "session",
      "issue",
      "--role",
      "owner",
      "--token-only",
      "--ttl",
      "15m",
      "--base-dir",
      settings.baseDir,
      ...devArgs
    ]);

    if (!output) {
      throw new Error("T3 Code did not return an owner session token.");
    }

    return output.split(/\r?\n/u).map((line) => line.trim()).find(Boolean) ?? output;
  }

  async function fetchSnapshot(): Promise<T3Snapshot> {
    const origin = await ensureServerOrigin();
    const token = await issueOwnerToken();
    const response = await fetch(`${origin}/api/orchestration/snapshot`, {
      headers: {
        Accept: "application/json",
        Authorization: `Bearer ${token}`
      },
      signal: AbortSignal.timeout(5_000)
    });

    const payload = await response.json().catch(() => null);
    if (!response.ok || !payload) {
      throw new Error(
        typeof payload?.error === "string"
          ? payload.error
          : `Unable to load T3 Code snapshot from ${origin}.`
      );
    }

    return payload as T3Snapshot;
  }

  async function dispatchCommand(command: Record<string, unknown>) {
    const origin = await ensureServerOrigin();
    const token = await issueOwnerToken();
    const response = await fetch(`${origin}/api/orchestration/dispatch`, {
      method: "POST",
      headers: {
        Accept: "application/json",
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify(command),
      signal: AbortSignal.timeout(5_000)
    });

    const payload = await response.json().catch(() => null);
    if (!response.ok) {
      throw new Error(
        typeof payload?.error === "string"
          ? payload.error
          : `Unable to dispatch a T3 Code command to ${origin}.`
      );
    }

    return payload;
  }

  return {
    async getHealth(): Promise<T3Health> {
      const settings = currentSettings();
      const runtimeTarget = await resolvePreferredRuntimeTarget(settings);
      const origin = runtimeTarget.origin;

      if (!settings.companionRepoPath) {
        return {
          status: "not-configured",
          detail: "Configure the T3 companion repository path to enable project sync.",
          origin
        };
      }

      if (!t3ScriptExists(settings.companionRepoPath)) {
        return {
          status: "unavailable",
          detail: `T3 companion script not found at ${t3ScriptPath(settings.companionRepoPath)}.`,
          origin
        };
      }

      try {
        const snapshot = await fetchSnapshot();
        return {
          status: "connected",
          detail: `Connected to T3 Code with ${snapshot.projects.filter((project) => project.deletedAt === null).length} active project(s).`,
          origin
        };
      } catch (error) {
        return {
          status: "error",
          detail: error instanceof Error ? error.message : String(error),
          origin
        };
      }
    },
    async listProjects(): Promise<Project[]> {
      const snapshot = await fetchSnapshot();
      return snapshot.projects
        .filter((project) => project.deletedAt === null)
        .sort((left, right) => left.title.localeCompare(right.title))
        .map((project) => {
          const metadata = projectMetadataStore.get(project.workspaceRoot);
          return {
            id: project.id,
            name: project.title,
            repoPath: project.workspaceRoot,
            platform: metadata.platform,
            supportsIosRun: projectSupportsIosRun({
              repoPath: project.workspaceRoot,
              platform: metadata.platform
            }),
            previewModes: metadata.previewModes
          };
        });
    },
    async listTasks(): Promise<ProviderTask[]> {
      const snapshot = await fetchSnapshot();
      return sortDescendingByIso(
        snapshot.threads
          .filter((thread) => thread.deletedAt === null)
          .map((thread) => mapThreadToTask(thread))
      );
    },
    async submitTask({
      projectId,
      prompt,
      interactionMode,
      reasoningEffort
    }: {
      projectId: string;
      prompt: string;
      interactionMode?: string;
      reasoningEffort?: string;
    }): Promise<ProviderTask> {
      const snapshot = await fetchSnapshot();
      const project = snapshot.projects.find(
        (candidate) => candidate.id === projectId && candidate.deletedAt === null
      );

      if (!project) {
        throw new Error(`Unknown T3 Code project: ${projectId}`);
      }

      const createdAt = new Date().toISOString();
      const threadId = crypto.randomUUID();
      const messageId = crypto.randomUUID();
      const selectedInteractionMode = normalizeInteractionMode(interactionMode);
      const selectedReasoningEffort = normalizeReasoningEffort(reasoningEffort);
      const modelSelection = modelSelectionWithReasoningEffort(
        project.defaultModelSelection ?? { ...DEFAULT_MODEL_SELECTION },
        selectedReasoningEffort
      );

      await dispatchCommand({
        type: "thread.create",
        commandId: crypto.randomUUID(),
        threadId,
        projectId,
        title: titleFromPrompt(prompt),
        modelSelection,
        interactionMode: selectedInteractionMode,
        runtimeMode: "full-access",
        branch: null,
        worktreePath: null,
        createdAt
      });

      await dispatchCommand({
        type: "thread.turn.start",
        commandId: crypto.randomUUID(),
        threadId,
        message: {
          messageId,
          role: "user",
          text: prompt,
          attachments: []
        },
        modelSelection,
        runtimeMode: "full-access",
        interactionMode: selectedInteractionMode,
        createdAt
      });

      const nextSnapshot = await fetchSnapshot();
      const createdThread = nextSnapshot.threads.find((thread) => thread.id === threadId);
      if (!createdThread) {
        throw new Error("T3 Code accepted the turn, but the new thread was not visible yet.");
      }

      return mapThreadToTask(createdThread);
    },
    async continueTask({
      taskId,
      prompt,
      interactionMode,
      reasoningEffort
    }: {
      taskId: string;
      prompt: string;
      interactionMode?: string;
      reasoningEffort?: string;
    }): Promise<ProviderTask> {
      const snapshot = await fetchSnapshot();
      const thread = findVisibleThread(snapshot, taskId);
      if (!thread) {
        throw new Error(`Unknown T3 Code thread: ${taskId}`);
      }

      const project = findThreadProject(snapshot, thread);
      if (!project) {
        throw new Error(`Unknown T3 Code project: ${thread.projectId}`);
      }

      const createdAt = new Date().toISOString();
      const messageId = crypto.randomUUID();
      const selectedInteractionMode = normalizeInteractionMode(interactionMode ?? thread.interactionMode);
      const selectedReasoningEffort = normalizeReasoningEffort(reasoningEffort);
      const modelSelection = modelSelectionWithReasoningEffort(
        thread.modelSelection ?? project.defaultModelSelection ?? { ...DEFAULT_MODEL_SELECTION },
        selectedReasoningEffort
      );

      await dispatchCommand({
        type: "thread.turn.start",
        commandId: crypto.randomUUID(),
        threadId: taskId,
        message: {
          messageId,
          role: "user",
          text: prompt,
          attachments: []
        },
        modelSelection,
        runtimeMode: thread.runtimeMode || "full-access",
        interactionMode: selectedInteractionMode,
        createdAt
      });

      const nextSnapshot = await fetchSnapshot();
      return mapThreadToTask(findVisibleThread(nextSnapshot, taskId) ?? thread);
    },
    async renderTaskFileDiff(taskId: string, filePath: string): Promise<string | null> {
      const snapshot = await fetchSnapshot();
      const thread = findVisibleThread(snapshot, taskId);
      if (!thread) {
        return null;
      }

      const checkpoint = latestCheckpoint(thread);
      const workspaceRoot = taskWorkspaceRoot(snapshot, thread);
      if (!checkpoint || !checkpoint.checkpointRef || !workspaceRoot) {
        return null;
      }

      if (!checkpoint.files.some((file) => file.path === filePath)) {
        throw new Error(`File ${filePath} was not captured in the latest T3 Code checkpoint.`);
      }

      const fromRef = checkpointRefForThreadTurn(thread.id, 0);
      const toRef = checkpoint.checkpointRef;

      try {
        const { stdout } = await execFileAsync(
          "git",
          ["diff", "--no-ext-diff", "--no-color", fromRef, toRef, "--", filePath],
          {
            cwd: workspaceRoot,
            maxBuffer: 12 * 1024 * 1024
          }
        );
        return stdout || `No diff was available for ${filePath}.`;
      } catch {
        const { stdout } = await execFileAsync(
          "git",
          ["diff", "--no-ext-diff", "--no-color", "HEAD", toRef, "--", filePath],
          {
            cwd: workspaceRoot,
            maxBuffer: 12 * 1024 * 1024
          }
        );
        return stdout || `No diff was available for ${filePath}.`;
      }
    },
    async undoLatestTaskTurn(taskId: string): Promise<ProviderTask> {
      const snapshot = await fetchSnapshot();
      const thread = findVisibleThread(snapshot, taskId);
      if (!thread) {
        throw new Error(`Unknown T3 Code thread: ${taskId}`);
      }

      const checkpoint = latestCheckpoint(thread);
      if (!checkpoint || checkpoint.checkpointTurnCount < 1) {
        throw new Error("This thread does not have a T3 Code checkpoint to undo.");
      }

      await dispatchCommand({
        type: "thread.checkpoint.revert",
        commandId: crypto.randomUUID(),
        threadId: taskId,
        turnCount: checkpoint.checkpointTurnCount - 1,
        createdAt: new Date().toISOString()
      });

      const nextSnapshot = await fetchSnapshot();
      return mapThreadToTask(findVisibleThread(nextSnapshot, taskId) ?? thread);
    },
    async renderTaskSummary(taskId: string): Promise<string | null> {
      const snapshot = await fetchSnapshot();
      const thread = findVisibleThread(snapshot, taskId);
      return thread ? renderThreadSummary(snapshot, thread) : null;
    }
  };
}

import { execFile, spawn } from "node:child_process";
import { mkdtemp, readFile, readdir, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join, relative } from "node:path";
import { promisify } from "node:util";
import type { Readable } from "node:stream";
import { projectSupportsIosRun, type Project } from "./project-capabilities.js";

const execFileAsync = promisify(execFile);
const MAX_EVENT_HISTORY = 1_000;
const MAX_LOG_TAIL = 400;

export type IosRunStatus = "queued" | "building" | "installing" | "launching" | "succeeded" | "failed" | "canceled";
export type IosRunPhase = "queued" | "discover" | "build" | "install" | "launch" | "done";
export type IosRunEventType = "state" | "phase" | "log" | "done" | "error";

export type IosRunLogEntry = {
  at: string;
  stream: "system" | "stdout" | "stderr";
  line: string;
};

export type IosRun = {
  id: string;
  projectId: string;
  projectName: string;
  status: IosRunStatus;
  phase: IosRunPhase;
  summary: string;
  createdAt: string;
  updatedAt: string;
  deviceId: string | null;
  deviceName: string | null;
  scheme: string | null;
  appPath: string | null;
  bundleIdentifier: string | null;
  logTail: IosRunLogEntry[];
};

export type IosRunEvent = {
  id: string;
  at: string;
  event: IosRunEventType;
  data: Record<string, unknown>;
};

type XcodeContainer = {
  path: string;
  kind: "workspace" | "project";
};

type DevicectlDevice = {
  identifier?: string;
  capabilities?: { featureIdentifier?: string }[];
  connectionProperties?: {
    pairingState?: string;
    transportType?: string;
    tunnelState?: string;
  };
  deviceProperties?: {
    name?: string;
  };
  hardwareProperties?: {
    platform?: string;
    reality?: string;
    udid?: string;
  };
};

type DevicectlListDevicesOutput = {
  result?: {
    devices?: DevicectlDevice[];
  };
};

type SpawnedProcessLike = ReturnType<typeof spawn>;

type SpawnProcess = typeof spawn;

function now(): string {
  return new Date().toISOString();
}

function makeRunId(): string {
  return `run-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

function cloneRun(run: IosRun): IosRun {
  return {
    ...run,
    logTail: run.logTail.map((entry) => ({ ...entry }))
  };
}

function sanitizeLogLine(line: string): string {
  return line.trim();
}

function attachLineStream(
  stream: Readable | null,
  streamName: "stdout" | "stderr",
  onLine: (stream: "stdout" | "stderr", line: string) => void
) {
  if (!stream) {
    return;
  }

  let buffer = "";
  stream.setEncoding("utf8");
  stream.on("data", (chunk: string | Buffer) => {
    buffer += String(chunk);
    const lines = buffer.split(/\r?\n/u);
    buffer = lines.pop() ?? "";
    for (const line of lines) {
      const trimmed = sanitizeLogLine(line);
      if (trimmed) {
        onLine(streamName, trimmed);
      }
    }
  });

  stream.on("end", () => {
    const trimmed = sanitizeLogLine(buffer);
    if (trimmed) {
      onLine(streamName, trimmed);
    }
  });
}

async function discoverXcodeContainers(repoPath: string): Promise<XcodeContainer[]> {
  const containers: XcodeContainer[] = [];
  const skippedDirectories = new Set([".git", "node_modules", "DerivedData", "build", ".build"]);

  async function visit(directory: string, depth: number) {
    if (depth > 3) {
      return;
    }

    let entries;
    try {
      entries = await readdir(directory, { withFileTypes: true });
    } catch {
      return;
    }

    for (const entry of entries) {
      if (!entry.isDirectory() || skippedDirectories.has(entry.name)) {
        continue;
      }

      const entryPath = join(directory, entry.name);
      if (entry.name.endsWith(".xcworkspace")) {
        containers.push({ path: entryPath, kind: "workspace" });
        continue;
      }

      if (entry.name.endsWith(".xcodeproj")) {
        containers.push({ path: entryPath, kind: "project" });
        continue;
      }

      await visit(entryPath, depth + 1);
    }
  }

  await visit(repoPath, 0);
  return containers.sort((left, right) => {
    if (left.kind !== right.kind) {
      return left.kind === "workspace" ? -1 : 1;
    }

    return relative(repoPath, left.path).localeCompare(relative(repoPath, right.path));
  });
}

async function pickScheme(repoPath: string, container: XcodeContainer): Promise<string> {
  const containerFlag = container.kind === "workspace" ? "-workspace" : "-project";
  const { stdout } = await execFileAsync("xcodebuild", ["-list", "-json", containerFlag, container.path], {
    cwd: repoPath,
    maxBuffer: 10 * 1024 * 1024
  });
  const parsed = JSON.parse(String(stdout)) as {
    workspace?: { schemes?: string[] };
    project?: { schemes?: string[] };
  };
  const schemes = parsed.workspace?.schemes ?? parsed.project?.schemes ?? [];
  const preferredScheme = schemes.find((scheme) => !/tests?$/iu.test(scheme)) ?? schemes[0];

  if (!preferredScheme) {
    throw new Error(`No shared Xcode schemes were found in ${basename(container.path)}.`);
  }

  return preferredScheme;
}

function isRunnableIosDevice(device: DevicectlDevice): boolean {
  const platform = device.hardwareProperties?.platform;
  const reality = device.hardwareProperties?.reality;
  const pairingState = device.connectionProperties?.pairingState;
  const tunnelState = device.connectionProperties?.tunnelState;
  const udid = device.hardwareProperties?.udid;
  const capabilities = device.capabilities ?? [];

  return platform === "iOS" &&
    reality === "physical" &&
    pairingState === "paired" &&
    tunnelState === "connected" &&
    typeof udid === "string" &&
    udid.length > 0 &&
    capabilities.some((capability) => capability.featureIdentifier === "com.apple.coredevice.feature.installapp");
}

async function pickDevice(): Promise<DevicectlDevice> {
  const outputDir = await mkdtemp(join(tmpdir(), "anywhere-devices-"));
  const jsonPath = join(outputDir, "devices.json");

  try {
    await execFileAsync("xcrun", ["devicectl", "list", "devices", "--timeout", "10", "--json-output", jsonPath], {
      maxBuffer: 10 * 1024 * 1024
    });

    const parsed = JSON.parse(await readFile(jsonPath, "utf8")) as DevicectlListDevicesOutput;
    const devices = parsed.result?.devices ?? [];
    const device = devices.find(isRunnableIosDevice);

    if (!device) {
      throw new Error("No connected iPhone was available to Xcode. Pair the phone with the Mac, enable Developer Mode, and make sure wireless debugging is connected.");
    }

    return device;
  } finally {
    void rm(outputDir, { force: true, recursive: true }).catch(() => undefined);
  }
}

async function findBuiltApp(derivedDataPath: string): Promise<string> {
  const productRoot = join(derivedDataPath, "Build", "Products");
  const apps: { path: string; mtimeMs: number }[] = [];

  async function visit(directory: string) {
    let entries;
    try {
      entries = await readdir(directory, { withFileTypes: true });
    } catch {
      return;
    }

    for (const entry of entries) {
      const entryPath = join(directory, entry.name);
      if (entry.isDirectory() && entry.name.endsWith(".app")) {
        const entryStat = await stat(entryPath);
        apps.push({ path: entryPath, mtimeMs: entryStat.mtimeMs });
        continue;
      }

      if (entry.isDirectory() && !entry.name.endsWith(".appex")) {
        await visit(entryPath);
      }
    }
  }

  await visit(productRoot);
  const app = apps.sort((left, right) => right.mtimeMs - left.mtimeMs)[0];

  if (!app) {
    throw new Error("Xcode completed, but no built .app bundle was found in DerivedData.");
  }

  return app.path;
}

async function readBundleIdentifier(appPath: string): Promise<string> {
  const infoPlistPath = join(appPath, "Info.plist");
  const { stdout } = await execFileAsync("plutil", ["-convert", "json", "-o", "-", infoPlistPath], {
    maxBuffer: 2 * 1024 * 1024
  });
  const parsed = JSON.parse(String(stdout)) as { CFBundleIdentifier?: string };
  const bundleIdentifier = parsed.CFBundleIdentifier?.trim();

  if (!bundleIdentifier) {
    throw new Error(`Built app at ${appPath} did not contain a CFBundleIdentifier.`);
  }

  return bundleIdentifier;
}

export function createIosRunManager({
  projectLookup,
  spawnProcess = spawn
}: {
  projectLookup: (projectId: string) => Project | null | Promise<Project | null>;
  spawnProcess?: SpawnProcess;
}) {
  const runs = new Map<string, IosRun>();
  const events = new Map<string, IosRunEvent[]>();
  const subscribers = new Map<string, Set<(event: IosRunEvent) => void>>();
  const activeChildren = new Map<string, SpawnedProcessLike>();

  function updateRun(runId: string, updates: Partial<IosRun>) {
    const current = runs.get(runId);
    if (!current) {
      return null;
    }

    const next: IosRun = {
      ...current,
      ...updates,
      updatedAt: now(),
      logTail: updates.logTail ?? current.logTail
    };
    runs.set(runId, next);
    return cloneRun(next);
  }

  function emit(runId: string, event: IosRunEventType, data: Record<string, unknown>) {
    const entry: IosRunEvent = {
      id: `${runId}-event-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`,
      at: now(),
      event,
      data
    };

    const runEvents = events.get(runId) ?? [];
    runEvents.push(entry);
    if (runEvents.length > MAX_EVENT_HISTORY) {
      runEvents.splice(0, runEvents.length - MAX_EVENT_HISTORY);
    }
    events.set(runId, runEvents);

    for (const subscriber of subscribers.get(runId) ?? []) {
      subscriber(entry);
    }
  }

  function setPhase(runId: string, phase: IosRunPhase, status: IosRunStatus, summary: string) {
    updateRun(runId, { phase, status, summary });
    emit(runId, "phase", { phase, status, message: summary });
    emit(runId, "state", { run: getRun(runId) });
  }

  function appendLog(runId: string, stream: IosRunLogEntry["stream"], line: string) {
    const entry = { at: now(), stream, line };
    const run = runs.get(runId);
    if (run) {
      const logTail = [...run.logTail, entry].slice(-MAX_LOG_TAIL);
      updateRun(runId, { logTail });
    }

    emit(runId, "log", entry);
  }

  async function runCommand(runId: string, command: string, args: string[], cwd: string) {
    appendLog(runId, "system", `$ ${[command, ...args].join(" ")}`);

    await new Promise<void>((resolve, reject) => {
      let settled = false;
      const child = spawnProcess(command, args, {
        cwd,
        env: process.env,
        stdio: ["ignore", "pipe", "pipe"]
      });
      activeChildren.set(runId, child);

      function settle(callback: () => void) {
        if (settled) {
          return;
        }

        settled = true;
        activeChildren.delete(runId);
        callback();
      }

      attachLineStream(child.stdout, "stdout", (stream, line) => {
        appendLog(runId, stream, line);
      });

      attachLineStream(child.stderr, "stderr", (stream, line) => {
        appendLog(runId, stream, line);
      });

      child.once("error", (error) => {
        settle(() => reject(error));
      });

      child.once("close", (code) => {
        settle(() => {
          if (runs.get(runId)?.status === "canceled") {
            resolve();
            return;
          }

          if (code === 0) {
            resolve();
            return;
          }

          reject(new Error(`${command} exited with status ${code}.`));
        });
      });
    });
  }

  async function executeRun(runId: string, project: Project) {
    const runRoot = join(tmpdir(), "anywhere-runs", runId);
    const derivedDataPath = join(runRoot, "DerivedData");

    try {
      setPhase(runId, "discover", "building", `Preparing to run ${project.name}.`);
      appendLog(runId, "system", `Project: ${project.repoPath}`);

      const [container] = await discoverXcodeContainers(project.repoPath);
      if (!container) {
        throw new Error(`No Xcode workspace or project was found under ${project.repoPath}.`);
      }

      appendLog(runId, "system", `Using ${container.kind}: ${container.path}`);
      const scheme = await pickScheme(project.repoPath, container);
      updateRun(runId, { scheme });
      appendLog(runId, "system", `Using scheme: ${scheme}`);

      const device = await pickDevice();
      const deviceId = device.hardwareProperties?.udid ?? null;
      const deviceName = device.deviceProperties?.name ?? deviceId;
      updateRun(runId, { deviceId, deviceName });
      appendLog(runId, "system", `Using device: ${deviceName ?? "iPhone"}`);

      const containerArgs = container.kind === "workspace"
        ? ["-workspace", container.path]
        : ["-project", container.path];
      const destination = deviceId ? `platform=iOS,id=${deviceId}` : "generic/platform=iOS";

      setPhase(runId, "build", "building", `Building ${project.name} for ${deviceName ?? "iPhone"}.`);
      await runCommand(
        runId,
        "xcodebuild",
        [
          ...containerArgs,
          "-scheme",
          scheme,
          "-configuration",
          "Debug",
          "-destination",
          destination,
          "-derivedDataPath",
          derivedDataPath,
          "-allowProvisioningUpdates",
          "-allowProvisioningDeviceRegistration",
          "build"
        ],
        project.repoPath
      );

      const appPath = await findBuiltApp(derivedDataPath);
      const bundleIdentifier = await readBundleIdentifier(appPath);
      updateRun(runId, { appPath, bundleIdentifier });
      appendLog(runId, "system", `Built app: ${appPath}`);
      appendLog(runId, "system", `Bundle identifier: ${bundleIdentifier}`);

      setPhase(runId, "install", "installing", `Installing ${project.name} on ${deviceName ?? "iPhone"}.`);
      await runCommand(
        runId,
        "xcrun",
        ["devicectl", "--timeout", "180", "device", "install", "app", "--device", deviceId ?? "", appPath],
        project.repoPath
      );

      setPhase(runId, "launch", "launching", `Launching ${project.name} on ${deviceName ?? "iPhone"}.`);
      await runCommand(
        runId,
        "xcrun",
        ["devicectl", "--timeout", "60", "device", "process", "launch", "--device", deviceId ?? "", "--terminate-existing", bundleIdentifier],
        project.repoPath
      );

      setPhase(runId, "done", "succeeded", `${project.name} is running on ${deviceName ?? "the device"}.`);
      emit(runId, "done", { run: getRun(runId) });
    } catch (error) {
      if (runs.get(runId)?.status === "canceled") {
        setPhase(runId, "done", "canceled", `Run canceled for ${project.name}.`);
        emit(runId, "done", { run: getRun(runId) });
        return;
      }

      const message = error instanceof Error ? error.message : String(error);
      appendLog(runId, "system", message);
      setPhase(runId, "done", "failed", message);
      emit(runId, "error", { message, run: getRun(runId) });
    } finally {
      activeChildren.delete(runId);
      if (!process.env.ANYWHERE_KEEP_RUN_DERIVED_DATA) {
        void rm(runRoot, { force: true, recursive: true }).catch(() => undefined);
      }
    }
  }

  function getRun(runId: string): IosRun | null {
    const run = runs.get(runId);
    return run ? cloneRun(run) : null;
  }

  async function startRun(projectId: string): Promise<IosRun> {
    const project = await projectLookup(projectId);
    if (!project) {
      throw new Error(`Unknown project: ${projectId}`);
    }

    if (!projectSupportsIosRun(project)) {
      throw new Error(`iOS runs are only available for iOS projects. ${project.name} is marked as ${project.platform}.`);
    }

    const createdAt = now();
    const run: IosRun = {
      id: makeRunId(),
      projectId: project.id,
      projectName: project.name,
      status: "queued",
      phase: "queued",
      summary: `Queued run for ${project.name}.`,
      createdAt,
      updatedAt: createdAt,
      deviceId: null,
      deviceName: null,
      scheme: null,
      appPath: null,
      bundleIdentifier: null,
      logTail: []
    };

    runs.set(run.id, run);
    events.set(run.id, []);
    emit(run.id, "state", { run: cloneRun(run) });
    queueMicrotask(() => {
      void executeRun(run.id, project);
    });

    return cloneRun(run);
  }

  function cancelRun(runId: string): IosRun | null {
    const run = runs.get(runId);
    if (!run) {
      return null;
    }

    if (run.status === "succeeded" || run.status === "failed" || run.status === "canceled") {
      return cloneRun(run);
    }

    updateRun(runId, {
      status: "canceled",
      phase: "done",
      summary: `Run canceled for ${run.projectName}.`
    });
    appendLog(runId, "system", "Run canceled from the phone.");
    activeChildren.get(runId)?.kill("SIGTERM");
    emit(runId, "done", { run: getRun(runId) });
    return getRun(runId);
  }

  function listRunEvents(runId: string): IosRunEvent[] {
    return (events.get(runId) ?? []).map((event) => ({
      ...event,
      data: { ...event.data }
    }));
  }

  function subscribe(runId: string, subscriber: (event: IosRunEvent) => void): () => void {
    const runSubscribers = subscribers.get(runId) ?? new Set<(event: IosRunEvent) => void>();
    runSubscribers.add(subscriber);
    subscribers.set(runId, runSubscribers);

    return () => {
      runSubscribers.delete(subscriber);
      if (runSubscribers.size === 0) {
        subscribers.delete(runId);
      }
    };
  }

  return {
    startRun,
    getRun,
    cancelRun,
    listRunEvents,
    subscribe
  };
}

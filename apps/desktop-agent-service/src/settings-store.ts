import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";

export type T3IntegrationSettings = {
  companionRepoPath: string;
  baseDir: string;
  host: string;
  port: number;
  autoStartServer: boolean;
};

export type CompanionSettings = {
  t3: T3IntegrationSettings;
};

export type CompanionSettingsInput = Partial<{
  t3: Partial<T3IntegrationSettings>;
}>;

const DEFAULT_T3_REPO_CANDIDATES = [
  process.env.T3CODE_COMPANION_PATH
].filter((value): value is string => typeof value === "string" && value.trim().length > 0);

function uniqueList(values: string[]): string[] {
  return Array.from(new Set(values));
}

function resolveDefaultT3RepoPath(): string {
  const candidate = uniqueList(DEFAULT_T3_REPO_CANDIDATES).find((value) => existsSync(value));
  return candidate ?? uniqueList(DEFAULT_T3_REPO_CANDIDATES)[0] ?? "";
}

function resolveDefaultT3BaseDir(): string {
  const configured = process.env.T3CODE_HOME?.trim();
  return configured ? resolve(configured) : join(homedir(), ".t3");
}

function defaultSettings(): CompanionSettings {
  return {
    t3: {
      companionRepoPath: resolveDefaultT3RepoPath(),
      baseDir: resolveDefaultT3BaseDir(),
      host: process.env.T3CODE_HOST?.trim() || "127.0.0.1",
      port: Number(process.env.T3CODE_PORT || 3773),
      autoStartServer: process.env.T3CODE_AUTO_START === "false" ? false : true
    }
  };
}

function normalizePort(value: number | undefined, fallback: number): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return fallback;
  }

  const normalized = Math.trunc(value);
  return normalized >= 1 && normalized <= 65_535 ? normalized : fallback;
}

function normalizeSettings(input: CompanionSettingsInput = {}, defaults = defaultSettings()): CompanionSettings {
  const companionRepoPath = input.t3?.companionRepoPath?.trim() ?? defaults.t3.companionRepoPath;
  const baseDir = input.t3?.baseDir?.trim() ?? defaults.t3.baseDir;
  const host = input.t3?.host?.trim() ?? defaults.t3.host;

  return {
    t3: {
      companionRepoPath: companionRepoPath ? resolve(companionRepoPath) : "",
      baseDir: resolve(baseDir),
      host: host || defaults.t3.host,
      port: normalizePort(input.t3?.port, defaults.t3.port),
      autoStartServer: input.t3?.autoStartServer ?? defaults.t3.autoStartServer
    }
  };
}

function writeSettings(storagePath: string, settings: CompanionSettings) {
  mkdirSync(dirname(storagePath), { recursive: true });
  writeFileSync(storagePath, `${JSON.stringify(settings, null, 2)}\n`, "utf8");
}

function loadSettings(storagePath: string): CompanionSettings {
  const defaults = defaultSettings();

  if (!existsSync(storagePath)) {
    writeSettings(storagePath, defaults);
    return defaults;
  }

  try {
    const parsed = JSON.parse(readFileSync(storagePath, "utf8")) as CompanionSettingsInput;
    const settings = normalizeSettings(parsed, defaults);
    writeSettings(storagePath, settings);
    return settings;
  } catch {
    writeSettings(storagePath, defaults);
    return defaults;
  }
}

export function createSettingsStore({ storagePath }: { storagePath: string }) {
  let settings = loadSettings(storagePath);

  function persist(nextSettings: CompanionSettings) {
    settings = nextSettings;
    writeSettings(storagePath, settings);
  }

  return {
    getSettings(): CompanionSettings {
      return JSON.parse(JSON.stringify(settings)) as CompanionSettings;
    },
    updateSettings(input: CompanionSettingsInput): CompanionSettings {
      const nextSettings = normalizeSettings(
        {
          t3: {
            ...settings.t3,
            ...input.t3
          }
        },
        settings
      );
      persist(nextSettings);
      return this.getSettings();
    },
    storagePath
  };
}

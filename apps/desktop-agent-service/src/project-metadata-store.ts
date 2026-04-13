import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

export type ProjectMetadata = {
  platform: string;
  previewModes: string[];
};

type ProjectMetadataRecord = Record<string, ProjectMetadata>;

const DEFAULT_METADATA: ProjectMetadata = {
  platform: "mobile",
  previewModes: ["artifacts", "web-preview"]
};

function cloneMetadata(metadata: ProjectMetadata): ProjectMetadata {
  return {
    platform: metadata.platform,
    previewModes: [...metadata.previewModes]
  };
}

function normalizeMetadata(input: Partial<ProjectMetadata> | undefined): ProjectMetadata {
  const platform = input?.platform?.trim().toLowerCase() || DEFAULT_METADATA.platform;
  const previewModes = Array.from(
    new Set(
      (input?.previewModes ?? DEFAULT_METADATA.previewModes)
        .map((mode) => mode.trim())
        .filter(Boolean)
    )
  );

  return {
    platform,
    previewModes: previewModes.length ? previewModes : [...DEFAULT_METADATA.previewModes]
  };
}

function writeMetadata(storagePath: string, metadata: ProjectMetadataRecord) {
  mkdirSync(dirname(storagePath), { recursive: true });
  writeFileSync(storagePath, `${JSON.stringify(metadata, null, 2)}\n`, "utf8");
}

function loadMetadata(storagePath: string): ProjectMetadataRecord {
  if (!existsSync(storagePath)) {
    writeMetadata(storagePath, {});
    return {};
  }

  try {
    const parsed = JSON.parse(readFileSync(storagePath, "utf8")) as Record<string, Partial<ProjectMetadata>>;
    const normalizedEntries = Object.entries(parsed).map(([workspaceRoot, metadata]) => [
      resolve(workspaceRoot),
      normalizeMetadata(metadata)
    ]);
    const normalized = Object.fromEntries(normalizedEntries);
    writeMetadata(storagePath, normalized);
    return normalized;
  } catch {
    writeMetadata(storagePath, {});
    return {};
  }
}

export function createProjectMetadataStore({ storagePath }: { storagePath: string }) {
  let metadata = loadMetadata(storagePath);

  function persist(nextMetadata: ProjectMetadataRecord) {
    metadata = nextMetadata;
    writeMetadata(storagePath, metadata);
  }

  return {
    get(workspaceRoot: string): ProjectMetadata {
      return cloneMetadata(metadata[resolve(workspaceRoot)] ?? DEFAULT_METADATA);
    },
    set(workspaceRoot: string, value: Partial<ProjectMetadata>) {
      const normalizedWorkspaceRoot = resolve(workspaceRoot);
      persist({
        ...metadata,
        [normalizedWorkspaceRoot]: normalizeMetadata(value)
      });
      return this.get(normalizedWorkspaceRoot);
    },
    remove(workspaceRoot: string) {
      const normalizedWorkspaceRoot = resolve(workspaceRoot);
      if (!(normalizedWorkspaceRoot in metadata)) {
        return false;
      }

      const nextMetadata = { ...metadata };
      delete nextMetadata[normalizedWorkspaceRoot];
      persist(nextMetadata);
      return true;
    },
    storagePath
  };
}

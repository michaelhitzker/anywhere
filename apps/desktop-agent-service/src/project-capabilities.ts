import { readdirSync } from "node:fs";
import { join } from "node:path";

export type Project = {
  id: string;
  name: string;
  repoPath: string;
  platform: string;
  supportsIosRun: boolean;
  previewModes: string[];
};

export function isIosAppProject(project: Pick<Project, "platform">): boolean {
  return project.platform.trim().toLowerCase() === "ios";
}

export function hasXcodeContainer(repoPath: string): boolean {
  const skippedDirectories = new Set([".git", "node_modules", "DerivedData", "build", ".build"]);

  function visit(directory: string, depth: number): boolean {
    if (depth > 3) {
      return false;
    }

    let entries;
    try {
      entries = readdirSync(directory, { withFileTypes: true });
    } catch {
      return false;
    }

    for (const entry of entries) {
      if (!entry.isDirectory() || skippedDirectories.has(entry.name)) {
        continue;
      }

      if (entry.name.endsWith(".xcworkspace") || entry.name.endsWith(".xcodeproj")) {
        return true;
      }

      if (visit(join(directory, entry.name), depth + 1)) {
        return true;
      }
    }

    return false;
  }

  return visit(repoPath, 0);
}

export function projectSupportsIosRun(project: Pick<Project, "platform" | "repoPath">): boolean {
  return isIosAppProject(project) || hasXcodeContainer(project.repoPath);
}

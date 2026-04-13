import type { Project } from "./project-capabilities.js";

export type ProviderStatus = {
  id?: string;
  label?: string;
  status: string;
  detail: string;
};

export type TaskLogEntry = {
  at: string;
  message: string;
};

export type TaskArtifact = {
  id: string;
  type: string;
  label: string;
  url: string;
  note: string;
};

export type TaskMessage = {
  id: string;
  role: string;
  text: string;
  createdAt: string;
  updatedAt: string;
};

export type TaskChangedFile = {
  path: string;
  status: string | null;
  additions: number;
  deletions: number;
};

export type ProviderTask = {
  id: string;
  title: string;
  projectId: string;
  prompt: string;
  providerId: string;
  branchName: string | null;
  worktreePath: string | null;
  createdAt: string;
  updatedAt: string;
  status: string;
  summary: string;
  messages: TaskMessage[];
  changedFiles: TaskChangedFile[];
  latestTurnCount: number | null;
  undoAvailable: boolean;
  logs: TaskLogEntry[];
  artifacts: TaskArtifact[];
  nextActions: string[];
};

export type TaskProcessSpec = {
  command: string;
  args: string[];
  cwd: string;
  env: Record<string, string>;
};

export type TaskProvider = {
  id: string;
  label: string;
  getStatus?: () => Promise<ProviderStatus>;
  createTaskProcess: (input: {
    task: ProviderTask;
    project: Project;
  }) => TaskProcessSpec;
};

export function createProviderRegistry({
  providers,
  defaultProviderId
}: {
  providers: TaskProvider[];
  defaultProviderId: string;
}) {
  const providerMap = new Map(providers.map((provider) => [provider.id, provider]));

  if (!providerMap.has(defaultProviderId)) {
    throw new Error(`Unknown default provider: ${defaultProviderId}`);
  }

  function getProvider(providerId: string): TaskProvider {
    const provider = providerMap.get(providerId);
    if (!provider) {
      throw new Error(`Unknown provider: ${providerId}`);
    }

    return provider;
  }

  async function getProviderStatus(providerId: string): Promise<ProviderStatus> {
    const provider = getProvider(providerId);
    if (!provider.getStatus) {
      return {
        id: provider.id,
        label: provider.label,
        status: "ready",
        detail: "Provider did not expose health information."
      };
    }

    const status = await provider.getStatus();
    return {
      id: provider.id,
      label: provider.label,
      ...status
    };
  }

  async function listProviderStatuses(): Promise<ProviderStatus[]> {
    return Promise.all(Array.from(providerMap.keys()).map((providerId) => getProviderStatus(providerId)));
  }

  return {
    defaultProviderId,
    getProvider,
    getDefaultProvider(): TaskProvider {
      return getProvider(defaultProviderId);
    },
    listProviders() {
      return Array.from(providerMap.values()).map((provider) => ({
        id: provider.id,
        label: provider.label
      }));
    },
    getProviderStatus,
    listProviderStatuses
  };
}

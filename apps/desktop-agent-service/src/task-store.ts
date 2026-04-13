import type { ProviderTask, TaskArtifact } from "./provider-registry.js";

let taskCounter = 0;

export type StoredTask = ProviderTask;

function timestamp(): string {
  return new Date().toISOString();
}

function buildTaskId(): string {
  taskCounter += 1;
  return `task-${Date.now()}-${taskCounter}`;
}

function cloneTask(task: StoredTask): StoredTask {
  return {
    ...task,
    messages: task.messages.map((message) => ({ ...message })),
    changedFiles: task.changedFiles.map((file) => ({ ...file })),
    logs: task.logs.map((entry) => ({ ...entry })),
    artifacts: task.artifacts.map((artifact) => ({ ...artifact })),
    nextActions: [...task.nextActions]
  };
}

export function createTaskStore() {
  const tasks = new Map<string, StoredTask>();

  function getTask(taskId: string): StoredTask | null {
    const task = tasks.get(taskId);
    return task ? cloneTask(task) : null;
  }

  function listTasks(): StoredTask[] {
    return Array.from(tasks.values())
      .sort((left, right) => right.createdAt.localeCompare(left.createdAt))
      .map(cloneTask);
  }

  function updateTask(taskId: string, updater: (task: StoredTask) => StoredTask): StoredTask | null {
    const current = tasks.get(taskId);
    if (!current) {
      return null;
    }

    const next = updater(current);
    next.updatedAt = timestamp();
    tasks.set(taskId, next);
    return cloneTask(next);
  }

  function createTask({
    projectId,
    prompt,
    providerId,
    branchName = null,
    worktreePath = null
  }: {
    projectId: string;
    prompt: string;
    providerId: string;
    branchName?: string | null;
    worktreePath?: string | null;
  }): StoredTask {
    const createdAt = timestamp();
    const taskId = buildTaskId();
    const task: StoredTask = {
      id: taskId,
      title: prompt,
      projectId,
      prompt,
      providerId,
      branchName,
      worktreePath,
      createdAt,
      updatedAt: createdAt,
      status: "queued",
      summary: "Task accepted by Anywhere Bridge.",
      messages: [
        {
          id: `${taskId}-message`,
          role: "user",
          text: prompt,
          createdAt,
          updatedAt: createdAt
        }
      ],
      changedFiles: [],
      latestTurnCount: null,
      undoAvailable: false,
      logs: [
        {
          at: createdAt,
          message: `Queued task for provider ${providerId}.`
        }
      ],
      artifacts: [],
      nextActions: [
        "Start provider run",
        "Stream logs to clients",
        "Collect preview output"
      ]
    };

    tasks.set(task.id, task);
    return cloneTask(task);
  }

  function appendLog(taskId: string, message: string): StoredTask | null {
    return updateTask(taskId, (task) => ({
      ...task,
      logs: [
        ...task.logs,
        {
          at: timestamp(),
          message
        }
      ]
    }));
  }

  function markRunning(
    taskId: string,
    updates: {
      summary?: string;
      branchName?: string | null;
      worktreePath?: string | null;
      nextActions?: string[];
    } = {}
  ): StoredTask | null {
    return updateTask(taskId, (task) => ({
      ...task,
      status: "running",
      summary: updates.summary ?? "Task is running in the selected provider.",
      branchName: updates.branchName ?? task.branchName,
      worktreePath: updates.worktreePath ?? task.worktreePath,
      nextActions: updates.nextActions ?? ["Watch live logs", "Review repo changes", "Collect preview artifacts"]
    }));
  }

  function markDone(
    taskId: string,
    updates: {
      summary?: string;
      artifacts?: TaskArtifact[];
      nextActions?: string[];
    } = {}
  ): StoredTask | null {
    return updateTask(taskId, (task) => ({
      ...task,
      status: "done",
      summary: updates.summary ?? "Task completed successfully.",
      artifacts: updates.artifacts ?? task.artifacts,
      nextActions: updates.nextActions ?? ["Review changes", "Inspect preview artifacts", "Decide whether to commit"]
    }));
  }

  function markFailed(
    taskId: string,
    updates: {
      summary?: string;
      nextActions?: string[];
    } = {}
  ): StoredTask | null {
    return updateTask(taskId, (task) => ({
      ...task,
      status: "failed",
      summary: updates.summary ?? "Task failed before completion.",
      nextActions: updates.nextActions ?? ["Inspect logs", "Adjust the prompt", "Retry the task"]
    }));
  }

  return {
    createTask,
    getTask,
    listTasks,
    appendLog,
    markRunning,
    markDone,
    markFailed
  };
}

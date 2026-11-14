import { fixtureModelSelection } from "./test-support/fixture-model-selection.mjs";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

async function powershell(command) {
  const { stdout } = await execFileAsync(
    "powershell.exe",
    ["-NoProfile", "-NonInteractive", "-Command", command],
    { maxBuffer: 64 * 1024 * 1024, windowsHide: true },
  );
  return JSON.parse(stdout);
}

function asArray(value) {
  if (value === null || value === undefined) return [];
  return Array.isArray(value) ? value : [value];
}

// Host counters come from Get-Process so they match the 2026-11-12/14 baseline
// (PrivateMemorySize64 is the commit charge, WorkingSet64 the resident set).
async function measure(pid) {
  const tree = asArray(
    await powershell(
      "Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,Name | ConvertTo-Json -Compress -Depth 2",
    ),
  );
  const children = new Map();
  for (const entry of tree) {
    const list = children.get(entry.ParentProcessId) ?? [];
    list.push(entry);
    children.set(entry.ParentProcessId, list);
  }
  const descendants = [];
  const queue = [pid];
  while (queue.length > 0) {
    for (const child of children.get(queue.shift()) ?? []) {
      descendants.push(child);
      queue.push(child.ProcessId);
    }
  }
  const ids = [pid, ...descendants.map((entry) => entry.ProcessId)];
  const counters = asArray(
    await powershell(
      `Get-Process -Id ${ids.join(",")} | Select-Object Id,PrivateMemorySize64,WorkingSet64,@{n='ThreadCount';e={$_.Threads.Count}} | ConvertTo-Json -Compress -Depth 2`,
    ),
  );
  const byId = new Map(counters.map((entry) => [entry.Id, entry]));
  const host = byId.get(pid);
  if (!host) throw new Error(`host process ${pid} disappeared while sampling`);
  let treeCommit = host.PrivateMemorySize64;
  let treeWorkingSet = host.WorkingSet64;
  let treeThreads = host.ThreadCount;
  for (const entry of descendants) {
    const counter = byId.get(entry.ProcessId);
    if (!counter) continue;
    treeCommit += counter.PrivateMemorySize64;
    treeWorkingSet += counter.WorkingSet64;
    treeThreads += counter.ThreadCount;
  }
  return {
    hostCommitBytes: host.PrivateMemorySize64,
    hostWorkingSetBytes: host.WorkingSet64,
    hostThreads: host.ThreadCount,
    treeCommitBytes: treeCommit,
    treeWorkingSetBytes: treeWorkingSet,
    treeThreads: treeThreads,
    processes: descendants.length + 1,
    children: descendants.map((entry) => entry.Name),
  };
}

const mb = (bytes) => Math.round((bytes / (1024 * 1024)) * 10) / 10;

// Thread owners come from ThreadQuerySetWin32StartAddress plus the host's own
// pdb, so each spawn site is named; the probe is a separate script because it
// needs dbghelp through P/Invoke.
async function probeThreadOwners(script, symbolPath, pid) {
  if (!script) return null;
  const { stdout } = await execFileAsync(
    "powershell.exe",
    [
      "-NoProfile",
      "-NonInteractive",
      "-File",
      script,
      "-ProcessId",
      String(pid),
      "-SymbolPath",
      symbolPath,
    ],
    { maxBuffer: 64 * 1024 * 1024, windowsHide: true },
  );
  return JSON.parse(stdout.trim().split(/\r?\n/).at(-1));
}

function threadOwnerGrowth(before, after) {
  if (!before || !after) return null;
  const baseline = new Map(
    before.groups.map((group) => [group.startAddress, group.count]),
  );
  return after.groups
    .map((group) => ({
      startAddress: group.startAddress,
      symbol: group.symbol,
      lines: group.lines,
      before: baseline.get(group.startAddress) ?? 0,
      after: group.count,
      added: group.count - (baseline.get(group.startAddress) ?? 0),
    }))
    .filter((entry) => entry.added !== 0)
    .sort((first, second) => second.added - first.added);
}

// After a cold restart the Tasks are back in Product state from history, but
// no Run has happened, so nothing has reopened their AgentCore Sessions.
export async function measureAfterRestart({
  pid,
  snapshot,
  poll,
  expectedTasks,
  settleMs = 8000,
}) {
  await poll(
    async () => (await snapshot()).taskIndex.length === expectedTasks,
    60_000,
    "task index reloaded after restart",
  );
  await new Promise((resolve) => setTimeout(resolve, settleMs));
  const sample = await measure(pid);
  return { tasks: expectedTasks, label: `${expectedTasks} (after restart)`, ...sample };
}

// Real Application/Bridge/Product/canonical Core; only model replies are
// fixtures. One completed Run per Task, so every Task holds an open AgentCore
// Session - the structural growth source issue #147 left unmeasured.
export async function runMemoryGrowthVertical({
  invoke,
  snapshot,
  poll,
  provider,
  textSse,
  pid,
  workspaceId,
  workspaceEpoch,
  catalog,
  total = 50,
  checkpoints = [0, 1, 5, 10, 20, 30, 40, 50],
  settleMs = 4000,
  threadProbeScript = null,
  symbolPath = "",
  deleteAtEnd = 10,
}) {
  const samples = [];
  const probes = [];
  const wanted = new Set(checkpoints.filter((value) => value <= total));
  wanted.add(total);
  const take = async (tasks, { probe = false, label = null } = {}) => {
    await new Promise((resolve) => setTimeout(resolve, settleMs));
    const sample = await measure(pid);
    samples.push({ tasks, label: label ?? String(tasks), ...sample });
    if (probe) {
      const owners = await probeThreadOwners(threadProbeScript, symbolPath, pid);
      if (owners) probes.push({ tasks, ...owners });
    }
    process.stdout.write(
      `tasks=${String(tasks).padStart(3)} host commit=${mb(sample.hostCommitBytes)}MB ws=${mb(sample.hostWorkingSetBytes)}MB threads=${sample.hostThreads} tree commit=${mb(sample.treeCommitBytes)}MB ws=${mb(sample.treeWorkingSetBytes)}MB procs=${sample.processes}\n`,
    );
    return sample;
  };
  const create = async () => {
    const modelSnapshot = await snapshot();
    const created = await invoke("metawork.tasks.create", {
      workspace: {
        kind: "manual",
        workspaceId,
        expectedWorkspaceEpoch: workspaceEpoch,
      },
      modelSelection: fixtureModelSelection(modelSnapshot),
      expectedSkillCatalogRevision: catalog.revision,
      expectedSkillSelectionRevision: catalog.selectionRevision,
      approvalMode: "manual",
    });
    assert.equal(created.accepted, true, JSON.stringify(created));
    return created.taskId;
  };
  const taskIds = [];
  if (wanted.has(0)) await take(0, { probe: true });
  for (let index = 1; index <= total; index += 1) {
    const taskId = await create();
    taskIds.push(taskId);
    provider.enqueue(
      textSse(`memory-growth-${index}`, `Measured reply ${index}.`),
    );
    const sent = await invoke("metawork.tasks.sendInput", {
      taskId,
      operationId: `memory-growth-${index}`,
      // "Review" is the harness provider's only accepted automatic-title input.
      input: { kind: "text", text: "Review" },
    });
    assert.equal(sent.outcome, "accepted", JSON.stringify(sent));
    await poll(
      async () => {
        const current = (await snapshot()).tasks.find(
          (task) => task.id === taskId,
        );
        return (
          current?.activeOperation === null &&
          current.runs.at(-1)?.terminal?.outcome === "completed"
        );
      },
      60_000,
      `memory growth Task ${index} completed`,
    );
    if (wanted.has(index)) await take(index, { probe: index === total });
  }
  // Deleting a Task closes its AgentCore Session, so what the deletion gives
  // back is what the Session owned.
  let afterDeletion = null;
  if (deleteAtEnd > 0 && taskIds.length >= deleteAtEnd) {
    const removed = taskIds.slice(0, deleteAtEnd);
    for (const taskId of removed) await invoke("metawork.tasks.delete", { taskId });
    await poll(
      async () => {
        const index = (await snapshot()).taskIndex;
        return removed.every((taskId) => !index.some((task) => task.id === taskId));
      },
      60_000,
      `${deleteAtEnd} Tasks physically deleted`,
    );
    afterDeletion = await take(total - deleteAtEnd, {
      probe: true,
      label: `${total} → ${total - deleteAtEnd} (deleted ${deleteAtEnd})`,
    });
  }
  const first = samples[0];
  const header =
    "| tasks | host commit MB | host WS MB | host threads | tree commit MB | tree WS MB | procs |\n| --- | --- | --- | --- | --- | --- | --- |";
  const rows = samples.map(
    (sample) =>
      `| ${sample.label} | ${mb(sample.hostCommitBytes)} | ${mb(sample.hostWorkingSetBytes)} | ${sample.hostThreads} | ${mb(sample.treeCommitBytes)} | ${mb(sample.treeWorkingSetBytes)} | ${sample.processes} |`,
  );
  const last =
    samples.find((sample) => sample.label === String(total)) ?? samples.at(-1);
  const growth = {
    tasks: last.tasks - first.tasks,
    hostCommitBytes: last.hostCommitBytes - first.hostCommitBytes,
    hostWorkingSetBytes: last.hostWorkingSetBytes - first.hostWorkingSetBytes,
    hostThreads: last.hostThreads - first.hostThreads,
    perTaskHostWorkingSetBytes: Math.round(
      (last.hostWorkingSetBytes - first.hostWorkingSetBytes) /
        Math.max(1, last.tasks - first.tasks),
    ),
    perTaskHostCommitBytes: Math.round(
      (last.hostCommitBytes - first.hostCommitBytes) /
        Math.max(1, last.tasks - first.tasks),
    ),
  };
  const ceilingProbe = probes.find((probe) => probe.tasks === total) ?? null;
  const threadGrowth = threadOwnerGrowth(probes[0] ?? null, ceilingProbe);
  const deletionReturn = afterDeletion
    ? {
        tasksDeleted: deleteAtEnd,
        hostCommitBytes: afterDeletion.hostCommitBytes - last.hostCommitBytes,
        hostThreads: afterDeletion.hostThreads - last.hostThreads,
        threadOwners: threadOwnerGrowth(probes.at(-1), ceilingProbe),
      }
    : null;
  return {
    scope:
      "Real Application/Bridge/Product/canonical Core on Windows; scripted model replies; one completed Run per Task",
    taskCount: taskIds.length,
    samples,
    growth,
    probes,
    threadGrowth,
    deletionReturn,
    table: [header, ...rows].join("\n"),
  };
}

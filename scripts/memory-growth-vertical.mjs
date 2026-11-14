// Windows measurement of how a Host grows with the number of Tasks that hold
// an open AgentCore Session. It is a manual measurement, not a Gate: it builds
// dozens of real Tasks and runs for minutes, so only its own explicit scope
// selects it and no default vertical set or CI job reaches it.
//
//   $env:METAWORK_MEMORY_GROWTH_ONLY = '1'
//   node scripts/run-agentcore-vertical-windows.mjs
//
// `METAWORK_MEMORY_GROWTH_TASKS` lowers the Task ceiling for a shorter repeat
// run. Evidence lands in `.zig-cache/memory-growth-vertical-evidence.json`
// with the checkpoint table, the per-spawn-site thread histogram and the
// artifact identity; the table is also printed.

import { fixtureModelSelection } from "./test-support/fixture-model-selection.mjs";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const maxProbeOutputBytes = 64 * 1024 * 1024;
// The probe lives beside this harness; callers own the artifact directory the
// symbols are resolved from, not the probe's location.
const threadOwnerProbe = fileURLToPath(
  new URL("./probe-windows-thread-owners.ps1", import.meta.url),
);
// The harness provider applies a frozen shape check to the automatic title
// Completion and accepts this single input; any other text fails the first Task.
const taskInput = "Review";

async function powershell(command) {
  const { stdout } = await execFileAsync(
    "powershell.exe",
    ["-NoProfile", "-NonInteractive", "-Command", command],
    { maxBuffer: maxProbeOutputBytes, windowsHide: true },
  );
  return parseProbeJson(stdout, command);
}

function parseProbeJson(stdout, source) {
  // Add-Type can precede the payload with compiler notices, so the JSON is the
  // last line rather than the whole stream.
  const payload = stdout.trim().split(/\r?\n/).at(-1) ?? "";
  try {
    return JSON.parse(payload);
  } catch (cause) {
    throw new Error(
      `memory growth probe returned no JSON for ${source}: ${payload.slice(0, 200)}`,
      { cause },
    );
  }
}

function asArray(value) {
  if (value === null || value === undefined) return [];
  return Array.isArray(value) ? value : [value];
}

// Host counters come from Get-Process: PrivateMemorySize64 is the commit
// charge, WorkingSet64 the resident set. The whole tree is sampled because a
// Session's cost can land in a child process instead of the Host.
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
    // A descendant that exited between the two queries contributes nothing;
    // the Host itself is required above.
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

// Thread owners come from ThreadQuerySetWin32StartAddress plus the Host's own
// pdb, so each spawn site is named; the probe is a separate script because it
// needs dbghelp through P/Invoke.
async function probeThreadOwners(symbolPath, pid) {
  const { stdout } = await execFileAsync(
    "powershell.exe",
    [
      "-NoProfile",
      "-NonInteractive",
      "-File",
      threadOwnerProbe,
      "-ProcessId",
      String(pid),
      "-SymbolPath",
      symbolPath,
    ],
    { maxBuffer: maxProbeOutputBytes, windowsHide: true },
  );
  const owners = parseProbeJson(stdout, "thread owner probe");
  // An empty histogram or an unresolved one means the pdb beside the artifact
  // was not loaded, which would silently cost the attribution this measurement
  // exists for.
  assert.ok(
    owners.groups?.length > 0,
    `thread owner probe attributed no thread of pid ${pid}`,
  );
  assert.ok(
    owners.groups.some((group) => group.symbol),
    `thread owner probe resolved no symbol from ${symbolPath}`,
  );
  return owners;
}

// Signed deltas per spawn site, over the union of both histograms: a site that
// disappears between the two samples is as interesting as a new one.
function threadOwnerDelta(before, after) {
  if (!before || !after) return null;
  const counts = (probe) =>
    new Map(probe.groups.map((group) => [group.startAddress, group]));
  const baseline = counts(before);
  const current = counts(after);
  return [...new Set([...baseline.keys(), ...current.keys()])]
    .map((startAddress) => {
      const group = current.get(startAddress) ?? baseline.get(startAddress);
      return {
        startAddress,
        symbol: group.symbol,
        lines: group.lines,
        before: baseline.get(startAddress)?.count ?? 0,
        after: current.get(startAddress)?.count ?? 0,
      };
    })
    .map((entry) => ({ ...entry, delta: entry.after - entry.before }))
    .filter((entry) => entry.delta !== 0)
    .sort((first, second) => Math.abs(second.delta) - Math.abs(first.delta));
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
  symbolPath,
  total = 50,
  checkpoints = [0, 1, 5, 10, 20, 30, 40, 50],
  settleMs = 4000,
  restartSettleMs = 8000,
  deleteAtEnd = 10,
}) {
  // Commit charge, working set and per-thread stack reservation are the
  // measured quantities, and the thread owner probe is Win32-only; there is no
  // reduced form of this measurement on another platform.
  assert.equal(
    process.platform,
    "win32",
    "The Task memory growth measurement requires Windows commit charge counters",
  );
  assert.ok(
    Number.isInteger(total) && total > 0,
    `memory growth Task total must be a positive integer, got ${total}`,
  );
  assert.ok(
    Number.isInteger(deleteAtEnd) && deleteAtEnd >= 0 && deleteAtEnd <= total,
    `memory growth deletion slice must fit the Task total, got ${deleteAtEnd}`,
  );
  assert.ok(
    symbolPath,
    "memory growth evidence requires the artifact directory",
  );
  const samples = [];
  const probes = [];
  const wanted = new Set(checkpoints.filter((value) => value <= total));
  wanted.add(total);
  const take = async (tasks, { probe = false, label = null } = {}) => {
    await new Promise((resolve) => setTimeout(resolve, settleMs));
    const sample = await measure(pid);
    samples.push({ tasks, label: label ?? String(tasks), ...sample });
    if (probe)
      probes.push({ tasks, ...(await probeThreadOwners(symbolPath, pid)) });
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
      input: { kind: "text", text: taskInput },
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
  assert.equal(
    samples.length,
    wanted.size,
    "every memory growth checkpoint must have produced a sample",
  );
  const first = samples[0];
  const ceiling =
    samples.find((sample) => sample.label === String(total)) ?? samples.at(-1);
  const ceilingProbe = probes.find((probe) => probe.tasks === total) ?? null;
  // Deleting a Task closes its AgentCore Session, so what the deletion gives
  // back is what the Session owned.
  let deletionReturn = null;
  if (deleteAtEnd > 0) {
    const removed = taskIds.slice(0, deleteAtEnd);
    for (const taskId of removed)
      await invoke("metawork.tasks.delete", { taskId });
    await poll(
      async () => {
        const index = (await snapshot()).taskIndex;
        return removed.every(
          (taskId) => !index.some((task) => task.id === taskId),
        );
      },
      60_000,
      `${deleteAtEnd} Tasks physically deleted`,
    );
    const afterDeletion = await take(total - deleteAtEnd, {
      probe: true,
      label: `${total} → ${total - deleteAtEnd} (deleted ${deleteAtEnd})`,
    });
    deletionReturn = {
      tasksDeleted: deleteAtEnd,
      hostCommitBytes: afterDeletion.hostCommitBytes - ceiling.hostCommitBytes,
      hostWorkingSetBytes:
        afterDeletion.hostWorkingSetBytes - ceiling.hostWorkingSetBytes,
      hostThreads: afterDeletion.hostThreads - ceiling.hostThreads,
      threadOwners: threadOwnerDelta(ceilingProbe, probes.at(-1)),
    };
  }
  const perTask = (bytes) =>
    Math.round(bytes / Math.max(1, ceiling.tasks - first.tasks));
  const report = {
    scope:
      "Real Application/Bridge/Product/canonical Core on Windows; scripted model replies; one completed Run per Task",
    platform: `${process.platform}-${process.arch}`,
    at: new Date().toISOString(),
    taskCount: taskIds.length,
    samples,
    growth: {
      tasks: ceiling.tasks - first.tasks,
      hostCommitBytes: ceiling.hostCommitBytes - first.hostCommitBytes,
      hostWorkingSetBytes:
        ceiling.hostWorkingSetBytes - first.hostWorkingSetBytes,
      hostThreads: ceiling.hostThreads - first.hostThreads,
      perTaskHostCommitBytes: perTask(
        ceiling.hostCommitBytes - first.hostCommitBytes,
      ),
      perTaskHostWorkingSetBytes: perTask(
        ceiling.hostWorkingSetBytes - first.hostWorkingSetBytes,
      ),
    },
    probes,
    threadGrowth: threadOwnerDelta(probes[0] ?? null, ceilingProbe),
    deletionReturn,
    limitations: [
      "Commit charge includes reserved-and-committed thread stacks, which is not resident memory",
      "Scripted model replies; one short completed Run per Task does not represent real conversation size",
      "Single machine, single run: absolute counters move with host load",
    ],
  };
  return {
    report,
    table: () => renderTable(report.samples),
    // After a cold restart the Tasks are back in Product state from history,
    // but no Run has happened, so nothing has reopened their AgentCore
    // Sessions. The restart sample belongs to the same evidence record.
    async measureAfterRestart({ pid: restartedPid }) {
      const expectedTasks = samples.at(-1).tasks;
      await poll(
        async () => (await snapshot()).taskIndex.length === expectedTasks,
        60_000,
        "task index reloaded after restart",
      );
      await new Promise((resolve) => setTimeout(resolve, restartSettleMs));
      const sample = await measure(restartedPid);
      const restarted = {
        tasks: expectedTasks,
        label: `${expectedTasks} (after restart)`,
        ...sample,
      };
      report.samples.push(restarted);
      report.afterRestart = restarted;
      return restarted;
    },
  };
}

function renderTable(samples) {
  const header =
    "| tasks | host commit MB | host WS MB | host threads | tree commit MB | tree WS MB | procs |\n| --- | --- | --- | --- | --- | --- | --- |";
  const rows = samples.map(
    (sample) =>
      `| ${sample.label} | ${mb(sample.hostCommitBytes)} | ${mb(sample.hostWorkingSetBytes)} | ${sample.hostThreads} | ${mb(sample.treeCommitBytes)} | ${mb(sample.treeWorkingSetBytes)} | ${sample.processes} |`,
  );
  return [header, ...rows].join("\n");
}

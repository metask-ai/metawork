// Renderer fixtures still describe a Run's Tool records as `tools`. The task
// page carries only their summary and file references, and the records arrive
// in pages. These helpers derive both the way the Host does.

/** Changes whenever the listed records change, like the Host's revision. */
function recordsRevision(tools) {
  let hash = 5381;
  for (const character of JSON.stringify(tools))
    hash = (hash * 33 + character.charCodeAt(0)) % 4294967291;
  return String(hash + 1);
}

function byOrder(left, right) {
  const a = BigInt(left.order ?? "0");
  const b = BigInt(right.order ?? "0");
  return a < b ? -1 : a > b ? 1 : 0;
}

/** The Run as a task page carries it: summary and references, no records. */
export function withToolSummary(run) {
  const tools = [...(run.tools ?? [])].sort(byOrder);
  const running = tools.filter((tool) => tool.state === "running");
  const media = [];
  const candidates = [];
  for (const tool of tools)
    tool.fileRefs.forEach((reference, index) => {
      if (reference.generatedImage || reference.generatedVideo)
        media.push(reference);
      if (!reference.generatedVideo && reference.displayPath)
        candidates.push({ order: BigInt(tool.order ?? "0"), index, reference });
    });
  candidates.sort((left, right) =>
    left.order === right.order
      ? right.index - left.index
      : left.order > right.order
        ? -1
        : 1,
  );
  const seen = new Set();
  const links = [];
  for (const { reference } of candidates) {
    if (seen.has(reference.displayPath)) continue;
    seen.add(reference.displayPath);
    links.push(reference);
  }
  // Records listed by the fixture decide the summary; otherwise keep the
  // Host's. The listed records stay on the object for the page cache.
  const derived = run.tools !== undefined || !run.toolLog;
  return {
    ...run,
    toolLog: derived
      ? {
          count: String(tools.length),
          revision: recordsRevision(tools),
          runningName: running.length === 1 ? running[0].name : null,
        }
      : run.toolLog,
    fileReferences:
      derived || !run.fileReferences
        ? { media, links, linksComplete: true }
        : run.fileReferences,
  };
}

/** The Run as the wire carries it: task-page shape without listed records. */
export function wireRunWithToolSummary(run) {
  const { tools: _records, ...wire } = withToolSummary(run);
  return wire;
}

/** A Task whose Runs are in task-page shape. */
export function withToolSummaries(task) {
  return { ...task, runs: task.runs.map(withToolSummary) };
}

/** Pages already read for each Run that lists records, as the view caches them. */
export function runToolsCacheFor(runs) {
  const cache = new Map();
  for (const run of runs) {
    if (!run.tools?.length) continue;
    cache.set(run.id, {
      revision: withToolSummary(run).toolLog.revision,
      tools: [...run.tools].sort(byOrder),
      nextAfterOrder: null,
      status: "ready",
    });
  }
  return cache;
}

/** A Tool page loader answering from the fixture's records. */
export function runToolsLoaderFor(runs, securityEpoch = "1") {
  return async (taskId, runId, afterOrder) => {
    const run = runs.find((entry) => entry.id === runId);
    const tools = [...(run?.tools ?? [])]
      .sort(byOrder)
      .filter((tool) => BigInt(tool.order) > BigInt(afterOrder));
    return {
      generation: "1",
      requestId: "1",
      state: run ? "ready" : "missing",
      securityEpoch,
      revision: run ? withToolSummary(run).toolLog.revision : "0",
      total: String(run?.tools?.length ?? 0),
      tools,
      nextAfterOrder: null,
    };
  };
}

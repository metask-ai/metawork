import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";

const exec = promisify(execFile);

// Actual macOS Host/Bridge/store/public SDK codec; no Renderer injection or
// private capacity query. RSS samples are observations, not a memory ceiling.
export async function runAttachmentCapacityVertical({
  invoke,
  snapshot,
  poll,
  provider,
  textSse,
  pid,
  workspaceId,
  workspaceEpoch,
  workspaceRoot,
  catalog,
  evidenceDir,
  pngFixture,
  maxOriginalPath,
  baselineOnly = false,
}) {
  assert.equal(process.platform, "darwin", "this RSS probe requires macOS");
  await mkdir(evidenceDir, { recursive: true });
  const small = join(workspaceRoot, "capacity-screenshot.png");
  const large = join(workspaceRoot, "capacity-entropy.png");
  await writeFile(small, pngFixture(100, 80, 120_000));
  await writeFile(large, pngFixture(1200, 900, 4_500_000));
  let nextBatch = 1000;
  const batches = [];
  const samples = [];
  let stage = "baseline";
  let samplingError;
  let sampleInFlight = false;
  const sample = async () => {
    if (sampleInFlight) return;
    sampleInFlight = true;
    try {
      const { stdout } = await exec("/bin/ps", [
        "-o",
        "rss=",
        "-p",
        String(pid),
      ]);
      const rssBytes = Number(stdout.trim()) * 1024;
      assert.ok(Number.isSafeInteger(rssBytes) && rssBytes > 0);
      samples.push({ stage, rssBytes, atMs: Date.now() });
    } catch (error) {
      samplingError ??= error;
    } finally {
      sampleInFlight = false;
    }
  };
  const timer = setInterval(() => {
    void sample();
  }, 20);
  const key = () => ({ generation: "1", batchId: String(nextBatch++) });
  async function add(path, count = 8) {
    const batch = key();
    process.stdout.write(
      `Attachment capacity ${stage}: begin batch ${batch.batchId} (${count} files)\n`,
    );
    const result = await invoke("metawork.attachments.beginAdd", {
      ...batch,
      ...(baselineOnly ? {} : { remainingFiles: 8 }),
      source: { kind: "native_paths", paths: Array(count).fill(path) },
    });
    if (result?.status === "ready") {
      assert.equal(result.attachments.length, count);
      batches.push({ ...batch, attachments: result.attachments });
    } else {
      const cancelled = await invoke("metawork.attachments.cancelAdd", batch);
      assert.equal(cancelled.status, "cleaned");
    }
    await sample();
    return result;
  }
  async function clear() {
    for (const batch of batches.splice(0)) {
      const result = await invoke("metawork.attachments.cancelAdd", {
        generation: batch.generation,
        batchId: batch.batchId,
      });
      assert.equal(result.status, "cleaned");
    }
    await sample();
  }
  const results = [];
  let releaseProvider = () => {};
  let primaryFailure;
  try {
    await sample();
    const scenarios = [
      { name: "old-pool-baseline", records: 8, path: small },
      { name: "common-multiple-drafts", records: 32, path: small },
      { name: "candidate-near-preview-limit", records: 128, path: large },
    ];
    for (const scenario of baselineOnly ? scenarios.slice(0, 1) : scenarios) {
      stage = scenario.name;
      const started = Date.now();
      for (let count = 0; count < scenario.records; count += 8)
        assert.equal((await add(scenario.path)).status, "ready");
      process.stdout.write(
        `Attachment capacity stage ${scenario.name}: ${scenario.records} records staged in ${Date.now() - started} ms\n`,
      );
      results.push({
        scenario: scenario.name,
        records: scenario.records,
        stagingMs: Date.now() - started,
      });
      if (scenario.records === 128) {
        assert.deepEqual(await add(small, 1), {
          status: "rejected",
          reason: "staging_capacity",
        });
        const admission = (await snapshot()).newTaskAdmission;
        const task = await invoke("metawork.tasks.create", {
          workspace: {
            kind: "manual",
            workspaceId,
            expectedWorkspaceEpoch: workspaceEpoch,
          },
          expectedExecutionGeneration: admission.activeGeneration,
          expectedSelectionRevision: admission.activeSelectionRevision,
          modelSelection: null,
          expectedSkillCatalogRevision: catalog.revision,
          expectedSkillSelectionRevision: catalog.selectionRevision,
          approvalMode: "manual",
        });
        assert.equal(task.accepted, true, JSON.stringify(task));
        let entered = false;
        const held = new Promise((resolve) => {
          releaseProvider = resolve;
        });
        provider.enqueue(async () => {
          entered = true;
          await held;
          return {
            body: textSse("attachment-capacity-root", "Fixture complete."),
            initialDelayMs: 0,
            frameDelayMs: 0,
          };
        });
        const root = await invoke("metawork.tasks.sendInput", {
          taskId: task.taskId,
          operationId: "attachment-capacity-root",
          input: {
            kind: "text",
            text: "Wait for the following attachment message.",
          },
        });
        assert.equal(root.outcome, "accepted", JSON.stringify(root));
        await poll(async () => entered, 20_000, "capacity Provider gate");
        stage = "task-acceptance-copy";
        const accepted = await invoke("metawork.tasks.sendInput", {
          taskId: task.taskId,
          operationId: "attachment-capacity-waiting",
          input: {
            kind: "multimodal",
            text: "Inspect these screenshots later.",
            attachmentTokens: batches[0].attachments.map((item) => item.token),
          },
        });
        assert.equal(accepted.outcome, "accepted", JSON.stringify(accepted));
        await sample();
        const waiting = (
          await snapshot({ taskId: task.taskId, includeManagement: false })
        ).tasks.find((item) => item.id === task.taskId);
        assert.ok(
          waiting.inputSubmissions.some(
            (item) =>
              item.submission.operationId === "attachment-capacity-waiting" &&
              item.state === "waiting",
          ),
        );
        // Waiting originals keep their resource records after grant consumption.
        assert.deepEqual(await add(small, 1), {
          status: "rejected",
          reason: "staging_capacity",
        });
        await invoke("metawork.tasks.stop", { taskId: task.taskId });
        releaseProvider();
        await poll(
          async () => {
            const current = (
              await snapshot({ taskId: task.taskId, includeManagement: false })
            ).tasks.find((item) => item.id === task.taskId);
            return (
              current.activeOperation === null &&
              current.inputSubmissions.every((item) => item.state !== "waiting")
            );
          },
          30_000,
          "capacity Stop and pending cleanup",
        );
        stage = "after-task-cleanup";
        assert.equal((await add(small, 1)).status, "ready");
        await sample();
      }
      stage = `${scenario.name}-released`;
      await clear();
    }
    if (!baselineOnly) {
      for (let cycle = 0; cycle < 3; cycle++) {
        stage = `repeat-${cycle + 1}`;
        for (let batch = 0; batch < 4; batch++)
          assert.equal((await add(large)).status, "ready");
        await clear();
      }
      stage = "maximum-original-byte-budget";
      assert.equal((await add(maxOriginalPath)).status, "ready");
      assert.deepEqual(await add(small, 1), {
        status: "rejected",
        reason: "staging_capacity",
      });
      await clear();
      stage = "byte-budget-recovered";
      assert.equal((await add(small, 1)).status, "ready");
      await clear();
    }
    if (samplingError) throw samplingError;
    const stages = [...new Set(samples.map((item) => item.stage))].map(
      (name) => {
        const values = samples
          .filter((item) => item.stage === name)
          .map((item) => item.rssBytes);
        return {
          stage: name,
          samples: values.length,
          minRssBytes: Math.min(...values),
          peakRssBytes: Math.max(...values),
        };
      },
    );
    const evidence = {
      baselineOnly,
      platform: `${process.platform}-${process.arch}`,
      at: new Date().toISOString(),
      source: baselineOnly
        ? "original Host native_paths, Product staging and public SDK codec"
        : "real Host native_paths, Product staging, public SDK codec, Task sendInput and Stop",
      results,
      stages,
      limitations: [
        "RSS sampling is 20 ms best effort and covers the Host process only",
        baselineOnly
          ? "8-record baseline must be run against the original executable"
          : "Compare the 8-record group with the separately recorded original executable baseline",
        "Synthetic PNG fixtures; no actual system picker/drop/paste gesture or Windows evidence",
        "No total-process memory SLO is inferred from bounded records",
      ],
    };
    await writeFile(
      join(
        evidenceDir,
        baselineOnly
          ? "attachment-capacity-baseline.json"
          : "attachment-capacity.json",
      ),
      JSON.stringify(evidence, null, 2) + "\n",
    );
    process.stdout.write(
      `Attachment capacity Host vertical passed: ${JSON.stringify(evidence)}\n`,
    );
    return evidence;
  } catch (error) {
    primaryFailure = error;
    throw error;
  } finally {
    clearInterval(timer);
    releaseProvider();
    try {
      await clear();
    } catch (error) {
      if (!primaryFailure) throw error;
      process.stderr.write(
        `Attachment probe cleanup also failed: ${error.message}\n`,
      );
    }
  }
}

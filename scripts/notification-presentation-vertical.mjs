import { fixtureModelSelection } from "./test-support/fixture-model-selection.mjs";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

// Real Application/Bridge/Product/canonical Core and the real Windows toast
// host; only model replies are fixtures.
//
// This vertical reads the screen because the defect it covers is what a banner
// LOOKS like, which no in-process assertion can see, and because the Run
// notification turns on `WM_ACTIVATEAPP` actually reaching the SDK's app-active
// register when the window is minimized. Windows composes banners without
// exposing them as enumerable windows, so presence is decided by comparing the
// banner anchor against a baseline captured moments earlier with nothing else
// driving the screen, and every capture is kept for a person to read.
export async function runNotificationPresentationVertical({
  invoke,
  snapshot,
  poll,
  provider,
  textSse,
  workspaceId,
  workspaceEpoch,
  catalog,
  repositoryRoot,
  evidenceDir,
  pid,
  hostLog,
}) {
  const evidence = {
    scope:
      "Real Application/Bridge/Product/canonical Core plus the real Windows toast host; model replies are fixtures",
    captures:
      "Each case keeps the banner anchor as a PNG beside this file; the text in them is the evidence for language consistency",
    cases: [],
  };
  const reader = join(repositoryRoot, "scripts", "read-windows-toast.ps1");
  const shell = async (...args) =>
    JSON.parse(
      (
        await execFileAsync(
          "powershell.exe",
          [
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            reader,
            ...args,
          ],
          { maxBuffer: 8 * 1024 * 1024 },
        )
      ).stdout,
    );
  const capture = (name, baseline) =>
    shell(
      "-Capture",
      join(evidenceDir, name),
      ...(baseline ? ["-Baseline", join(evidenceDir, baseline)] : []),
    );
  // A banner covers most of the anchor in flat, light, neutral pixels. A
  // window repainting behind it changes far less, and rarely that colour.
  const showsBanner = (reading) =>
    reading.changedFraction > 0.35 && reading.toastColouredFraction > 0.25;
  // Other applications raise banners into the same anchor, so a banner is
  // only this application's when its attribution strip — the icon and name
  // Windows draws above the content — matches the one case 1 recorded.
  const attribution = (name, match) =>
    shell(
      "-Attribution",
      join(evidenceDir, name),
      ...(match ? ["-Match", join(evidenceDir, match)] : []),
    );
  const isOurs = async (name) =>
    (await attribution(name, "attribution.png")).sameApplication === true;
  const waitForBanner = async (name, baseline, label, record = false) =>
    poll(
      async () => {
        const reading = await capture(name, baseline);
        if (!showsBanner(reading)) return null;
        if (record) {
          await attribution("attribution.png");
          return reading;
        }
        return (await isOurs(`attribution-${name}`)) ? reading : null;
      },
      40_000,
      label,
    );
  // Windows keeps a banner on screen for about five seconds, so an absence
  // has to be watched for longer than that to mean anything.
  const expectNoBanner = async (name, baseline, label) => {
    const readings = [];
    for (let attempt = 0; attempt < 10; attempt++) {
      const reading = await capture(`${name}-${attempt}.png`, baseline);
      readings.push(reading);
      if (showsBanner(reading))
        assert.equal(
          await isOurs(`attribution-${name}-${attempt}.png`),
          false,
          `${label}: ${JSON.stringify(reading)}`,
        );
      await new Promise((resolve) => setTimeout(resolve, 800));
    }
    return readings;
  };
  // Windows hides a banner by itself after about five seconds, but holds one
  // the pointer rests on indefinitely. Before each case the anchor is brought
  // back to the reference capture, closing a banner only when two independent
  // signals agree one is there — nothing else under the anchor is ever
  // clicked.
  const clearAnchor = async (label) =>
    poll(
      async () => {
        if (!showsBanner(await capture("clearing.png", "anchor-clear.png")))
          return true;
        await shell(
          "-Dismiss",
          "-Baseline",
          join(evidenceDir, "anchor-clear.png"),
        );
        return false;
      },
      40_000,
      label,
    );

  const chinese = {
    scheduleCompleted: "定时任务已完成",
    scheduleFailed: "定时任务失败",
    scheduleSkipped: "上一次运行仍在进行，本次运行已跳过",
    scheduleNeedsAttention: "定时任务需要处理",
    runCompleted: "任务已完成",
    runFailed: "任务失败",
    runNeedsApproval: "任务正在等待你的确认",
    openTaskAction: "查看任务",
  };
  const english = {
    scheduleCompleted: "Scheduled task completed",
    scheduleFailed: "Scheduled task failed",
    scheduleSkipped:
      "A run was skipped because the previous run is still active",
    scheduleNeedsAttention: "Scheduled task needs attention",
    runCompleted: "Task finished",
    runFailed: "Task failed",
    runNeedsApproval: "Task is waiting for your approval",
    openTaskAction: "View task",
  };
  const register = (table) =>
    invoke("metawork.host.notifications.registerText", table);

  const chromeGeneration = (
    await invoke("metawork.host.windowChrome.connect", {})
  ).generation;
  const minimize = () =>
    invoke("metawork.host.windowChrome.control", {
      generation: chromeGeneration,
      action: "minimize",
    });

  const create = async (title) => {
    const current = await snapshot();
    const created = await invoke("metawork.tasks.create", {
      workspace: {
        kind: "manual",
        workspaceId,
        expectedWorkspaceEpoch: workspaceEpoch,
      },
      modelSelection: fixtureModelSelection(current),
      expectedSkillCatalogRevision: catalog.revision,
      expectedSkillSelectionRevision: catalog.selectionRevision,
      approvalMode: "manual",
    });
    assert.equal(created.accepted, true, JSON.stringify(created));
    await invoke("metawork.tasks.rename", { taskId: created.taskId, title });
    return created.taskId;
  };
  const runToCompletion = async (taskId, operationId) => {
    provider.enqueue(async () => ({
      body: textSse("Done."),
      headers: { "content-type": "text/event-stream" },
    }));
    await invoke("metawork.tasks.sendInput", {
      taskId,
      operationId,
      input: { kind: "text", text: "Review" },
    });
    return poll(
      async () => {
        const task = (await snapshot()).tasks.find(
          (item) => item.id === taskId,
        );
        const run = task?.runs?.[task.runs.length - 1];
        return run && run.phase === "completed" ? run : null;
      },
      60_000,
      `Run completion for Task ${taskId}`,
    );
  };

  await rm(evidenceDir, { recursive: true, force: true });
  await mkdir(evidenceDir, { recursive: true });
  // The window is kept clear of the banner anchor throughout, so its own
  // repainting can never be read as a banner, and the pointer is parked away
  // from it, because Windows holds a hovered banner on screen indefinitely.
  await shell("-MoveClear", String(pid));
  await shell("-ParkCursor");
  // One reference capture of the anchor with nothing on it, taken after any
  // banner left over from an earlier run has had time to hide itself. Every
  // later reading is a comparison against a baseline taken from this clear
  // state, so a stale banner can never be read as this run's.
  await new Promise((resolve) => setTimeout(resolve, 9_000));
  await capture("anchor-clear.png");

  // 1. Minimized, with the Chinese table registered: the banner is raised,
  //    and `chinese-banner.png` is the evidence that every word of it is in
  //    that language — application name, Task title, body and button alike.
  assert.equal((await register(chinese)).registered, 8);
  await minimize();
  await clearAnchor("anchor clear before the Chinese case");
  await capture("baseline-chinese.png");
  const chineseTask = await create("整理本周进展");
  const chineseRun = await runToCompletion(chineseTask, "notify-chinese-1");
  const chineseBanner = await waitForBanner(
    "chinese-banner.png",
    "baseline-chinese.png",
    "minimized Chinese completion banner",
    // The first banner is this application's by construction: nothing else
    // had a reason to raise one, and its content is checked by eye. Its
    // attribution strip becomes the reference every later case matches.
    true,
  );
  evidence.cases.push({
    case: "a minimized completion raises a banner in the registered language",
    taskId: chineseTask,
    runId: chineseRun.id,
    registered: "zh-CN",
    expectedTitle: "整理本周进展",
    expectedBody: chinese.runCompleted,
    expectedAction: chinese.openTaskAction,
    banner: chineseBanner,
  });

  // 2. Re-registering follows a language change on the next banner, and a
  //    click on the banner BODY — not its button — brings the window forward
  //    and opens that Task.
  assert.equal((await register(english)).registered, 8);
  await minimize();
  await clearAnchor("anchor clear before the English case");
  await capture("baseline-english.png");
  const englishTask = await create("Weekly progress digest");
  const englishRun = await runToCompletion(englishTask, "notify-english-1");
  const englishBanner = await waitForBanner(
    "english-banner.png",
    "baseline-english.png",
    "minimized English completion banner",
  );
  const click = await shell("-Click");
  // The Host's own record of what the click did: the SDK logs the command it
  // dispatched, and that command names the Task the banner was raised for.
  const openCommand = `metawork.schedule.open.${englishTask}`;
  await poll(
    async () => hostLog().includes(openCommand),
    25_000,
    "a banner click dispatches its Task-open command",
  );
  const clicked = await shell("-ForegroundPid");
  evidence.cases.push({
    case: "re-registration changes the next banner, and a body click focuses the window and opens its Task",
    taskId: englishTask,
    runId: englishRun.id,
    registered: "en-US",
    expectedTitle: "Weekly progress digest",
    expectedBody: english.runCompleted,
    expectedAction: english.openTaskAction,
    banner: englishBanner,
    click,
    openCommand,
    foregroundPid: clicked.foregroundPid,
    appPid: pid,
  });
  assert.equal(clicked.foregroundPid, pid);

  // 3. That click raised the window through the application's own path, so
  //    the next completion is quiet: a banner over the window the user is
  //    reading says nothing the Task list does not. With case 1 this
  //    exercises the app-active register in both directions, using only the
  //    gestures a user actually makes.
  await shell("-MoveClear", String(pid));
  await clearAnchor("anchor clear before the foreground case");
  await capture("baseline-foreground.png");
  const foregroundTask = await create("前台完成不打扰");
  await runToCompletion(foregroundTask, "notify-foreground-1");
  const quiet = await expectNoBanner(
    "foreground",
    "baseline-foreground.png",
    "a foreground completion raises no banner",
  );
  assert.equal((await shell("-ForegroundPid")).foregroundPid, pid);
  evidence.cases.push({
    case: "a completion while the window is in front raises no banner",
    taskId: foregroundTask,
    foregroundPid: pid,
    changedFractions: quiet.map((reading) => reading.changedFraction),
  });

  // 4. A slot the Host cannot show is refused whole, and the table already
  //    registered keeps working. That is the production failure mode: the
  //    Host never holds a half-filled table, so no banner loses only some of
  //    its words.
  await assert.rejects(
    register({ ...chinese, openTaskAction: "查".repeat(64) }),
    "an over-long slot must be refused",
  );
  await minimize();
  await clearAnchor("anchor clear before the refusal case");
  await capture("baseline-refusal.png");
  const refusalTask = await create("Refused table keeps the last one");
  await runToCompletion(refusalTask, "notify-refusal-1");
  const refusalBanner = await waitForBanner(
    "refusal-banner.png",
    "baseline-refusal.png",
    "banner after a refused registration",
  );
  evidence.cases.push({
    case: "a refused registration keeps the table the Host already had",
    taskId: refusalTask,
    expectedBody: english.runCompleted,
    expectedAction: english.openTaskAction,
    banner: refusalBanner,
  });

  await writeFile(
    join(evidenceDir, "notification-presentation.json"),
    JSON.stringify(evidence, null, 2),
  );
  console.log(
    `Notification presentation vertical passed: ${evidence.cases.length} cases`,
  );
  return evidence;
}

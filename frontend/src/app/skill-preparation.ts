import type { WorkbenchSnapshot } from "../bridge/contracts.ts";

type Target = { taskId: string; bindingEpoch: string; generation: string };
type Result = { kind: "ready" } | { kind: "failed"; error: Error };
type Waiter = Target & {
  resolve: (value: Result) => void;
  timer: ReturnType<typeof setTimeout>;
  seen: boolean;
};

// Observes canonical snapshots during one user submission. It issues no
// commands, retries or Run replay; timeout preserves the submitted draft.
export class SkillPreparationCoordinator {
  private generation = "0";
  private latest: Pick<WorkbenchSnapshot, "tasks"> | null = null;
  private readonly waiters = new Set<Waiter>();

  resetGeneration(generation: string) {
    if (this.generation === generation) return;
    this.cancelAll("The Host connection changed while preparing Skills");
    this.generation = generation;
    this.latest = null;
  }

  observeSnapshot(
    snapshot: Pick<WorkbenchSnapshot, "tasks">,
    generation: string,
  ) {
    if (generation !== this.generation) return;
    this.latest = snapshot;
    for (const waiter of this.waiters) this.inspect(waiter);
  }

  wait(target: Target, timeoutMs: number): Promise<Result> {
    return new Promise((resolve) => {
      const waiter: Waiter = {
        ...target,
        resolve,
        seen: false,
        timer: setTimeout(
          () => this.fail(waiter, "Timed out preparing Skills"),
          timeoutMs,
        ),
      };
      this.waiters.add(waiter);
      this.inspect(waiter);
    });
  }

  cancelExceptTask(taskId: string | null) {
    for (const waiter of this.waiters)
      if (taskId !== waiter.taskId)
        this.fail(waiter, "The active Task changed while preparing Skills");
  }

  dispose() {
    this.cancelAll("Skill preparation was closed");
    this.generation = "0";
    this.latest = null;
  }

  private inspect(waiter: Waiter) {
    if (waiter.generation !== this.generation)
      return this.fail(
        waiter,
        "The Host connection changed while preparing Skills",
      );
    const task = this.latest?.tasks.find((value) => value.id === waiter.taskId);
    if (!task) {
      if (waiter.seen)
        this.fail(waiter, "The Task disappeared while preparing Skills");
      return;
    }
    waiter.seen = true;
    if (
      task.binding.epoch !== waiter.bindingEpoch ||
      task.archived ||
      task.lifecycle !== "open" ||
      task.activeOperation
    )
      return this.fail(waiter, "The Task changed while preparing Skills");
    if (task.skillCatalog.availability !== "loading")
      this.settle(waiter, { kind: "ready" });
  }

  private fail(waiter: Waiter, message: string) {
    this.settle(waiter, { kind: "failed", error: new Error(message) });
  }

  private settle(waiter: Waiter, result: Result) {
    if (!this.waiters.delete(waiter)) return;
    clearTimeout(waiter.timer);
    waiter.resolve(result);
  }

  private cancelAll(message: string) {
    for (const waiter of this.waiters) this.fail(waiter, message);
  }
}

export class SnapshotDemand {
  private latestRevision = 0n;
  private requestedRevision = 0n;
  private forced = false;
  private generation = "0";
  private failures = 0;
  private exhausted = false;

  beginGeneration(generation: string) {
    if (generation === this.generation) return;
    this.generation = generation;
    this.failures = 0;
    this.exhausted = false;
  }

  request(targetRevision?: bigint) {
    if (targetRevision === undefined) {
      this.forced = true;
      return;
    }
    if (targetRevision > this.requestedRevision)
      this.requestedRevision = targetRevision;
  }

  needsRefresh() {
    return !this.exhausted && this.hasPending();
  }

  hasPending() {
    return this.forced || this.requestedRevision > this.latestRevision;
  }

  beginAttempt() {
    this.forced = false;
  }

  failAttempt(): number | null {
    this.forced = true;
    this.failures += 1;
    if (this.failures >= 5) {
      this.exhausted = true;
      return null;
    }
    return [100, 250, 500, 1000][this.failures - 1]!;
  }

  resetRetry() {
    this.failures = 0;
    this.exhausted = false;
  }

  accept(revision: bigint) {
    if (revision < this.latestRevision) return false;
    this.latestRevision = revision;
    this.failures = 0;
    this.exhausted = false;
    return true;
  }
}

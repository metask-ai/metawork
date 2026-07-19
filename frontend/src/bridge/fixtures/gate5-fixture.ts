import type { NativeBridge } from "../client.ts";

type AgentBatchItem = {
  sessionId: string;
  runId: string;
  sequence: string;
  event?: unknown;
  object?: { id: string; bytes: number };
};
type AgentBatch = { generation: string; items: AgentBatchItem[] };
type AgentObject = {
  generation: string;
  sessionId: string;
  runId: string;
  sequence: string;
  event: unknown;
};

const fixtureCommands = {
  ack: "metawork.events.ack",
  fetch: "metawork.events.fetch",
  emit: "metawork.gate5.emitFixture",
} as const;
const fixtureEvent = "metawork:agent-events";

export function installGate5Fixture(
  bridge: NativeBridge,
  generation: () => string,
  onFailure: (error: unknown) => void,
) {
  let chain: Promise<void> = Promise.resolve();
  const remove = bridge.on<AgentBatch>(fixtureEvent, (batch) => {
    chain = chain
      .then(async () => {
        if (batch.generation !== generation()) return;
        for (const item of batch.items) {
          const inline = Object.prototype.hasOwnProperty.call(item, "event");
          if (inline === Boolean(item.object))
            throw new Error("Invalid Gate 5 Agent event envelope");
          if (item.object) {
            const fetched = await bridge.invoke<AgentObject>(
              fixtureCommands.fetch,
              {
                generation: batch.generation,
                sessionId: item.sessionId,
                runId: item.runId,
                objectId: item.object.id,
              },
            );
            if (
              fetched.generation !== batch.generation ||
              fetched.sessionId !== item.sessionId ||
              fetched.runId !== item.runId ||
              fetched.sequence !== item.sequence
            )
              throw new Error("Fetched Gate 5 event identity mismatch");
          }
          await bridge.invoke(fixtureCommands.ack, {
            generation: batch.generation,
            sessionId: item.sessionId,
            runId: item.runId,
            sequence: item.sequence,
          });
        }
      })
      .catch(onFailure);
  });
  return {
    emit: () => bridge.invoke(fixtureCommands.emit, {}),
    remove,
  };
}

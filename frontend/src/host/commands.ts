export const commands = {
  ping: "metawork.smoke.ping",
  pingAck: "metawork.smoke.eventAck",
  connect: "metawork.events.connect",
  disconnect: "metawork.events.disconnect",
  chooseWorkspace: "metawork.workspace.choose",
  snapshot: "metawork.workbench.snapshot",
  snapshotChunk: "metawork.workbench.snapshot.chunk",
  createSession: "metawork.sessions.create",
  run: "metawork.sessions.run",
  cancel: "metawork.sessions.cancel",
  respondUi: "metawork.sessions.respondUi",
  closeSession: "metawork.sessions.close",
  renameTask: "metawork.tasks.rename",
  archiveTask: "metawork.tasks.archive",
  deleteTask: "metawork.tasks.delete",
} as const;

export const events = {
  hostSignal: "metawork:host-signal",
  workbench: "metawork:workbench-changed",
} as const;

export const commands = {
  ping: "metawork.smoke.ping",
  pingAck: "metawork.smoke.eventAck",
  connect: "metawork.events.connect",
  disconnect: "metawork.events.disconnect",
  chooseWorkspace: "metawork.workspace.choose",
  snapshot: "metawork.workbench.snapshot",
  snapshotChunk: "metawork.workbench.snapshot.chunk",
  accountBeginLogin: "metawork.account.beginLogin",
  accountReauthenticate: "metawork.account.reauthenticate",
  accountCancelOperation: "metawork.account.cancelOperation",
  accountRefreshCatalog: "metawork.account.refreshCatalog",
  accountSelectApiKey: "metawork.account.selectApiKey",
  accountSelectModel: "metawork.account.selectModel",
  accountLogout: "metawork.account.logout",
  createTask: "metawork.tasks.create",
  run: "metawork.tasks.run",
  cancel: "metawork.tasks.cancel",
  respondUi: "metawork.tasks.respondUi",
  closeTask: "metawork.tasks.close",
  renameTask: "metawork.tasks.rename",
  archiveTask: "metawork.tasks.archive",
  deleteTask: "metawork.tasks.delete",
} as const;

export const events = {
  hostSignal: "metawork:host-signal",
  workbench: "metawork:workbench-changed",
} as const;

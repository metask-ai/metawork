export const RENDERER_BRIDGE_CONTRACT_ID = "metawork.renderer-bridge";
export const RENDERER_BRIDGE_CONTRACT_REVISION = 1 as const;

export const commands = {
  ping: "metawork.smoke.ping",
  pingAck: "metawork.smoke.eventAck",
  connect: "metawork.events.connect",
  disconnect: "metawork.events.disconnect",
  windowBeginDrag: "metawork.window.beginDrag",
  windowControl: "metawork.window.control",
  chooseWorkspace: "metawork.workspaces.choose",
  selectWorkspace: "metawork.workspaces.select",
  removeWorkspace: "metawork.workspaces.remove",
  refreshWorkspaceSkillCatalog: "metawork.workspaces.refreshSkillCatalog",
  refreshSkillCatalog: "metawork.skills.refreshCatalog",
  snapshot: "metawork.workbench.snapshot",
  snapshotChunk: "metawork.workbench.snapshot.chunk",
  accountBeginLogin: "metawork.account.beginLogin",
  accountReopenLogin: "metawork.account.reopenLogin",
  accountReauthenticate: "metawork.account.reauthenticate",
  accountCancelOperation: "metawork.account.cancelOperation",
  accountRefreshCatalog: "metawork.account.refreshCatalog",
  accountSelectApiKey: "metawork.account.selectApiKey",
  accountSelectModel: "metawork.account.selectModel",
  accountLogout: "metawork.account.logout",
  createTask: "metawork.tasks.create",
  run: "metawork.tasks.run",
  refreshTaskSkillCatalog: "metawork.tasks.refreshSkillCatalog",
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

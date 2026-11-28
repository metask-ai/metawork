export const enUS = {
  "task.project_change_body":
    "Changing the project keeps this chat’s working directory.",
  "task.project_change_not_confirmed":
    "The project change is not confirmed. Refresh to check its current assignment.",
  "task.project": "Project",
  "task.no_project": "No project",
  "task.project_removed": "Project removed",
  "task.add_project": "Add project",
  "task.add_project_failed":
    "Could not add the project. Choose its folder again.",
  "task.move_to_project": "Move to project",
  "task.change_project": "Change project",
  "task.project_change_failed":
    "Could not change the project. Refresh and try again.",
  "task.draft_preserved":
    "Your original draft was kept. You are viewing the destination project’s draft.",
  "workspace.directory_capacity":
    "The working directory limit is reached. Choose a previously registered directory.",
  "mutation.reason.schedule_persistence_unavailable":
    "Schedule storage is unavailable. Open Scheduled tasks to recover it before trying again.",
  "mutation.reason.handoff_changed":
    "The task or account changed. Reopen task details.",
  "mutation.reason.history_unavailable":
    "Session history could not be saved. Try again shortly.",
  "mutation.reason.schedule_persistence_failed":
    "Schedule storage could not be updated. Open Scheduled tasks to recover it before trying again.",
  "mutation.reason.schedule_persistence_outcome_unknown":
    "The schedule update could not be confirmed. Open Scheduled tasks to recover it before trying again.",
  "feedback.details": "Technical details",
  "feedback.dismiss": "Dismiss this notice",
  "feedback.open": "View feedback ({count})",
  "feedback.account": "View account operation result",
  "account.feedback.title": "Latest account operation result",
  "account.feedback.sending": "Sending account request…",
  "account.feedback.received":
    "Account request received. Its outcome is awaiting current state confirmation.",
  "account.feedback.unknown":
    "The account operation outcome is not confirmed. Check the current account state before deciding what to do next.",
  "account.feedback.rate_limited":
    "The latest account request was rate limited. Try again later.",
  "account.feedback.service_unavailable":
    "The latest account request could not finish because Metask was unavailable at the time.",
  "account.feedback.credential_read":
    "Could not read the sign-in credentials saved on this device.",
  "account.feedback.credential_write":
    "Could not save the sign-in credentials on this device.",
  "account.feedback.credential_delete":
    "Could not remove the sign-in credentials from this device.",
  "run.model_error.category.authentication":
    "The model service could not verify your credentials.",
  "run.model_error.category.permission":
    "The model service did not grant permission for this request.",
  "run.model_error.category.payment_required":
    "The model service reported a payment issue.",
  "run.model_error.category.not_found":
    "The model service could not find the requested model or resource.",
  "run.model_error.category.invalid_request":
    "The model service did not accept this request.",
  "run.model_error.category.context_window":
    "This conversation exceeds the model's context limit.",
  "run.model_error.category.rate_limited":
    "The model service is limiting request frequency.",
  "run.model_error.category.overloaded": "The model service is busy.",
  "run.model_error.category.server_error":
    "The model service encountered an error while handling this request.",
  "run.model_error.category.timeout":
    "The model service did not respond in time.",
  "run.model_error.category.connection":
    "Could not connect to the model service.",
  "run.model_error.category.stream_interrupted":
    "Receiving the model response was interrupted.",
  "run.model_error.category.output_limit":
    "This response reached the model's output limit.",
  "run.model_error.category.unknown":
    "The model service could not complete this request.",
  "run.model_error.reason.metask_insufficient_balance":
    "Your Metask balance and plan quota are insufficient.",
  "run.model_error.reason.metask_account_suspended":
    "Your Metask account is suspended. See the Metask website for details.",
  "run.guidance.review_context":
    "Shorten your next message or compact the conversation when available.",
  "run.guidance.revise_instruction":
    "Revise the instruction or narrow the request before continuing.",
  "run.guidance.wait": "Please try again later.",
  "run.guidance.prepare_retry":
    "Review the original instruction before sending again.",
  "run.guidance.review_changes":
    "Review any resulting changes before continuing.",
  "run.guidance.review_permissions": "Check the permissions before continuing.",
  "run.guidance.review_image_input":
    "Confirm that the selected model supports image input, then add the images again.",
  "run.provider_failure.no_response_title": "Could not generate a response",
  "run.provider_failure.partial_title": "The response is incomplete",
  "run.model_error.open_account": "Open account settings",
  "run.model_error.open_models": "Open model settings",
  "run.model_error.supplemental":
    "The following model error also occurred. The main reason this request ended is shown above.",
  "run.model_error.message_hidden":
    "The model error message was removed for privacy.",
  "run.model_error.upstream_truncated":
    "The model service detail was truncated upstream.",
  "run.model_error.host_redacted":
    "MetaWork removed sensitive content from this detail.",
  "run.model_error.host_truncated":
    "MetaWork shows only part of this detail because it is too long.",
  "run.model_error.diagnostic_withheld":
    "Additional technical details are stored on this device and cannot be shown here.",
  "run.model_error.diagnostic_absent":
    "No additional technical details were provided.",
  "run.model_error.category_label": "Model error category",
  "run.model_error.agent_run": "Agent execution ID",
  "run.model_error.code": "Service error code",
  "run.model_error.type": "Service error type",
  "run.model_error.requestId": "Service request ID",
  "run.model_error.attempts": "Attempts for this request",
  "run.model_error.retry_label": "Trying the request again",
  "run.model_error.retry.retryable":
    "Another request may work. This does not mean earlier tool actions can safely be repeated.",
  "run.model_error.retry.not_retryable":
    "Sending the same request unchanged is unlikely to help.",
  "run.model_error.retry.unknown":
    "It is unknown whether resending this request would help.",
  "run.model_error.retry_after": "Suggested retry delay",
  "run.model_error.empty": "(empty)",
  "archive.success": "Task archived. Find it in Settings → Archived tasks.",
  "archive.undo": "Undo",
  "archive.view": "View",
  "archive.reading": "This task is archived. Restore it to continue.",
  "archive.back": "Back to archived tasks",
  "archive.restore": "Restore task",

  "settings.archived_tasks": "Archived tasks",
  "archive.search": "Search archived tasks",
  "archive.count": "Total: {count}",
  "archive.filtered_count": "{matched} of {count}",
  "archive.empty": "Archived tasks will appear here.",
  "archive.no_results": "No matching tasks.",
  "archive.sync_unavailable":
    "Task list is unavailable. Reconnect to manage archived tasks.",
  "archive.history_read_only": "Update MetaWork to modify this saved task.",
  "archive.deleting": "Deleting task…",
  "task.stop_and_delete": "Stop and delete",
  "model_setup.title": "Get started with MetaWork",
  "model_setup.body":
    "Sign in with Metask to use models, or configure your own model service.",
  "model_setup.body_metask":
    "Sign in with Metask to choose a model and start a task.",
  "model_setup.configure": "Configure your own models",
  "model_setup.skip": "Skip for now",
  "model_setup.start": "Get started",
  "model_setup.other_options": "Other options",
  "model_setup.retry": "Retry",
  "model_setup.unconfigured": "No model configured",
  "model_setup.required":
    "Sign in or configure a model before sending. Your draft will be kept.",
  "model_setup.sign_in":
    "Sign in with Metask to use this model. Your draft will be kept.",
  "model_setup.authorizing":
    "Complete sign-in in your browser. Your draft will be kept.",
  "model_setup.cancel_login": "Cancel sign-in",
  "model_setup.loading": "Loading models…",
  "model_setup.unconfirmed":
    "Can't confirm your sign-in yet. Your text is kept.",
  "model_setup.recovering":
    "Connecting to Metask. You can send once it's connected; your text is kept.",
  "model_setup.unreachable":
    "Can't reach Metask right now. MetaWork keeps retrying; your text is kept.",
  "model_setup.preparing": "Preparing the model…",
  "model_setup.choose": "Choose an available model before sending.",
  "model_setup.custom_models_unavailable":
    "Custom model configuration cannot be read, so custom models are unavailable for now. Metask models work as usual.",
  "model_setup.account_suspended":
    "Your Metask account is suspended. See the Metask website for details.",
  "model_setup.catalog_failed":
    "Models could not be loaded. Retry loading them.",
  "model_setup.no_models":
    "No conversation models are available for this Metask account. Retry or review Models settings.",
  "model_setup.model_unavailable":
    "The selected model is unavailable. Choose another available model or review its configuration.",
  "model_setup.provider_unavailable":
    "Your model service is not ready. Review its configuration and test a model.",
  "model_setup.execution_unavailable":
    "The selected model is unavailable. Choose an available model or review its configuration.",
  "model_setup.view_schedules": "View scheduled tasks",
  "model_setup.schedule_unavailable":
    "Schedule storage is unavailable, so the execution configuration could not be updated.",
  "model_setup.schedule_failed":
    "Schedule data could not be saved, so the execution configuration could not be updated.",
  "model_setup.schedule_unknown":
    "The schedule save outcome is unknown, so the execution configuration could not be updated.",
  "model_setup.resources_unavailable":
    "The execution configuration could not be prepared because local resources are insufficient.",
  "common.loading": "Loading…",
  "app.name": "MetaWork",
  "app.account_and_application_menu": "Account and application menu",
  "app.toggle_sidebar": "Toggle task sidebar",
  "app.toggle_navigation": "Toggle navigation drawer",
  "app.navigation": "Primary navigation",
  "app.workbench": "Workbench",
  "app.workbench_tools": "Workbench tools",
  "inbox.title": "Messages",
  "inbox.toggle_conversations": "Toggle conversation list",
  "inbox.unavailable": "MetaTeam messaging is not connected",
  "inbox.title_unread": "Messages, {count} unread",
  "inbox.unavailable_hint":
    "Install and enable the MetaTeam connection to see team messages here.",
  "inbox.open_connectors": "Open connectors",
  "inbox.checking": "Connecting to MetaTeam…",
  "inbox.reauthorize": "Reconnect MetaTeam or confirm this device",
  "inbox.reauthorize_hint":
    "MetaTeam refused this device's authorization: it may have expired, or this device may not be confirmed in MetaTeam yet. Confirm the device or reinstall the MetaTeam connection, then retry.",
  "inbox.unreachable": "MetaTeam messages can't be read right now",
  "inbox.unreachable_stale":
    "MetaTeam messages can't be read right now. Showing what was read at {time}.",
  "inbox.retry": "Retry",
  "inbox.people_search": "Search members",
  "inbox.people_loading": "Reading members…",
  "inbox.people_failed": "Members can't be read right now.",
  "inbox.people_forbidden": "This device may not list members.",
  "inbox.people_none": "No matching members.",
  "inbox.composer_label": "Message {name}",
  "inbox.composer_placeholder": "Write a message…",
  "inbox.send": "Send",
  "inbox.sending": "Sending…",
  "inbox.send_failed":
    "The message wasn't sent, or MetaTeam didn't confirm it. Retrying won't send it twice.",
  "inbox.send_busy": "Another message is still being sent.",
  "inbox.send_unavailable": "MetaTeam isn't connected right now.",
  "inbox.send_unknown_peer":
    "MetaTeam gave no username for this member, so this conversation can't be replied to yet.",
  "inbox.send_rejected":
    "MetaTeam refused this message. Change it to send again.",
  "inbox.send_forbidden": "This device may not send this message.",
  "inbox.send_not_found": "MetaTeam can't find this recipient.",
  "inbox.diagnostics": "Request details",
  "inbox.no_members": "No members yet",
  "inbox.loading_conversations": "Loading conversations…",
  "inbox.load_earlier_conversations": "Load earlier conversations",
  "inbox.loading_messages": "Loading messages…",
  "inbox.load_earlier_messages": "Load earlier messages",
  "inbox.conversation_failed": "This conversation can't be read right now",
  "inbox.conversation_forbidden": "This device may not read this conversation",
  "inbox.conversation_not_found": "MetaTeam can't find this conversation",
  "inbox.conversation_unread": "{name}, {count} unread",
  "inbox.pick_conversation": "Select a member",
  "inbox.pick_hint":
    "Choose someone from the list to read your history or send a message.",
  "inbox.preview_self": "You: {text}",
  "inbox.sender_self": "You",
  "inbox.self_conversation": "Me",
  "inbox.sent_by_agent": "Sent by {agent}",
  "inbox.new_message": "New",
  "inbox.read": "Read",
  "inbox.not_read": "Unread",
  "inbox.read_at": "Read {time}",
  "inbox.receipts": "Read status",
  "inbox.receipt": "{name}: {status}",
  "inbox.list_separator": ", ",
  "inbox.message_truncated":
    "This message is too long; only its beginning is shown.",
  "inbox.attachment_unknown": "Linked item #{id}",
  "inbox.attachment_task": "Task #{id}",
  "inbox.attachment_file": "File #{id}",
  "inbox.attachment_project": "Project #{id}",
  "inbox.item_number": "#{id}",
  "inbox.detail_back": "Back",
  "inbox.task_state": "State",
  "inbox.task_created_by": "Created by",
  "inbox.task_last_note": "Latest note",
  "inbox.task_notes": "Earlier notes",
  "inbox.task_more": "More information",
  "inbox.task_description": "Task description",
  "inbox.task_children": "Sub-tasks",
  "inbox.progress_plan": "Unclaimed",
  "inbox.progress_todo": "To do",
  "inbox.progress_doing": "In progress",
  "inbox.progress_done": "Done",
  "inbox.state_active": "Active",
  "inbox.state_closed": "Closed",
  "inbox.state_deleted": "Deleted",
  "inbox.file_size": "Size",
  "inbox.file_type": "Type",
  "inbox.file_tag": "Category",
  "inbox.file_by": "Uploaded by",
  "inbox.file_preview": "Preview",
  "inbox.file_preview_truncated": "Only the beginning is shown.",
  "inbox.download": "Download",
  "inbox.download_opening": "Opening…",
  "inbox.download_opened": "Opened in your browser.",
  "inbox.download_unavailable": "This file has no download.",
  "inbox.download_failed": "The download couldn't be opened.",
  "inbox.project_file_tags": "Categories",
  "inbox.project_file_tag": "{tag} · {count}",
  "inbox.project_files": "Files",
  "inbox.project_no_files": "No files.",
  "inbox.project_files_more": "More files exist than are shown.",
  "handoff.both_drafts":
    "The session already has a draft. Finish that draft, then return to the message to retrieve this one.",
  "handoff.unavailable": "Local session links are unavailable",
  "handoff.loading": "Loading work sessions…",
  "handoff.history": "View history",
  "handoff.reauthorize": "Open session and check directory",
  "handoff.continue": "Continue in workbench",
  "handoff.choose": "Choose a session or draft",
  "handoff.choose_session": "Choose session",
  "handoff.default": "Default",
  "handoff.quote": "Quote original message",
  "handoff.prefer": "Set as default",
  "handoff.unlink": "Unlink",
  "handoff.resume": "Resume draft",
  "handoff.another": "Start another session",
  "handoff.new": "Start a work session",
  "handoff.link": "Link session",
  "handoff.pick": "Choose an existing session",
  "handoff.other": "Other options",
  "handoff.search": "Search sessions or directories",
  "handoff.confirm_open": "Confirm link and open",
  "handoff.no_matches": "No matching sessions",
  "handoff.no_candidates": "No work sessions available to link",
  "handoff.change_failed":
    "Could not confirm the change. Reopen details to check.",
  "handoff.workdir": "Choose a working directory to send.",
  "handoff.source_task": "Source task",
  "handoff.task_prompt":
    "Check the latest progress on MetaTeam task #{id}, then continue working on it.",
  "handoff.prompt_too_long":
    "The suggested prompt exceeds the input limit for a work session draft.",
  "handoff.pending":
    "The creation result is unconfirmed. The directory and model are locked.",
  "handoff.check": "Check creation result",
  "handoff.store_failed": "The draft could not be saved. Check local storage.",
  "handoff.quote_failed":
    "The current draft cannot accept this quote. Your draft was preserved.",
  "handoff.stale":
    "The task or account has changed. Reopen the message details.",
  "handoff.recovered":
    "Work session found. Review the input in that session before sending.",
  "handoff.not_created": "No session was created. You can edit and send again.",
  "inbox.task_loading": "Reading the task…",
  "inbox.task_failed": "This task can't be read right now.",
  "inbox.task_forbidden": "This device may not view this task.",
  "inbox.task_not_found":
    "MetaTeam can't find this task; it may have been deleted.",
  "inbox.task_id": "Number",
  "inbox.task_status": "Progress",
  "inbox.task_assignees": "Assigned to {names}",
  "inbox.task_path": "Location",
  "inbox.task_updated": "Updated",
  "app.resize_sidebar": "Resize task sidebar",
  "app.resize_task_panel": "Resize side panel",
  "app.dismiss_panels": "Dismiss panels",
  "app.language": "Language",
  "app.language.en-US": "English",
  "app.language.zh-CN": "简体中文",
  "app.language.pseudo": "Pseudo-locale",
  "window.controls": "Window controls",
  "window.minimize": "Minimize",
  "window.maximize": "Maximize",
  "window.restore": "Restore",
  "window.close": "Close",
  "common.save": "Save",
  "common.saving": "Saving…",
  "common.edit": "Edit",
  "common.remove": "Remove",
  "common.cancel": "Cancel",
  "common.close": "Close",
  "common.ok": "OK",
  "time.just_now": "Just now",
  "copy.input": "Copy input",
  "copy.response": "Copy response",
  "copy.code": "Copy code",
  "copy.copied": "Copied",
  "copy.failed": "Copy failed",
  "link.open_failed": "Couldn’t open this link.",
  "settings.about": "About",
  "settings.about_product": "About {product}",
  "about.current_version": "Current version",
  "about.visit_website": "Visit website",
  "about.contact_us": "Contact us",
  "about.developer": "Developer",
  "about.developer_name": "Metask",
  "about.version": "Version",
  "updates.section": "Version updates",
  "updates.available": "Update available",
  "updates.open": "View new version {version}",
  "updates.new_version": "Version {version} is available",
  "updates.check": "Check for updates",
  "updates.retry": "Retry check",
  "updates.checking": "Checking for updates…",
  "updates.check_hint": "Check whether a new version is available.",
  "updates.latest": "You’re up to date.",
  "updates.check_failed": "Couldn’t check for updates. Try again later.",
  "updates.last_known":
    "This check failed. This is the last confirmed version.",
  "updates.download": "Download update",
  "updates.preparing": "Checking the download link…",
  "updates.browser_opened": "Sent to your browser. Check the download there.",
  "updates.package_missing":
    "The update package for this platform is not available yet. Visit the website.",
  "updates.link_invalid":
    "The download link is unavailable. Download from the website.",
  "updates.version_changed":
    "The version information changed. Check for updates again.",
  "updates.download_unavailable":
    "The download link is temporarily unavailable. Retry or visit the website.",
  "updates.browser_failed": "Couldn’t open your browser. Try again later.",
  "updates.action_unavailable":
    "This action is unavailable. Check the current status before retrying.",
  "updates.command_unknown":
    "The outcome couldn’t be confirmed. Check the current status or your browser before retrying.",
  "updates.website": "Download website",
  "updates.diagnostics": "Check details",
  "updates.diagnostic_line":
    "Stage: {phase} · Reason: {cause} · Took: {elapsed}",
  "updates.phase.admission": "starting the request",
  "updates.phase.resolve": "finding the server",
  "updates.phase.connect": "connecting",
  "updates.phase.send": "sending the request",
  "updates.phase.head": "waiting for a reply",
  "updates.phase.body": "reading the reply",
  "updates.phase.complete": "finishing",
  "updates.cause.invalid_request":
    "the request was rejected before it was sent",
  "updates.cause.dns_failed": "the server address could not be found",
  "updates.cause.connect_failed": "the connection could not be opened",
  "updates.cause.tls_failed": "the secure connection failed",
  "updates.cause.write_failed": "the request could not be sent",
  "updates.cause.read_failed": "the reply could not be read",
  "updates.cause.invalid_response": "the reply was not usable",
  "updates.cause.response_too_large": "the reply was too large",
  "updates.cause.out_of_memory": "there was not enough memory",
  "updates.cause.resource_limit": "too many requests were already running",
  "updates.cause.cancelled": "the check was stopped",
  "updates.cause.deadline_exceeded": "the time limit ran out",
  "updates.elapsed.under_1s": "under a second",
  "updates.elapsed.under_5s": "a few seconds",
  "updates.elapsed.under_15s": "over five seconds",
  "updates.elapsed.over_15s": "over fifteen seconds",
  "connection.connecting": "Connecting…",
  "connection.connected": "Connected.",
  "connection.recovered": "Connection restored.",
  "connection.failed": "Connection unavailable",
  "connection.failed_help":
    "The content already shown remains available. Retry syncing to continue.",
  "connection.contract_failed": "Could not load MetaWork",
  "connection.contract_failed_help":
    "The received data does not match the expected format. Check the technical details. If this continues, close and reopen MetaWork.",
  "connection.component_mismatch": "MetaWork components do not match",
  "connection.component_mismatch_help":
    "Close MetaWork, then rebuild or reinstall the matching application components before reopening it.",
  "connection.retry": "Reconnect",
  "connection.retrying": "Reconnecting…",
  "connection.retry_sync": "Retry syncing",
  "connection.sync_retrying": "Restoring sync…",
  "connection.details": "Technical details",
  "connection.source.bootstrap": "Renderer contract",
  "connection.source.snapshot": "Product snapshot contract",
  "connection.source.revision": "Product state update",
  "connection.source.host_signal_ack": "Host acknowledgement",
  "connection.source.host_signal": "Host signal",
  "connection.refresh_failed": "Sync failed",
  "account.label": "Metask account",
  "account.provider": "Metask",
  "account.signed_in": "Signed in",
  "account.signed_out": "Not signed in",
  "account.ready": "Ready",
  "account.checking.title": "Checking sign-in",
  "account.checking.body":
    "MetaWork is checking whether this device can sign in.",
  "account.unconfirmed.title": "Can't confirm your sign-in yet",
  "account.unconfirmed.body":
    "MetaWork keeps retrying. You won't need to sign in again once it's back.",
  "account.sign_in_required.title": "Sign in to MetaWork",
  "account.sign_in_required.body":
    "Use your Metask account to load the models available to you.",
  "account.authorizing.title": "Finishing Metask sign-in",
  "account.authorizing.body":
    "Complete authorization in your browser if it is still open. MetaWork will continue automatically.",
  "account.action_failed": "Account action needs attention",
  "account.error.no_models":
    "No conversation models are available for this Metask account. Refresh the catalog or check the account in Metask and retry.",
  "account.error.deadline":
    "Metask did not respond in time. Check your connection.",
  "account.error.browser":
    "MetaWork could not open the sign-in page. Try opening it again.",
  "account.error.authorization":
    "The Metask sign-in could not be completed. Start sign-in again.",
  "account.error.refresh":
    "Sign-in refresh could not be completed. Sign in again.",
  "account.error.service":
    "Metask is temporarily unavailable. Check your connection or service status.",
  "account.error.metask_access":
    "Metask rejected this sign-in credential. Sign in again.",
  "account.error.credentials":
    "MetaWork could not confirm the credential update on this device.",
  "account.error.refresh_schedule":
    "Automatic sign-in refresh could not be scheduled. Retry now to restore it.",
  "account.error.local":
    "MetaWork could not finish preparing this task on this device. Try again.",
  "account.error.generic": "MetaWork could not finish preparing this account.",
  "account.cancelled": "The account action was cancelled.",
  "account.operation.loading_keys": "Loading API Keys",
  "account.operation.selecting_key": "Choose an API Key",
  "account.login": "Sign in with Metask",
  "account.login_short": "Sign in",
  "account.api_key": "API Key",
  "account.model": "Model",
  "account.choose_key": "Choose an API Key",
  "account.choose_model": "Choose a model",
  "account.cancel": "Cancel current action",
  "account.refresh_catalog": "Sync again",
  "account.retry_refresh": "Retry sign-in refresh",
  "account.retry_now": "Try again now",
  "account.login_again": "Sign in again",
  "account.clear_residue": "Clear sign-in again",
  "account.logout": "Sign out",
  "account.logout_confirm":
    "After you sign out, you can't use Metask models until you sign in again. Your custom models, local tasks and history, and workspace files will remain.",
  "account.logout_stops_tasks.one":
    "{count} task is using Metask models and will stop when you sign out.",
  "account.logout_stops_tasks.other":
    "{count} tasks are using Metask models and will stop when you sign out.",
  "account.command_rejected":
    "That account action is no longer available. MetaWork kept the latest account state.",
  "account.command_failed":
    "MetaWork could not complete that account action. Use the recovery action shown here.",
  "account.recharge_open_failed":
    "MetaWork could not open the Metask recharge page. Try again shortly.",
  "execution.command_rejected":
    "The model settings were not updated. Refresh and try again.",
  "execution.command_failed": "Model configuration result not yet confirmed",
  "account.cancel_rejected":
    "That account action has already finished. MetaWork checked the latest state.",
  "account.cancel_failed":
    "MetaWork could not cancel the account action. It will still stop at its Host deadline.",
  "account.updated": "Metask account updated.",
  "execution.updated": "Model settings updated.",
  "operation.account": "Updating the Metask account",
  "operation.execution": "Updating model settings",
  "operation.account_cancel": "Cancelling the Metask account action",
  "workspace.label": "Workspace",
  "workspace.select": "Choose working directory",
  "workspace.add": "Open local folder",
  "workspace.working_directory": "Working directory",
  "workspace.automatic_directory": "No working directory",
  "workspace.grant_ready": "Ready to start a task in this trusted workspace.",
  "workspace.selection_cancelled": "Workspace selection cancelled.",
  "workspace.selection_failed":
    "The workspace could not be opened. Choose it again.",
  "workspace.selection_capacity":
    "The project limit has been reached. Remove a project entry to add another.",
  "workspace.grant_confirmed": "Workspace selected.",
  "workspace.access_required":
    "This workspace is unavailable. Select the folder again.",
  "workspace.access_required_short": "Directory unavailable",
  "workspace.confirm_access": "Select folder again",
  "workspace.actions": "Project actions for {title}",
  "workspace.new_conversation": "New conversation",
  "workspace.new_conversation_for": "New conversation in “{title}”",
  "workspace.remove": "Remove project",
  "workspace.remove_failed": "Could not remove the project. Please try again.",
  "workspace.open": "Open project folder",
  "workspace.open_failed.workspace_unavailable":
    "Could not open the project folder because the project has changed. Refresh and try again, or choose the project again.",
  "workspace.open_failed.directory_unavailable":
    "Could not open the project folder. Check that it is still available and try again.",
  "workspace.open_failed.system_open_failed":
    "The system file manager could not open the project folder. Please try again.",
  "workspace.open_failed.request_failed":
    "Could not open the project folder. Please try again.",
  "workspace.remove_title": "Remove project “{title}”?",
  "workspace.remove_body":
    "Tasks and their history will be kept, and tasks in progress are unaffected. You can add the project again at any time.",
  "workspace.remove_close_failed":
    "Some tasks could not be closed. Folder access has been retained.",
  "workspace.removing_short": "Removing",
  "task.list": "Tasks",
  "task.recent": "Recent",
  "task.projects": "Projects",
  "task.project_empty": "No tasks in this project yet.",
  "task.count.one": "{count} task",
  "task.count.other": "{count} tasks",
  "task.item": "Task {id}",
  "task.new": "New task",
  "task.open": "Open a task",
  "skills.title": "Skills",
  "skills.builtin": "Built-in",
  "mcp.title": "Connectors",
  "mcp.subtitle": "Connect external tools and choose what new tasks can use.",
  "mcp.clear_search": "Clear search",
  "mcp.search_placeholder": "Search connectors and tools",
  "mcp.section.attention": "Needs attention",
  "mcp.section.available": "Available connectors",
  "mcp.section.disabled": "Disabled",
  "mcp.status.ready": "Ready",
  "mcp.status.connecting": "Connecting",
  "mcp.status.not_loaded": "Not loaded",
  "mcp.status.disabled": "Disabled",
  "mcp.status.needs_authentication": "Sign-in required",
  "mcp.status.unreachable": "Cannot connect",
  "mcp.status.invalid_catalog": "Invalid tool catalog",
  "mcp.transport.stdio": "Local · STDIO",
  "mcp.transport.streamable_http": "Remote · HTTP",
  "mcp.access.not_allowed": "Not allowed",
  "mcp.access.restart_required": "Connecting",
  "mcp.access.unavailable": "Unavailable to new tasks",
  "mcp.banner.applying.title": "Connecting to services",
  "mcp.banner.applying.body":
    "Launching connections, checking the MCP handshake, and discovering tools.",
  "mcp.banner.apply_failed.title": "Connection changes were not applied",
  "mcp.banner.apply_failed.body":
    "Your settings are saved. Open a service to retry its connection or sign in again.",
  "mcp.apply.action": "Retry connection",
  "mcp.apply.started":
    "Connection requested. Authorization will be recovered first when needed.",
  "mcp.apply.busy": "Another connector operation is still running.",
  "mcp.apply.unavailable": "Connectors are currently unavailable.",
  "mcp.apply.rejected": "The saved settings cannot be applied.",
  "mcp.banner.alignment_unknown.title":
    "The active connection state cannot be verified",
  "mcp.banner.alignment_unknown.body":
    "Editing is paused because MetaWork cannot confirm which saved connection settings are active.",
  "mcp.banner.recovery.title": "Connector settings need recovery",
  "mcp.banner.recovery.body":
    "The last known configuration is shown, but changes are paused until recovery completes.",
  "mcp.banner.outcome_unknown.title": "The last save result is unknown",
  "mcp.banner.outcome_unknown.body":
    "MetaWork has hidden the unconfirmed configuration and paused connector access for new tasks until recovery is complete.",
  "mcp.banner.runtime_unavailable.title":
    "Connector tools are currently unavailable",
  "mcp.banner.runtime_unavailable.body":
    "You can still review saved settings. Ordinary tasks can continue without connector tools.",
  "mcp.unavailable_title": "Connectors are unavailable",
  "mcp.unavailable_body":
    "MetaWork could not load your connectors. Reopen the app to try again.",
  "mcp.empty_title": "No connectors yet",
  "mcp.empty_agent_hint":
    "Have a setup guide? Share its link with the agent in a task to connect the server.",
  "mcp.no_results_title": "No matching connectors or tools",
  "mcp.no_results_body": "Nothing matches “{query}”.",
  "mcp.detail.tool_permissions": "Tool permissions",
  "mcp.detail.connection_test": "Connection test",
  "mcp.detail.connection_and_auth": "Connection and authentication",
  "mcp.detail.advanced": "Advanced settings",
  "mcp.detail.display_name": "Display name",
  "mcp.detail.diagnostic": "Needs attention",
  "mcp.detail.tool_help":
    "Newly discovered tools are off by default for new tasks.",
  "mcp.detail.allowed_count": "Allowed {allowed}/{total}",
  "mcp.detail.no_tools": "This server has not published any usable tools.",
  "mcp.redacted": "MetaWork removed sensitive text from this catalog.",
  "mcp.desired.enabled": "Enabled",
  "mcp.desired.disabled": "Disabled",
  "mcp.existing_tasks_note":
    "Existing tasks cannot gain newly added tools. Revoked permissions restrict future access.",
  "mcp.add.action": "Add manually",
  "mcp.add.title": "Add a connector",
  "mcp.edit.title": "Edit connection settings",
  "mcp.edit.reauthenticate":
    "Changing the address or program requires setting up credentials or signing in again.",
  "mcp.edit.action": "Edit connection",
  "mcp.edit.submit": "Save connection",
  "mcp.add.name": "Display name",
  "mcp.add.continue": "Continue",
  "mcp.add.back": "Back",
  "mcp.add.confirm_title": "Confirm connector",
  "mcp.add.detected.connected":
    "MCP handshake succeeded. This address needs no additional sign-in.",
  "mcp.add.detected.authentication_required":
    "The server requires authentication. Check its setup instructions for the required request headers.",
  "mcp.add.detected.access_denied":
    "The server denied access. Check its authorization instructions.",
  "mcp.add.detected.oauth_automatic":
    "The server requires OAuth sign-in and supports automatic client registration.",
  "mcp.add.detected.oauth_existing":
    "The server requires OAuth sign-in and did not provide a registration endpoint.",
  "mcp.add.detected_label": "Detected",
  "mcp.add.auth_mode.oauth": "OAuth",
  "mcp.add.auth_mode.none": "Without OAuth",
  "mcp.add.oauth_client": "OAuth client registration",
  "mcp.add.oauth_client.automatic": "Register automatically",
  "mcp.add.oauth_client.existing": "Use your own OAuth client",
  "mcp.add.oauth_after_save":
    "After adding the server, sign in from its details to connect.",
  "mcp.add.oauth_unavailable": "OAuth is currently unavailable.",
  "mcp.add.request_headers": "Request headers",
  "mcp.add.request_header_name": "Name",
  "mcp.add.request_header_value": "Value",
  "mcp.add.request_header_add": "Add header",
  "mcp.add.final.failed":
    "The final configuration could not complete the MCP handshake. Check the address and headers and try again.",
  "mcp.add.final.busy": "Another server is being added. Try again shortly.",
  "mcp.add.final.unavailable":
    "The final configuration could not be verified right now. Try again shortly.",
  "mcp.add.probing": "Checking connection…",
  "mcp.add.probe.failed":
    "Couldn't complete the MCP handshake. Check the full server address and try again.",
  "mcp.add.probe.busy":
    "Another connection check is in progress. Try again shortly.",
  "mcp.add.probe.rejected":
    "Couldn't check this configuration. Review the name and address and try again.",
  "mcp.add.probe.unavailable":
    "Connection checks are unavailable right now. Try again shortly.",
  "mcp.add.timeout": "Timeout (ms)",
  "mcp.add.timeoutHelp":
    "Per-request timeout. Connection and catalog management are limited to {limit} ms; tool calls keep the configured timeout.",
  "mcp.add.structured_command": "Program and arguments",
  "mcp.add.executable": "Executable",
  "mcp.add.argument": "Argument",
  "mcp.add.add_argument": "Add argument",
  "mcp.add.remove_argument": "Remove argument {index}",
  "mcp.add.edit_command_line": "Edit as launch command",
  "mcp.add.command": "Launch command",
  "mcp.add.command_help":
    "Paste the command you would normally run. Shell operators and substitutions are not executed.",
  "mcp.add.cwd": "Working directory (optional)",
  "mcp.add.environment": "Environment variable names",
  "mcp.add.environment_name": "Add environment name",
  "mcp.add.authentication": "Authentication",
  "mcp.add.headers": "Header names",
  "mcp.edit.secret_help":
    "Set or replace secret values in the connection details after saving.",
  "mcp.add.header_name": "Add header name",
  "mcp.add.client_id": "Client ID",
  "mcp.add.client_auth_method": "Token endpoint client authentication",
  "mcp.client_auth.none": "Public client (no client secret)",
  "mcp.client_auth.client_secret_basic": "Client secret (HTTP Basic)",
  "mcp.client_auth.client_secret_post": "Client secret (request body)",
  "mcp.add.remove_row": "Remove row",
  "mcp.add.sensitive_endpoint_replace":
    "Enter the full address to replace the saved address.",
  "mcp.install.phase.preparing": "Preparing configuration…",
  "mcp.install.phase.needs_authorization":
    "Confirm this installation in the system confirmation window.",
  "mcp.install.phase.acquiring_credentials": "Obtaining credentials securely…",
  "mcp.install.phase.needs_credentials": "Enter the required credential below.",
  "mcp.install.phase.needs_oauth":
    "Complete sign-in in the authorization window.",
  "mcp.install.phase.connecting": "Connecting and discovering tools…",
  "mcp.install.phase.ready":
    "Installation completed. The tools discovered during installation were authorized.",
  "mcp.install.phase.no_tools":
    "Connected. There are currently no tools available to new tasks.",
  "mcp.install.phase.failed": "Configuration failed.",
  "mcp.install.phase.cancelled": "Installation cancelled.",
  "mcp.install.phase.cancelling":
    "Stopping installation. Further stages are blocked.",
  "mcp.install.failure.invalid_request":
    "The installation instructions could not be applied.",
  "mcp.install.failure.credential_request_failed":
    "Credential retrieval failed. Check the installation source before retrying.",
  "mcp.install.failure.credential_request_interrupted":
    "Credential retrieval was interrupted. Retry this installation explicitly.",
  "mcp.install.failure.configuration_changed":
    "The configuration changed during installation.",
  "mcp.install.failure.authorization_failed":
    "Authorization did not complete. Retry explicitly when you are ready.",
  "mcp.install.failure.connection_failed":
    "Could not connect to the service. Open Connectors to check its connection details.",
  "mcp.install.failure.storage_failed":
    "Configuration could not be saved securely.",
  "mcp.install.failure.timeout": "Installation exceeded its time budget.",
  "mcp.install.credential": "Credential: {slot}",
  "mcp.install.title": "Connector setup",
  "mcp.install.submit": "Save credential",
  "mcp.install.cancel": "Cancel installation",
  "mcp.install.action_failed":
    "The action could not be confirmed. Check the current status and retry.",
  "mcp.install.rejected":
    "Could not create the connector. Open Connectors to check its status.",
  "mcp.add.endpoint": "MCP server address",
  "mcp.add.endpoint_help":
    "Use an HTTP or HTTPS address. User info and fragments are not accepted.",
  "mcp.add.submit": "Add connector",
  "mcp.add.adding": "Adding…",
  "mcp.rename.action": "Save name",
  "mcp.enable.action": "Enable",
  "mcp.disable.action": "Disable",
  "mcp.delete.action": "Delete connector",
  "mcp.refresh.action": "Refresh tools",
  "mcp.refresh.refreshing": "Refreshing…",
  "mcp.refresh.started": "Refreshing tools from available connectors.",
  "mcp.refresh.busy": "A tool refresh is already running.",
  "mcp.refresh.unavailable": "Connector tools are currently unavailable.",
  "mcp.refresh.shutting_down": "MetaWork is shutting down.",
  "mcp.refresh.rejected": "The catalog refresh was rejected.",
  "mcp.refresh.failed":
    "The tools could not be refreshed. The last confirmed state is unchanged.",
  "mcp.test.action": "Test connection",
  "mcp.test.busy": "Another connection test is already running.",
  "mcp.test.stale_generation":
    "The configuration changed. Retry with the latest settings.",
  "mcp.test.needs_authentication":
    "Finish secret setup or OAuth authorization first.",
  "mcp.test.rejected": "The current configuration cannot be tested.",
  "mcp.test.unavailable": "Connection testing is temporarily unavailable.",
  "mcp.test.summary.testing": "Testing…",
  "mcp.test.summary.connected": "Succeeded · {tools} found",
  "mcp.test.summary.failed": "Failed · {issues} issues",
  "mcp.next.authorization.title": "Complete sign-in",
  "mcp.next.authorization.body": "Sign in to connect and load available tools.",
  "mcp.next.credentials.body":
    "Add the required credential to connect and load available tools.",
  "mcp.next.configure_credentials": "Set credentials",
  "mcp.next.apply_failed.body":
    "The settings are saved. The server has not loaded.",
  "mcp.next.retry_connection.body":
    "Retry the saved connection to update tools and new-task access.",
  "mcp.next.retry_connection.action": "Retry connection",
  "mcp.next.invalid_catalog.body":
    "This tool catalog cannot be used. Remove the server and add it again.",
  "mcp.next.choose_tools.title": "Choose tools",
  "mcp.next.choose_tools.body":
    "{count} tools were discovered. Choose which ones new tasks may use.",
  "mcp.next.choose_tools.action": "Choose tools",
  "mcp.mutation.unchanged": "No configuration change was needed.",
  "mcp.mutation.saved": "Connector settings saved.",
  "mcp.mutation.saved_recovery_required":
    "Settings saved, but management is paused until recovery completes.",
  "mcp.mutation.stale_generation":
    "The configuration changed elsewhere. The latest saved state was reloaded.",
  "mcp.mutation.rejected": "MetaWork could not apply this change.",
  "mcp.mutation.indeterminate":
    "The save result is unknown. MetaWork has paused connector access for new tasks.",
  "mcp.mutation.failed":
    "The change could not be completed. The last confirmed state is unchanged.",
  "mcp.mutation.enabled":
    "Server enabled for new tasks. Open tasks keep their current access.",
  "mcp.mutation.disabled":
    "Server disabled for new tasks. Open tasks keep their current access.",
  "mcp.tool.not_discovered": "Not in current catalog",
  "mcp.tool.allowed_not_available": "Currently unavailable",
  "mcp.tool.toggle": "Allow {name} for new tasks",
  "mcp.detail.allow_all": "Allow all {count}",
  "mcp.confirm.allow_all.title": "Allow every discovered tool?",
  "mcp.confirm.allow_all.body":
    "All currently discovered tools will be allowed; tools discovered later stay excluded by default.",
  "mcp.confirm.allow_all.action": "Allow all",
  "mcp.auth.static_locked": " (credential submission unavailable)",
  "mcp.auth.oauth_secret_locked":
    "Credential submission is temporarily unavailable. An existing selection can be preserved.",
  "mcp.confirm.enable.title": "Enable this server?",
  "mcp.confirm.enable.body":
    "When the connection is ready, this restores the previous tool access ({count} selected) for new tasks. Open tasks keep their current access.",
  "mcp.confirm.enable.action": "Enable server",
  "mcp.enablement.label": "{server} enabled",
  "mcp.enablement.connection_unavailable":
    "Connection settings are unavailable. Open details to review recovery options.",
  "mcp.enablement.approval_required":
    "Open details and finish connecting this server first.",
  "mcp.tasks.count": "Task references: {count}",
  "mcp.retained.summary":
    "Services kept for existing tasks: {count}. They are unavailable to new tasks.",
  "mcp.retained.disabled_body":
    "Existing tasks keep the applied configuration. Changes apply when this service is enabled again.",
  "mcp.apply_status.pending": "Waiting to connect",
  "mcp.apply_status.rejected": "Change rejected",
  "mcp.apply_status.failed": "Change not applied",
  "mcp.apply_status.capacity": "Connection limit reached",
  "mcp.next.capacity.body": "Close unused tasks, then retry the connection.",
  "mcp.apply_status.unknown": "Unconfirmed",
  "mcp.apply_status.current": "Processed",
  "mcp.apply_status.applying": "Connecting",
  "mcp.banner.runtime_unknown.title":
    "Connection change could not be confirmed",
  "mcp.banner.runtime_unknown.body":
    "Connector changes, tool refresh, and authorization are paused. Restart MetaWork to check the connection state.",
  "mcp.confirm.delete.oauth_body":
    "Renewal stops after deletion. Existing tasks lose access when the current authorization expires.",
  "mcp.confirm.delete.title": "Delete this connector?",
  "mcp.confirm.delete.body":
    "This removes the configuration and prevents new tasks from using this service. Existing tasks keep their current connection, subject to tool permissions.",
  "mcp.confirm.delete.action": "Delete connector",
  "skills.subtitle": "Manage your personal Skills in MetaWork.",
  "skills.import": "Import Skill",
  "skills.import.action": "Import",
  "skills.import_first": "Import your first Skill",
  "skills.install": "Install",
  "skills.reimport": "Reimport",
  "skills.export": "Export",
  "skills.uninstall": "Uninstall",
  "skills.retry": "Retry",
  "skills.working": "Working…",
  "skills.no_description": "No description provided.",
  "skills.section.skills": "Skills",
  "skills.scope.personal": "Personal",
  "skills.status.pending": "Pending verification",
  "skills.status.recovery_required": "Recovery required",
  "skills.restart_recovery_body":
    "Local Skill management is paused after a storage failure. Restart MetaWork to reload the saved inventory and retry recovery. If recovery still fails, check folder access and file locks.",
  "skills.status.issue": "Needs attention",
  "skills.more_actions": "More actions",
  "skills.enablement.enable": "Enable",
  "skills.enablement.disable": "Disable",
  "skills.enablement.enabled": "Enabled",
  "skills.enablement.disabled": "Disabled",
  "skills.enablement.label": "Toggle {skill}",
  "skills.choose_package": "Choose .skill or .zip",
  "skills.choose_package_body":
    "Import a portable Skill package from this computer.",
  "skills.choose_folder": "Choose folder",
  "skills.choose_folder_body":
    "Choose a folder with SKILL.md at its root or in one wrapper folder.",
  "skills.choose_again": "Choose again",
  "skills.import_error.invalid_scope":
    "Choose an available personal or working directory scope.",
  "skills.import_error.invalid_preview":
    "This confirmation has expired or is no longer valid. Choose the source again.",
  "skills.import_error.source_unavailable":
    "The selected source cannot be read. Check that it exists and is accessible, then choose it again.",
  "skills.import_error.definition_missing":
    "No SKILL.md was found. Choose a Skill root or a folder containing one Skill.",
  "skills.import_error.multiple_definitions":
    "More than one SKILL.md was found. Place the Skill you want to import in its own folder.",
  "skills.import_error.invalid_layout":
    "Unsupported folder layout. SKILL.md must be at the selected root or in its only child folder.",
  "skills.import_error.invalid_definition":
    "The name or description in SKILL.md is invalid. Correct it and choose the source again.",
  "skills.import_error.invalid_path":
    "The package contains an unsafe or duplicate path. Correct it before importing.",
  "skills.import_error.unsupported_entry":
    "The package contains an unsupported file type or compression method. Use regular files and ZIP.",
  "skills.import_error.archive_corrupt":
    "The package is damaged or is not a valid ZIP. Export or obtain it again.",
  "skills.import_error.too_large":
    "The file count or size exceeds the import limit. Reduce the package and choose it again.",
  "skills.import_error.source_changed":
    "The source has changed. Choose it again and confirm the latest content.",
  "skills.import_error.target_changed":
    "The target has changed. Choose the source again and review the updated effect before confirming.",
  "skills.import_error.asset_unavailable":
    "This Skill can no longer be managed. Refresh the list and try again.",
  "skills.import_error.state_changed":
    "The Skill state has changed. Refresh and confirm again.",
  "skills.import_error.target_exists":
    "The target already exists. Prepare again to review its replacement.",
  "skills.import_error.busy":
    "A related task or Skill operation is still active. Confirm again when it finishes.",
  "skills.import_error.catalog_loading":
    "Skills are still being checked or verified. Wait, then confirm again.",
  "skills.import_error.workspace_changed":
    "Working directory authorization has changed. Choose the directory and confirm again.",
  "skills.import_error.workspace_unavailable":
    "The working directory is unavailable. Restore folder authorization and try again.",
  "skills.import_error.capacity_reached":
    "There is not enough processing capacity right now. Try again later.",
  "skills.import_error.shutting_down":
    "The app is shutting down. This operation was not accepted.",
  "skills.import_error.local_storage_failed":
    "The local file operation failed. Check folder access or files in use, and review recovery status in the list.",
  "skills.import_error.outcome_unknown":
    "The outcome has not been confirmed. Check the latest list and recovery guidance before importing again.",
  "skills.effect.create": "Install Skill",
  "skills.effect.update": "Update Skill",
  "skills.effect.replace_directory": "Replace folder",
  "skills.effect_body.create": "Install “{skill}” in your personal directory.",
  "skills.effect_body.shadows_builtin":
    "A built-in Skill has the same name. After installation, the personal version will take precedence.",
  "skills.effect_body.update":
    "A Skill named “{skill}” already exists. Confirm to update its contents and keep its enablement settings.",
  "skills.effect_body.replace_directory":
    "A folder named “{skill}” already exists in your personal directory. Confirm to replace it. Its original copy is retained until verification finishes.",
  "skills.operation.prepared": "{skill} is prepared for confirmation.",
  "skills.operation.pending_verification":
    "{skill} has been published and is awaiting verification.",
  "skills.operation.ready": "{skill} has been verified and is ready.",
  "skills.operation.rolled_back":
    "{skill} failed verification. The file changes have been rolled back.",
  "skills.operation.recovery_required":
    "{skill} needs recovery. Review the available actions on the asset.",
  "skills.operation.rejected":
    "The operation for {skill} did not complete. Review the reason.",
  "skills.operation.cancelled":
    "The unsubmitted preparation for {skill} was discarded.",
  "skills.operation.outcome_unknown":
    "The outcome for {skill} is not confirmed. Review recovery guidance.",
  "skills.preview_size": "{files} files · {size} bytes",
  "skills.resource_context_notice":
    "MetaWork adds resource-location instructions to the installed Skill and its exports. Other tools reading the same Skill folder will also see them. Your source files stay unchanged.",
  "skills.replace_title": "A Skill with this name already exists",
  "skills.replace_body":
    "Replace it only if you trust this package and want the existing Skill to be restored if verification fails.",
  "skills.replace": "Replace Skill",
  "skills.detail.definition": "SKILL.md",
  "skills.detail.loading": "Loading the local definition…",
  "skills.detail.unavailable": "The Skill file is temporarily unavailable.",
  "skills.uninstall_confirm_title": "Uninstall “{skill}”?",
  "skills.uninstall_confirm":
    "Its managed files will be removed from your personal Skill directory. This cannot be undone from MetaWork.",
  "skills.exported": "Exported {file}",
  "skills.error.preview": "This source could not be validated as a Skill.",
  "skills.error.mutation": "The Skill change could not be completed.",
  "skills.error.export_too_large":
    "The exported package would exceed the reimport limit. Reduce its resources and export again.",
  "skills.error.export": "The Skill could not be exported.",
  "skills.error.enablement":
    "Could not change whether “{skill}” is enabled. Refresh and try again.",
  "skills.refresh": "Refresh",
  "skills.refreshing": "Refreshing…",
  "skills.search_label": "Search skills",
  "skills.clear_search": "Clear search",
  "skills.unavailable_title": "Skill management is unavailable",
  "skills.unavailable_body":
    "MetaWork could not open its local Skill inventory. Refresh to try again.",
  "skills.empty_title": "No local Skills yet",
  "skills.empty_body":
    "Import a .skill or .zip package, or choose a folder containing SKILL.md.",
  "skills.no_results_title": "No matching Skills",
  "skills.no_results_body": "Nothing matches “{query}”.",
  "skills.catalog_refresh_started": "Refreshing the Skill catalog…",
  "skills.catalog_refresh_failed": "The Skill catalog could not be refreshed.",
  "skills.catalog_issues": "Catalog issues",
  "skills.catalog_issues_help":
    "Adjust Skill files and refresh. Individual Skill enablement does not resolve source conflicts.",
  "skills.catalog_unavailable":
    "The catalog is not ready or its query failed. Refresh to retry.",
  "skills.personal_directory_error":
    "Could not check the personal Skill directory: {reason}.",
  "skills.directory_error.unreadable": "unreadable",
  "skills.directory_error.unsupported_entry": "unsupported directory entry",
  "skills.directory_error.changed": "directory changed",
  "skills.no_available_title": "No Skills are currently available",
  "skills.section.attention": "Needs attention",
  "skills.issue.source_conflict":
    "Same-priority source conflict; no candidate is available",
  "skills.issue.invalid_definition": "Invalid Skill definition",
  "skills.issue.invalid_resource": "Invalid Skill resource",
  "skills.issue.invalid_invocation_name": "Invalid Skill invocation name",
  "task.empty_title": "What would you like to accomplish?",
  "task.created_empty_body":
    "This task is ready. Enter its first instruction to begin.",
  "task.conversation_history_excluded":
    "Some history is not included in the restored conversation context. You can still continue with a new message.",
  "task.no_tasks":
    "Start a new task; choose a folder before sending when one is needed.",
  "task.archived_hidden": "Archived tasks are hidden.",
  "task.history_retained":
    "Tasks this version can't open: {count}. They are kept unchanged.",
  "task.archived": "Archived",
  "task.ready": "Ready",
  "task.last_result": "Last result: {result}",
  "task.lifecycle.open": "Open",
  "task.lifecycle.closing": "Ending",
  "task.phase.queued": "Queued",
  "task.phase.running": "Working",
  "task.phase.waiting_ui": "Needs attention",
  "task.phase.reviewing": "Automatic review",
  "task.phase.stopping": "Stopping",
  "task.phase.completed": "Completed",
  "task.phase.stopped": "Stopped",
  "task.phase.cancelled": "Stopped",
  "task.phase.interrupted": "Interrupted",
  "task.phase.failed": "Failed",
  "run.activity.queued": "Queued",
  "run.elapsed": "Turn elapsed {duration}",
  "run.activity.starting": "Getting started",
  "run.activity.executing_tools": "Processing tool calls",
  "run.activity.retrying_provider": "Retrying the model request",
  "run.activity.compacting_context": "Organizing context",
  "run.activity.finishing": "Finishing",
  "run.activity.waiting_model": "Working",
  "run.activity.thinking": "Thinking",
  "run.activity.writing_response": "Generating content",
  "run.activity.inspecting_workspace": "Inspecting the workspace",
  "run.activity.updating_content": "Updating content",
  "run.activity.running_operation": "Running an operation",
  "run.activity.tool_running_one": "Processing 1 tool call",
  "run.activity.tool_running_many": "Processing {count} tool calls",
  "run.activity.retry_detail":
    "Attempt {attempt} of {max} · retrying in {delay} ms",
  "run.activity.retry_detail_now": "Attempt {attempt} of {max} · retrying now",
  "task.signal.running": "Working",
  "task.signal.attention": "Attention",
  "task.signal.failed": "Failed",
  "task.signal.interrupted": "Interrupted",
  "task.signal.completed": "New completion",
  "task.signal.archived": "Archived",
  "task.actions": "Task actions",
  "task.actions_for": "Actions for “{title}”",
  "task.rename": "Rename",
  "task.rename_title": "Rename task",
  "task.rename_name": "Task name",
  "task.rename_unconfirmed":
    "The rename result is unconfirmed. Check the current task name before saving again.",
  "task.archive": "Archive",
  "task.archive_for": "Archive “{title}”",
  "task.restore": "Restore",
  "task.delete": "Permanently delete",
  "task.delete_retry": "Retry deletion",
  "task.delete_confirm_title": "Delete task “{title}”?",
  "task.delete_confirm_body":
    "This permanently deletes the task and its conversation and execution history. Files in the working folder will be kept. Any running operation will be stopped first.",
  "task.stop": "Stop task",
  "task.stop_confirm": "Press Esc again to stop",
  "compact.stop": "Stop compacting",
  "compact.started": "Context compaction started.",
  "compact.start_failed": "Context compaction could not be started.",
  "compact.stop_requested": "Stopping context compaction…",
  "compact.stop_failed":
    "The stop request could not be confirmed. Refresh and try again.",
  "compact.timeline.queued": "Context compaction queued",
  "compact.timeline.compacting": "Compacting context…",
  "compact.timeline.stopping": "Stopping context compaction…",
  "compact.timeline.compacted":
    "Context compacted · about {before} → {after} tokens",
  "compact.timeline.no_change": "Context was already compact",
  "compact.timeline.degraded":
    "Context compacted with reduced fidelity · about {before} → {after} tokens",
  "compact.timeline.aborted": "Context compaction stopped",
  "compact.timeline.interrupted": "Context compaction was interrupted",
  "compact.timeline.failed": "Context compaction failed",
  "compact.phase.queued": "Compaction queued",
  "compact.phase.compacting": "Compacting context",
  "compact.phase.stopping": "Stopping compaction",
  "recovery.start_failed":
    "This conversation cannot continue yet. Your message is saved; send it again to retry.",
  "task.create_failed":
    "The task could not be created. Check your connection and try again.",
  "task.created": "Task created.",
  "task.rename_failed": "The task could not be renamed. Try again.",
  "task.archive_failed": "The task could not be archived. Try again.",
  "task.restore_failed": "The task could not be restored. Try again.",
  "task.delete_failed": "The task record could not be deleted. Try again.",
  "task.renamed": "Task renamed.",
  "task.archived_status": "Task archived.",
  "task.restored": "Task restored.",
  "task.delete_requested": "Task deletion started.",
  "run.tokens": "{count} tokens",
  "run.preparing": "Preparing the work…",
  "run.submit": "Send",
  "run.input_history_loading": "Loading input history…",
  "run.input_history_failed": "Couldn't load input history. Press ↑ to retry.",
  "run.placeholder": "Enter your instructions…",
  "run.context": "Current execution context",
  "run.placeholder_no_task": "Start a task first",
  "run.placeholder_archived": "Restore this task to continue",
  "run.placeholder_closing": "This task is ending",
  "run.placeholder_unavailable": "This task cannot continue right now",
  "run.placeholder_execution_rebind_required":
    "The current execution cannot run this conversation. Switch to an account or connection that supports the task model",
  "run.placeholder_history_read_only":
    "This task has content this version can't read. You can view it; use a newer MetaWork to continue",
  "input.stopping": "This run is stopping. Your draft is preserved.",
  "input.skill_run":
    "Skill runs do not support additional messages. Your draft is preserved.",
  "input.text_only":
    "Only text can be added during a run. Your draft is preserved.",
  "input.not_ready":
    "This run is not accepting input. Your draft is preserved.",
  "input.submitting": "Submitting…",
  "input.waiting": "Waiting",
  "input.cancelled": "Stopped",
  "input.unexecuted": "Not executed",
  "input.edit": "Edit",
  "input.edit_notice":
    "Sending rewinds the conversation to this message and generates a new reply. Files already created and changes already made are kept.",
  "input.edit_cancel": "Cancel",
  "input.retry_original": "Resend original message",
  "input.discard_retry": "Discard saved input",
  "input.submitted": "Message sent.",
  "input.unknown":
    "Submission is unconfirmed. Check the run history; the message will not be resent automatically.",
  "input.local_capacity":
    "Local submission storage is full. Your draft is kept; sync and check earlier submissions before sending more.",
  "input.continuation_wait":
    "Processing submitted messages; edit your draft or stop",
  "mutation.reason.continuation_cancelled": "Further processing was cancelled.",
  "mutation.reason.approval_mode_change":
    "The approval mode change stopped this run. The message was kept so you can resend it.",
  "mutation.reason.combined_input_too_large":
    "The combined messages exceed the input limit. Send them separately.",
  "mutation.reason.edit_and_rerun":
    "Editing an earlier message took this one out of the conversation. It was kept so you can resend it.",
  "mutation.reason.rewind_compacted":
    "That part of the conversation was summarized away and can no longer be replaced. The message was kept so you can send it as a new one.",
  "mutation.reason.rewind_position_rejected":
    "MetaWork could not place that message in the conversation, so nothing was changed. Please report this.",
  "mutation.reason.rewind_failed":
    "The conversation could not be rewound. Nothing was changed.",
  "mutation.reason.checkpoint_failed":
    "Run cleanup failed; messages were not continued.",
  "mutation.reason.schedule_failed":
    "The scheduled result could not be confirmed; messages were not continued.",
  "mutation.reason.run_changed":
    "The target run has changed. Check it before sending again.",
  "mutation.reason.run_not_ready":
    "This run is not accepting input. The message was not sent.",
  "mutation.reason.run_stopping":
    "This run is stopping. The message was not sent.",
  "mutation.reason.too_late": "This run has ended. The message was not sent.",
  "mutation.reason.invalid_input":
    "Check the message content before sending again.",
  "mutation.reason.resource_limit":
    "This run’s additional input limit was reached. The message was not sent.",
  "mutation.reason.checkpoint_budget_required":
    "This run has insufficient context capacity. The message was not sent.",
  "mutation.reason.unsupported_input":
    "This additional input is unsupported. Your draft is preserved.",
  "mutation.reason.admission_failed":
    "The message could not be admitted. Your draft is preserved.",
  "run.started": "Work started.",
  "run.start_failed":
    "Work could not start. Check your connection and try again.",
  "run.stop_failed": "The stop request could not be confirmed",
  "run.stop_unconfirmed": "Stop result not yet confirmed",
  "run.stop_requested":
    "Stop requested. Waiting for the current work to finish stopping…",
  "run.activity.unsynchronized": "Status not synchronized",
  "run.activity.requesting_stop": "Requesting stop…",
  "attachment.add": "Add files",
  "composer.add": "Add to message",
  "attachment.error.reference_unavailable":
    "The referenced workspace file is unavailable. Check the original file or remove its attachment card.",
  "composer.upload_number": "Attachment {index}",
  "composer.reference_files": "Reference conversation files",
  "composer.uploaded_file": "Uploaded by you",
  "composer.no_files": "No files to reference",
  "composer.old_file": "Add the original file again to use it",
  "composer.older_files": "Load earlier files",
  "composer.loading_files": "Loading earlier files…",
  "composer.add_skill": "Add Skill",
  "composer.add_skill_selected":
    "Each message uses one Skill. Remove the selected Skill to choose another.",
  "attachment.removing": "Removing file…",
  "attachment.error.release_unconfirmed":
    "File cleanup could not be confirmed. Restoring the connection; unsent files need to be selected again.",
  "attachment.cancelling": "Cancelling file addition…",
  "attachment.error.input_busy":
    "Files are still being processed. Try adding again shortly.",
  "attachment.error.input_unavailable": "Files cannot be added here right now.",
  "attachment.error.cleanup_failed":
    "Attachment cleanup is incomplete and some resources are still in use. Try again later.",
  "attachment.cancel": "Cancel adding files",
  "attachment.error.invalid_transfer":
    "File transfer did not complete. Add the files again.",
  "attachment.error.stale_transfer":
    "This file transfer is no longer active. Add the files again.",
  "attachment.drop": "Drop files to add",
  "attachment.selected": "Selected attachments",
  "attachment.remove": "Remove {name}",
  "attachment.open": "Preview {name}",
  "attachment.close_preview": "Close image preview",
  "attachment.type.image": "Image",
  "attachment.type.file": "File",
  "attachment.reload_required":
    "Unsent attachments are not kept after reload. Add them again before sending.",
  "attachment.model_warning.image":
    "This model declares that image input is unsupported. You can still send and receive the exact result.",
  "attachment.error.unsupported_type":
    "A selected file is empty, invalid, or an image that cannot be decoded.",
  "attachment.error.file_too_large":
    "A selected file exceeds the per-file limit ({limit} MB).",
  "attachment.error.too_many_files":
    "You can attach up to 8 files per message.",
  "attachment.error.staging_capacity":
    "Attachment resources are temporarily unavailable. No files were added. Try again later.",
  "attachment.error.read_failed":
    "One of the selected files could not be read.",
  "attachment.error.file_changed":
    "One of the selected files changed while it was being added. Try again.",
  "attachment.error.shutting_down":
    "Attachments are unavailable while MetaWork is closing.",
  "attachment.error.generic": "The selected files could not be added.",
  "run.terminal.completed": "Work completed",
  "run.no_final_response": "This turn returned no final response",
  "run.actions": "Run actions",
  "run.recording_incomplete":
    "Some process details or response content were not fully retained.",
  "run.terminal.with_reason": "{outcome}. {reason}",
  "run.terminal.partial_reason": "{reason} Response incomplete.",
  "account.diagnostics": "Account diagnostics",
  "feedback.pending": "Working…",
  "feedback.unconfirmed": "{operation}: result not yet confirmed",
  "task.archive_unconfirmed": "Archive or restore result not yet confirmed",
  "task.delete_unconfirmed": "Deletion result not yet confirmed",
  "task.operation_diagnostics": "Operation diagnostics",
  "workspace.diagnostics": "Workspace diagnostics",
  "run.terminal.stopped": "Work stopped",
  "run.terminal.interrupted": "Work interrupted",
  "run.terminal.failed": "Work failed",
  "run.terminal.partial_completed": "The response ended before completion",
  "run.terminal.partial_stopped":
    "Work stopped before the response was complete",
  "run.terminal.partial_interrupted":
    "Work was interrupted before the response was complete",
  "run.terminal.partial_failed": "Work failed before the response was complete",
  "run.conversation_history_excluded":
    "This message remains in the task history, but is not included in the restored model context. You can still continue with a new message.",
  "run.process.title": "Execution details",
  "run.process.elapsed": "Turn time {duration}",
  "run.process.toggle_tool": "Show or hide details for {name}",
  "run.process.tool_detail": "Details for {name}",
  "run.process.tools_loading": "Loading tool calls…",
  "run.process.tools_failed": "Tool calls could not be loaded.",
  "run.process.tools_retry": "Retry",
  "run.process.tools_more": "Show more calls ({count} remaining)",
  "run.prepare_retry": "Copy to input box",
  "run.retry_help":
    "Copies this instruction to the Composer for review. Nothing is sent automatically.",
  "run.review_draft": "Review current draft",
  "run.review_draft_help":
    "Keeps your current draft unchanged and moves focus to the Composer.",
  "run.retry_prepared":
    "Instruction copied to the Composer. Review it before sending.",
  "run.draft_preserved": "Your current Composer draft was kept unchanged.",
  "run.text_input_too_large":
    "Text exceeds the 256 KiB send limit. Your full draft is retained; shorten it or move the log to a text file (up to 100 MB).",
  "run.retry_too_long":
    "This instruction is too long for the Composer. Write a shorter follow-up instead.",
  "run.provider_failure.title": "Model service request failed",
  "run.provider_failure.no_response_impact":
    "No response was generated. You can try again later.",
  "run.provider_failure.partial_impact":
    "The response stopped before it was complete.",
  "run.provider_failure.diagnostic_absent":
    "No additional technical details are available.",
  "run.provider_failure.diagnostic_withheld":
    "Additional technical details are stored on this device and cannot be shown here.",
  "run.provider_failure.review_tool_effects":
    "Review the earlier execution records before sending again.",
  "run.view_diagnostics": "View run details",
  "slash.title": "Composer actions",
  "slash.group.commands": "Commands",
  "slash.group.skills": "Skills",
  "slash.no_description": "No description provided",
  "slash.no_matches": "No matching command or Skill",
  "slash.no_skills": "No matching Skills in this catalog",
  "slash.skills_loading": "Skills are still loading. Text remains available.",
  "slash.skills_unavailable": "Skills are unavailable in this context.",
  "slash.refresh": "Refresh Skills",
  "slash.remove_skill": "Remove selected Skill",
  "slash.skill_message_unsupported":
    "This Skill cannot use this message. Remove the Skill or edit the message to continue.",
  "slash.skill_message_too_large":
    "This message is too long for the selected Skill. Shorten it to continue.",
  "slash.skill_changed":
    "This Skill has changed. Review your message before sending.",
  "slash.skill_disabled":
    "This Skill is disabled. Remove it or choose another Skill.",
  "slash.review_skill": "Review Skill",
  "slash.skill_stale":
    "This Skill is no longer available. Remove it or choose another Skill.",
  "slash.disabled_unavailable": "This action is temporarily unavailable.",
  "slash.disabled_already_new_task": "A new task draft is already open.",
  "slash.disabled_task_busy": "Wait for the current task operation to finish.",
  "slash.disabled_no_history": "Run the task once before compacting context.",
  "slash.command.new": "New task",
  "slash.command.new_help": "Open a fresh task draft.",
  "slash.command.compact": "Compact context",
  "slash.command.compact_help":
    "Compact this task's conversation without starting a new Run.",
  "slash.catalog_refresh_failed": "The Skill catalog could not be refreshed.",
  "tool.input": "Input",
  "tool.progress": "Progress",
  "tool.error": "Error",
  "tool.result": "Result",
  "tool.duration_ms": "{count} ms",
  "tool.output_shortened": "Long details were shortened",
  "privacy.sensitive_hidden": "Sensitive values were hidden",
  "file_preview.title": "File preview",
  "file_preview.state.capacity":
    "Image preview limit reached. Close other images and retry.",
  "file_preview.state.image_limit":
    "Image exceeds the preview file size or dimension limit.",
  "file_preview.state.animated_image": "Only static images can be previewed.",
  "file_preview.loading": "Loading preview…",
  "file_preview.close": "Close file preview",
  "file_preview.open": "Preview {path}",
  "file_preview.link_unavailable.outside_workspace":
    "Can't open: outside the current workspace",
  "file_preview.link_unavailable.workspace_unavailable":
    "Can't open: workspace unavailable",
  "file_preview.link_unavailable.unsupported_path":
    "Can't open: unsupported file path",
  "file_preview.refresh": "Refresh",
  "file_preview.enlarge_image": "Enlarge {name}",
  "file_preview.mode": "File display mode",
  "file_preview.rendered": "Preview",
  "file_preview.source": "Source",
  "file_preview.retry": "Retry",
  "file_preview.state.truncated": "Preview truncated",
  "file_preview.state.redacted": "Known sensitive content was hidden",
  "file_preview.state.missing": "File is no longer available",
  "file_preview.state.restricted": "File preview is restricted",
  "file_preview.state.unsupported": "This file cannot be previewed",
  "file_preview.state.changing":
    "The file changed while it was being read. Try again.",
  "file_preview.state.error": "File preview failed",
  "outputs.save": "Save as…",
  "outputs.saving": "Preparing and saving file…",
  "outputs.cancelling": "Cancelling…",
  "outputs.state.save_unknown":
    "Save result is unconfirmed. Check the selected location.",
  "outputs.state.saved": "File saved",
  "outputs.state.save_failed": "Could not save the file",
  "outputs.state.target_changed":
    "The selected destination changed. Choose it again.",
  "outputs.state.cleanup_failed": "Temporary file cleanup was incomplete",
  "outputs.edit": "Reference in conversation",
  "outputs.copy_path": "Copy path",
  "outputs.copy_image": "Copy image",
  "outputs.register": "Add to outputs",
  "outputs.state.registered": "Added to outputs",
  "outputs.state.edit_prepared": "File reference added to the input.",
  "outputs.state.edit_unavailable":
    "Cannot reference this file now. Check it again.",
  "outputs.check": "Check file",
  "video_preview.label": "Generated video",
  "video_preview.failed": "Could not play the video",
  "outputs.reveal": "Open folder",
  "outputs.cancel": "Cancel",
  "outputs.checking": "Checking file…",
  "outputs.state.ready": "Matched delivered content when checked",
  "outputs.state.revealed": "Requested location in file manager",
  "outputs.state.busy": "File operations are busy. Try again shortly.",
  "outputs.state.missing": "The source file no longer exists",
  "outputs.state.restricted": "This file is not currently accessible",
  "outputs.state.changed": "Changed since delivery",
  "outputs.state.file_changed":
    "The file changed during the operation. Try again.",
  "outputs.state.too_large": "The file exceeds the processing limit",
  "outputs.state.cancelled": "Operation cancelled",
  "outputs.state.timed_out": "File check timed out",
  "outputs.state.stale_security": "Authorization changed. Check again.",
  "outputs.state.unavailable": "File operations are unavailable",
  "outputs.state.failed": "File operation failed. Try again.",
  "outputs.title": "Delivered files",
  "outputs.view": "View outputs",
  "outputs.more": "More file actions",
  "outputs.open_browser": "Open in browser",
  "outputs.view_source": "View source",
  "outputs.open": "Open in default app",
  "outputs.state.open_unsupported":
    "This type of file cannot be opened in the default app. Use “Open folder”.",
  "outputs.state.open_failed":
    "The system did not open this file. It may have no associated app.",
  "outputs.state.path_copied": "Path copied",
  "outputs.state.copy_failed": "Could not copy. Try again.",
  "outputs.state.opened": "Sent to the default application",
  "outputs.updated": "File changed during this turn",
  "outputs.hidden_path": "File path hidden",
  "file_menu.label": "File actions",
  "file_card.separator": ", ",
  "file_card.state.missing": "File is no longer available",
  "file_card.state.restricted": "This file is not currently accessible",
  "file_card.state.changing": "The file is changing",
  "file_card.state.error": "This file cannot be read right now",
  "outputs.delivered_size": "Delivered · {bytes} bytes",
  "file_changes.title": "File changes",
  "file_changes.file_count.one": "{fileCount} file",
  "file_changes.file_count.other": "{fileCount} files",
  "file_changes.incomplete_label": "Record may be incomplete",
  "file_changes.incomplete_empty":
    "File changes for this run could not be fully verified",
  "file_changes.review": "Review changes",
  "file_changes.review_file": "Review changes to {path}",
  "file_changes.incomplete_notice":
    "Some file change records may be missing. The changes shown below are still available for review.",
  "file_changes.load_diff": "Load recorded diff",
  "file_changes.kind.created": "Added",
  "file_changes.kind.modified": "Modified",
  "file_changes.kind.deleted": "Deleted",
  "file_changes.kind.moved": "Moved",
  "file_changes.status.partial_warning":
    "The change may not have been fully applied",
  "file_changes.loading": "Loading recorded diff…",
  "file_changes.retry": "Retry",
  "file_changes.diff.incomplete": "Recorded diff is incomplete",
  "file_changes.diff.redacted": "Known sensitive content was hidden",
  "file_changes.diff.not_recorded": "No recorded diff is available",
  "file_changes.diff.capacity": "The diff reader is temporarily unavailable",
  "file_changes.diff.missing": "The recorded diff is no longer available",
  "file_changes.diff.corrupt":
    "The recorded diff did not pass integrity checks",
  "file_changes.diff.error": "The recorded diff could not be loaded",
  "file_changes.diff.group_unavailable":
    "Part of the recorded diff is unavailable",
  "file_changes.diff.content": "Recorded unified diff",
  "file_changes.diff.old_line": "Old line {line}",
  "file_changes.diff.new_line": "New line {line}",
  "file_changes.diff.stats":
    "{additions} added lines, {deletions} deleted lines",
  "file_changes.diff.unchanged_lines": "{count} unmodified lines",
  "task.jump_latest": "Jump to latest",
  "task.rail.label": "Conversation navigation",
  "task.rail.turn": "Turn {turn}",
  "task.rail.separator": ", ",
  "inspector.mcp_authority": "Connectors at creation",
  "inspector.mcp_selected": "Tools selected",
  "inspector.mcp_none": "Ready · no tools selected",
  "inspector.mcp_unavailable": "Unavailable",
  "inspector.needs_attention": "Needs your attention",
  "inspector.diagnostic_code": "Error identifier",
  "inspector.diagnostic_run": "Run ID",
  "inspector.diagnostic_model": "Model for this run",
  "inspector.diagnostic_protocol": "Execution protocol",
  "inspector.work_process": "Work process",
  "inspector.tool.running": "In progress",
  "inspector.tool.completed": "Completed",
  "inspector.tool.failed": "Failed",
  "inspector.tool.elapsed": "{duration} ms",
  "inspector.tool.input": "Input",
  "inspector.tool.command": "Command",
  "inspector.tool.command_succeeded": "Command completed · exit code {code}",
  "inspector.tool.command_failed": "Command failed · exit code {code}",
  "inspector.tool.stdout": "Standard output",
  "inspector.tool.stderr": "Standard error",
  "inspector.tool.stdout_incomplete":
    "Standard output is incomplete or truncated.",
  "inspector.tool.stderr_incomplete":
    "Standard error is incomplete or truncated.",
  "inspector.tool.start_line": "Start line",
  "inspector.tool.line_limit": "Line limit",
  "inspector.tool.read_content": "Read content",
  "inspector.tool.scope": "Scope",
  "inspector.tool.file_filter": "File filter",
  "inspector.tool.matches": "Matches",
  "inspector.tool.process_status": "Process status",
  "inspector.tool.process_running": "Running",
  "inspector.tool.process_exited": "Exited",
  "inspector.tool.process_killed": "Stopped",
  "inspector.tool.purpose": "Purpose",
  "inspector.tool.bytes": "Bytes",
  "inspector.tool.web_content": "Page content",
  "inspector.tool.error_detail": "Failure reason",
  "inspector.tool.bash_partially_unparsed":
    "Some Bash data could not be interpreted.",
  "inspector.tool.bash_unparsed":
    "This Bash call could not be interpreted. The safe original data is shown below.",
  "inspector.tool.unparsed_data": "Unparsed data",
  "inspector.tool.progress": "Progress",
  "inspector.tool.result": "Result",
  "inspector.tool.truncated": "Some tool details were shortened.",
  "inspector.context_warning": "Context is filling up",
  "inspector.context_critical": "Context compaction is approaching",
  "inspector.context_pressure_detail":
    "{current} tokens now · auto-compact at {compact} · limit {limit}",
  "task.information": "Task information",
  "task.selected_provider": "Selected provider",
  "task.current_run_model": "Current run model",
  "task.last_run_model": "Last run model",
  "task.current_run_protocol": "Current run protocol",
  "task.last_run_protocol": "Last run protocol",
  "task.current_run_global_instructions": "Current run global instructions",
  "task.last_run_global_instructions": "Last run global instructions",
  "task.current_run_project_instructions": "Current run project instructions",
  "task.last_run_project_instructions": "Last run project instructions",
  "task.instructions.applied": "Used",
  "task.instructions.applied_truncated": "Used (truncated to 32 KiB)",
  "task.instructions.global_absent": "Not set",
  "task.instructions.project_absent": "No AGENTS.md",
  "task.instructions.empty": "File is empty",
  "task.instructions.unreadable": "Could not be read: {reason}",
  "task.instructions.reason.access_denied": "permission denied",
  "task.instructions.reason.not_regular_file": "not a regular file",
  "task.instructions.reason.outside_workspace":
    "links outside the working directory",
  "task.instructions.reason.not_utf8": "not UTF-8 text",
  "task.instructions.reason.invalid_path":
    "path has a control character or is too long",
  "task.instructions.reason.io_error": "read error",
  "task.instructions.rejected": "Not used: the agent refused it",
  "task.instructions.update_failed":
    "Not updated for this run; it kept the version added earlier",
  "task.instructions.not_installed":
    "Not added: this run could not be updated, so it has none of this file",
  "task.instructions.unavailable": "No home folder",
  "task.information_scope":
    "Connector information reflects tool selection at task creation, not current connection status. Approval mode shows the current conversation setting.",
  "conversation.context_observed":
    "Latest observation for this conversation, not a live usage meter.",
  "task_panel.title": "Side panel",
  "task_panel.empty": "Open a file or review changes from the conversation.",
  "task_panel.tabs": "Open items",
  "task_panel.file_tree": "Workspace files",
  "task_panel.directory_unavailable":
    "Select a task with an available workspace to browse files.",
  "task_panel.directory_empty": "No browsable files in this folder.",
  "task_panel.directory_truncated":
    "Some entries are not shown because this folder exceeds the browsing limit.",
  "task_panel.directory_redacted": "Some entries are hidden for security.",
  "task_panel.directory_capacity":
    "Directory limit reached. Refresh to browse other folders.",
  "task_panel.refresh_directory": "Refresh workspace files",
  "task_panel.retry_directory": "Retry loading folder",
  "task_panel.show_file_tree": "Show file tree",
  "task_panel.hide_file_tree": "Hide file tree",
  "task_panel.close_tab": "Close {title}",
  "task_panel.hide": "Hide side panel",
  "task_panel.open": "Open side panel",
  "task_panel.close": "Close side panel",
  "approval.answered_by_reviewer": "Automatic review",
  "approval.review_approved_count": "Automatic approvals ({count})",
  "approval.action.command": "Allow this command to run?",
  "approval.action.read": "Allow reading “{target}”?",
  "approval.action.write": "Allow writing “{target}”?",
  "approval.action.edit": "Allow changing “{target}”?",
  "approval.action.web_fetch": "Allow requesting this URL?",
  "approval.manual_mode":
    "This task uses manual approval. Please confirm this operation.",
  "approval.confirm_request":
    "Please decide whether to proceed with this operation.",
  "approval.review_history": "Automatic review record",
  "approval.reviewer_note": "Reviewer’s note:",
  "approval.agent_purpose": "Agent’s description:",
  "approval.command": "Command to run",
  "approval.partial_preview":
    "Only part of this operation is shown. Open operation details to see it in full.",
  "approval.command_effects":
    "The system has not verified the command’s full effects.",
  "approval.command_unavailable":
    "The command is unavailable. View operation details.",
  "approval.full_request": "View operation details",
  "approval.hide_request": "Hide operation details",
  "approval.handoff.rejection_limit":
    "Repeated review denials require your decision for this operation. Automatic review resumes afterward.",
  "approval.handoff.unavailable":
    "Automatic review could not finish. Please confirm.",
  "approval.handoff.reviewer_concern":
    "Automatic review raised a concern that needs your confirmation.",
  "approval.handoff.context_incomplete":
    "Automatic review is missing required information. Please confirm.",
  "approval.handoff.timeout": "Automatic review timed out. Please confirm.",
  "approval.handoff.call_failed":
    "Automatic review is temporarily unavailable. Please confirm.",
  "approval.handoff.invalid_response":
    "Automatic review returned no valid decision. Please confirm.",
  "approval.handoff.capacity": "Automatic review is busy. Please confirm.",
  "approval.handoff.input_changed":
    "Automatic review has not considered your new instructions. Please confirm.",
  "approval.handoff.state_changed":
    "Permission settings changed. Please confirm again.",
  "approval.allow_tool": "Allow {tool}?",
  "approval.arguments": "Arguments",
  "approval.deny": "Deny",
  "approval.allow_once": "Allow once",
  "approval.allow_session_file": "Allow further changes to this file",
  "approval.deny_session_file": "Deny further changes to this file",
  "approval.scope_file_session":
    "Only {tool} changes to this file are covered. The changes may differ.",
  "approval.allow_session": "Allow future identical operations",
  "approval.deny_session": "Deny future identical operations",
  "approval.more_allow_options": "More approval options",
  "approval.scope_once": "Only this operation",
  "approval.scope_session_available":
    "The full operation details must match this request exactly.",
  "approval.session_expiry":
    "Expires when this session ends. Does not apply to new conversations.",
  "approval.why_again": "Why MetaWork is asking again",
  "approval.reason_allowed_once":
    "The previous approval applied only to that request.",
  "approval.reason_denied_once":
    "The previous denial applied only to that request.",
  "approval.reason_policy_changed":
    "The permission policy changed after the previous decision.",
  "approval.reason_candidate_changed":
    "AgentCore issued a different session-rule identity for this request.",
  "approval.reason_session_choice_unavailable":
    "AgentCore did not offer a session-scoped choice for this request.",
  "approval.restore_rules_invalidated":
    "Some session rules were invalidated during restoration. MetaWork cannot tell whether they relate to this request.",
  "approval.reason_session_grant_missed":
    "This request matches the previous session rule, but AgentCore asked again. The earlier grant may not have been applied.",
  "approval.response_failed": "The response could not be sent. Try again.",
  "approval.response_sent": "Response sent.",
  "approval.sending": "Sending your response…",
  "approval.awaiting_snapshot":
    "Response received. Updating this task before another action is allowed…",
  "approval.retry_response": "Response result not yet confirmed",
  "ui.kind.permission": "Permission request",
  "ui.state.allowed_once": "Allowed once",
  "ui.state.allowed_always": "Allowed for this session",
  "ui.state.denied": "Denied",
  "ui.state.denied_session": "Denied for this session",
  "ui.state.cancelled": "Cancelled",
  "view.refresh_after_commit_failed":
    "{operation} succeeded, but the latest state has not loaded. Retry syncing to confirm it.",
  "operation.task_create": "Task creation",
  "operation.run_submit": "Starting work",
  "operation.run_stop": "Stopping work",
  "operation.compact": "Compacting context",
  "operation.compact_stop": "Stopping context compaction",
  "operation.restore": "Restoring the conversation",
  "operation.ui_response": "Sending the response",
  "operation.task_rename": "Renaming the task",
  "operation.task_archive": "Archiving the task",
  "operation.task_restore": "Restoring the task",
  "operation.task_delete": "Deleting the task record",
  "operation.workspace_remove": "Removing the workspace",
  "search.open": "Search",
  "search.loading": "Searching…",
  "search.result_unavailable": "That task is no longer available.",
  "search.no_more": "No more matches.",
  "search.more": "Continue search",
  "search.first": "Back to first page",
  "search.title": "Search MetaWork",
  "search.placeholder": "Search workspaces, tasks, and completed work…",
  "search.hint":
    "Search across every workspace. Tool details stay out of results.",
  "search.no_results": "No matching work found.",
  "search.kind.task": "Task",
  "search.kind.instruction": "Instruction",
  "search.kind.completion": "Completion",
  "account.connection_attention": "Sign-in needs attention",
  "account.logout_short": "Sign out…",
  "account.api_fallback": "Metask API",
  "account.model_fallback": "Available model",
  "account.unknown_provider": "Unknown provider",
  "settings.title": "Settings",
  "settings.back": "Back to main view",
  "settings.sections": "Settings sections",
  "settings.general": "General",
  "settings.account": "Account",
  "settings.models": "Models",
  "settings.instructions": "Global instructions",
  "settings.instructions.global": "Instructions for every task",
  "settings.instructions.help":
    "MetaWork adds this file to the system prompt of every task. Where it conflicts with the AGENTS.md in a task's working directory, the project instructions win. Instructions never change the safety, permission or approval rules.",
  "settings.instructions.loading": "Loading…",
  "settings.instructions.load_failed":
    "The instructions file could not be loaded.",
  "settings.instructions.reload": "Reload",
  "settings.instructions.absent":
    "This file does not exist yet. Saving creates it.",
  "settings.instructions.size": "{bytes} / {limit} bytes",
  "settings.instructions.save": "Save",
  "settings.instructions.saving": "Saving…",
  "settings.instructions.saved":
    "Saved. Turns that start from now on use these instructions.",
  "settings.instructions.over_limit":
    "Instructions can be at most 32 KiB. Shorten the text to save it.",
  "settings.instructions.invalid_text":
    "The text contains characters that cannot be saved.",
  "settings.instructions.save_contains_credential":
    "The text contains a credential MetaWork stores, so it was not saved.",
  "settings.instructions.save_failed":
    "The file could not be saved. Your text is still here; try again.",
  "settings.instructions.conflict":
    "The file was changed outside MetaWork after it was loaded. Reload to see that version, or overwrite it with your text.",
  "settings.instructions.overwrite": "Overwrite",
  "settings.instructions.unavailable":
    "There is no home folder to keep global instructions in.",
  "settings.instructions.too_large_to_edit":
    "The file is {size} bytes, too large to edit here. Open the path above in another editor to shorten it.",
  "settings.instructions.unreadable":
    "The file cannot be read as text. Open the path above in another editor to fix it.",
  "settings.instructions.contains_credential":
    "The file contains a credential MetaWork stores, so it is not shown here. Open the path above in another editor to change it.",
  "settings.general_basics": "Basics",
  "settings.automatic_workspace.title": "Automatic Workspace location",
  "settings.automatic_workspace.help":
    "New automatic workspaces use a new random folder inside this location. Existing tasks and conversations do not move.",
  "settings.automatic_workspace.system_default": "Default",
  "settings.automatic_workspace.location_unavailable": "Location unavailable",
  "settings.automatic_workspace.choose": "Choose folder…",
  "settings.automatic_workspace.choosing": "Choosing…",
  "settings.automatic_workspace.reset": "Use system default",
  "settings.automatic_workspace.resetting": "Resetting…",
  "settings.automatic_workspace.retry": "Retry",
  "settings.automatic_workspace.retrying": "Retrying…",
  "settings.automatic_workspace.command_failed":
    "The location could not be changed. Try again.",
  "settings.automatic_workspace.health.ready": "Ready",
  "settings.automatic_workspace.health.path_unavailable":
    "This folder is unavailable. New automatic workspaces are paused until you retry or choose another folder.",
  "settings.automatic_workspace.health.persistence_unavailable":
    "Automatic Workspace location settings are unavailable in this installation.",
  "settings.automatic_workspace.health.read_failed":
    "MetaWork could not read the saved location. Choose a folder or restore the system default.",
  "settings.automatic_workspace.health.corrupt":
    "The saved location setting is invalid. Choose a folder or restore the system default.",
  "settings.automatic_workspace.health.write_failed":
    "The new choice could not be saved. The previously saved location remains active.",
  "settings.automatic_workspace.health.write_failed_no_active":
    "The location could not be saved. New automatic workspaces are paused until you choose a folder or restore the system default.",
  "settings.automatic_workspace.health.outcome_unknown":
    "MetaWork cannot confirm whether the location was saved. New automatic workspaces are paused; choose a folder or restore the system default.",
  "settings.account_profile": "Account information",
  "settings.account_usage": "Account usage",
  "settings.account_usage_scope":
    "These figures cover your whole Metask account, not only activity in MetaWork.",
  "settings.account_recharge": "Recharge",
  "settings.account_recharge_browser_hint":
    "Open the Metask recharge page in your browser",
  "settings.account_usage_stale": "May be out of date",
  "settings.account_usage_syncing": "Syncing…",
  "settings.account_usage_unavailable": "Temporarily unavailable",
  "settings.account_usage_mode_unknown":
    "MetaWork cannot confirm this account's usage mode yet. Refresh to try again.",
  "settings.account_usage_synced_at": "Data synced {value}",
  "settings.account_usage_not_synced": "Account usage has not synced yet",
  "settings.account_usage_refreshing": "Refreshing account usage…",
  "settings.account_usage_refresh": "Refresh account usage",
  "settings.account_history_title": "Token usage history",
  "settings.account_history_range": "Past {weeks} weeks · Daily",
  "settings.account_history_weekdays": "Mon|Tue|Wed|Thu|Fri|Sat|Sun",
  "settings.account_history_grid_label": "Daily Token usage calendar",
  "settings.account_history_day_label": "{date}, {tokens} Token",
  "settings.account_history_day_detail":
    "Input {input} · Output {output} · Cache created {cacheCreation} · Cache read {cacheRead} · Recorded cost {cost} U",
  "settings.account_history_legend_label": "Usage intensity from less to more",
  "settings.account_history_less": "Less",
  "settings.account_history_more": "More",
  "settings.builtin_provider_address_warning":
    "Model requests will send the API key to {host}.",
  "settings.get_api_key": "Get an API key",
  "settings.open_provider_docs": "Open official documentation",
  "settings.models_reset_message": "Custom model configuration cannot be read",
  "settings.models_reset_detail":
    "Metask models work as usual; custom models are unavailable for now. Recovery first reads the configuration again: what this version can read is restored as it is; what it cannot read (written by another version, or damaged) is saved aside and the custom models are cleared. Your account, Tasks, Workspaces, and conversations are unchanged.",
  "settings.models_reset_action": "Recover model configuration",
  "settings.models_reset_dialog_title": "Recover model configuration?",
  "settings.models_reset_dialog_body":
    "MetaWork first validates and restores the existing configuration. A configuration this version cannot read is saved aside, then the custom models are cleared and the custom model keys it can identify are removed from the system credential store; your account, Tasks, Workspaces, and conversations stay intact.",
  "settings.models_credentials_retained":
    "Some credentials may not have been cleaned up: the original configuration named custom model keys this version could not identify, and they may still be in the system credential store. The original file was saved aside.",
  "settings.models_reset_confirm": "Recover and continue",
  "settings.models_reset_pending": "Recovering…",
  "settings.models_reset_failed":
    "Model configuration recovery result not yet confirmed",
  "permission.profile.approval_required": "Request approval",
  "permission.mode.manual": "Manual approval",
  "permission.mode.manual.help":
    "Routine edits run automatically and other actions may need approval",
  "permission.mode.auto_review": "Automatic approval",
  "permission.mode.auto_review.help":
    "The model reviews requests and asks you if unsure",
  "permission.mode.full_access": "Full access",
  "permission.mode.full_access.help":
    "Routine actions skip approval while system protections still apply",
  "permission.auto_review.boundary":
    "Automatic review uses the task model and incurs additional usage charges. It is not a safety guarantee and decides only this operation. Built-in, Host and connector tools are reviewed against your task. Decisions requiring your input or review failures return to manual approval.",
  "permission.profile.approval_required.help":
    "Routine workspace edits run automatically. Other operations outside this policy require approval.",
  "permission.profile.full_access": "Full access",
  "permission.profile.full_access.help":
    "MetaWork skips approval for routine tool operations. AgentCore protections and system or service permissions can still block them.",
  "permission.new_task.label": "Approval mode",
  "permission.new_task.help":
    "Remembered across restarts for new Tasks. Existing conversations can change their own mode.",
  "permission.task.label": "Approval mode",
  "permission.task.help":
    "Shows the current mode of this conversation. Change it in the composer.",
  "permission.task.full_access.help":
    "This session uses Full access. Routine approval is skipped; AgentCore and system protections still apply.",
  "permission.task.menu_help":
    "Change approval mode for this conversation, keeping the workspace, attachments and history.",
  "permission.change.stop_help":
    "Stops the current run before switching; the run will not restart automatically.",
  "permission.change.pending": "Changing approval mode…",
  "permission.change.recovering":
    "The change did not complete. Restoring the original conversation…",
  "permission.change.sync_required":
    "The change is not yet confirmed. Refresh its status.",
  "permission.change.refresh": "Refresh status",
  "permission.change.completed": "Approval mode changed.",
  "permission.change.not_confirmed":
    "This change was not confirmed. Check the current mode before choosing again.",
  "permission.change.failure.cancelled": "The change was cancelled.",
  "permission.change.failure.busy":
    "The conversation is still busy. Approval mode did not change.",
  "permission.change.failure.budget_required":
    "The current call budget cannot cover this change.",
  "permission.change.failure.mode_update_failed":
    "Approval mode could not be changed. Check the current mode.",
  "permission.change.failure.checkpoint_failed":
    "The conversation could not be saved. Approval mode did not change.",
  "permission.change.failure.persistence_failed":
    "Approval mode could not be saved. Check the current mode before retrying.",
  "permission.change.failure.outcome_unknown":
    "The saved result is unknown. Recover task records, then refresh status.",
  "permission.change.failure.recovery_failed":
    "The original conversation could not be restored. Resolve the recovery notice to continue.",
  "permission.change.failure.dependency_contract":
    "The conversation runtime cannot perform this change.",
  "permission.change.rejection.task_not_found": "This task no longer exists.",
  "permission.change.rejection.stale_binding":
    "The conversation changed. Check its latest state before choosing.",
  "permission.change.rejection.stale_revision":
    "Approval mode changed. Check the latest mode before choosing.",
  "permission.change.rejection.busy":
    "Another operation is in progress. Choose again when it finishes.",
  "permission.change.rejection.task_closed": "This task is closed or archived.",
  "permission.change.rejection.unsupported_interaction":
    "This task does not support interactive approval changes.",
  "permission.change.rejection.unavailable":
    "This conversation cannot change approval mode right now. Check its recovery notice.",
  "permission.change.rejection.revision_exhausted":
    "This conversation cannot change approval mode again.",
  "permission.change.rejection.review_exhausted":
    "This conversation cannot enable automatic review.",
  "permission.change.rejection.shutting_down":
    "MetaWork is closing. Restart before choosing.",
  "permission.menu_help":
    "Choose how this Task handles operations outside its current authority.",
  "permission.full_access.boundary":
    "Full access skips MetaWork approval for routine tool operations. AgentCore protections, operating system permissions, service authorization, and process identity can still block or require action. It is not root access or a sandbox.",
  "settings.api_key": "API key",
  "settings.custom_provider_protocol": "Protocol",
  "settings.custom_provider_endpoint": "Request URL (Endpoint)",
  "settings.custom_model_protocol_detected": "Detected API: {protocol}",
  "settings.custom_model_protocol_automatic":
    "Enter the complete request URL to detect the API format automatically.",
  "settings.custom_model_base_url": "Base URL",
  "settings.custom_model_gemini_address_help":
    "Enter the service root URL. Gemini model paths are generated automatically.",
  "settings.custom_models": "Custom models",
  "settings.model_connection_provider": "Model vendor",
  "settings.model_connection_choose_provider": "Choose a model vendor",
  "settings.model_connection_custom": "Custom / other service",
  "settings.model_connection_help":
    "Add a third-party model, then test it before using it in a task.",
  "settings.custom_model_root_help":
    "Enter the complete endpoint. If this is a Gemini Native service root, confirm below.",
  "settings.custom_model_gemini_confirm":
    "This is a Gemini Native service root",
  "settings.custom_model_address_error.address":
    "Enter a valid URL without credentials, query parameters, or a fragment.",
  "settings.custom_model_address_error.secure":
    "The API key would be sent unencrypted. HTTP is allowed only for this computer (localhost, 127.0.0.1, [::1]); use HTTPS for services on your network.",
  "settings.custom_model_address_error.path":
    "Enter an endpoint ending in /chat/completions, /responses, or /v1/messages.",
  "settings.custom_model_address_suggestion": "Use {endpoint}",
  "settings.model_form_error.choice": "Select a model vendor first.",
  "settings.model_form_error.address": "Enter the request URL.",
  "settings.model_form_error.api_key": "Enter an API key.",
  "settings.model_form_error.model_id": "Enter a model ID.",
  "settings.custom_model_test_start_failed":
    "Test start for {model} not yet confirmed",
  "settings.custom_model_remove_failed":
    "Model removal result not yet confirmed",
  "settings.model_edit_partial":
    "Some changes were saved ({fields}). Review the remaining fields and re-enter the API key if needed before saving again.",
  "settings.model_edit_review":
    "The configuration changed or the save result could not be confirmed. Reopen the model to review its latest configuration.",
  "settings.model_connection_edit_help":
    "Save changes to the model. Leave the API key blank to keep it unchanged.",
  "settings.model_connection_dialog_help":
    "Choose a vendor or custom service, enter the model, and save.",
  "settings.model_connection_empty": "No custom models yet.",
  "settings.model_connection_edit": "Edit model",
  "settings.model_connection_shared":
    "These connection settings are shared by {count} models. Changes require testing the models again.",
  "settings.custom_model_testing": "Testing…",
  "settings.custom_model_test_status.untested": "Not tested",
  "settings.custom_model_test_status.testing": "Testing",
  "settings.custom_model_test_status.connected": "Test passed",
  "settings.custom_model_test_status.failed": "Test failed",
  "settings.custom_provider_protocol.openai_responses": "OpenAI Responses",
  "settings.custom_provider_protocol.anthropic_messages": "Anthropic Messages",
  "settings.custom_provider_protocol.openai_chat_completions":
    "OpenAI Chat Completions",
  "settings.custom_provider_protocol.gemini_native": "Gemini Native",
  "settings.custom_provider_credential.ready": "Credential available",
  "settings.custom_provider_credential.capture_unavailable":
    "Secure API key storage is unavailable",
  "settings.custom_provider_credential.missing": "Credential required",
  "settings.custom_provider_credential.invalid": "Credential rejected",
  "settings.catalog_count": "Models {models}",
  "settings.language_help": "Changes apply immediately on this device.",
  "settings.new_task_model_invalid":
    "The previously selected model is no longer available. Choose another model before sending.",
  "settings.custom_model_add": "Add model",
  "settings.custom_model_test": "Test model",
  "settings.custom_model_id": "Model ID",
  "settings.custom_model_image_input": "Image input",
  "settings.custom_model_image_input.supported": "Supported",
  "settings.custom_model_image_input.unsupported": "Not supported",
  "settings.custom_model_image_input.unknown": "Not sure",
  "settings.custom_model_image_input_help":
    "With “Not sure”, MetaWork decides from the model name and treats unknown models as text-only.",
  "settings.custom_model_remove_confirm": "Remove model?",
  "settings.custom_model_remove_description":
    "After removing “{model}”, it will no longer be selectable for new tasks. Existing tasks and their history will be kept.",
  "settings.choose_selection": "Choose",
  "settings.change_selection": "Change",
  "settings.view_selection": "View options",
  "settings.task_model_help":
    "Choose the model for messages sent in this task.",
  "settings.task_model_catalog_loading":
    "The model catalog is updating. You can choose a model when it finishes.",
  "settings.task_model_catalog_unavailable":
    "The model catalog is unavailable. This task keeps its model until the catalog recovers.",
  "settings.task_model_task_unavailable":
    "This task cannot be edited right now, so its model cannot be changed.",
  "outcome.completed": "Completed",
  "outcome.stopped": "Stopped",
  "outcome.cancelled": "Stopped",
  "outcome.interrupted": "Interrupted",
  "outcome.failed": "Failed",
  "outcome.dependency_contract_failure": "Task runtime failed",
  "cause.user_cancel": "Stopped by you",
  "cause.approval_mode_change": "Stopped to change the approval mode",
  "cause.account_logout": "Stopped to sign out",
  "cause.edit_and_rerun": "Stopped to rerun from an edited message",
  "cause.timeout": "Timed out",
  "cause.session_close": "Session released",
  "cause.app_shutdown": "MetaWork closed",
  "cause.event_pipeline_failure": "The run did not complete normally.",
  "cause.event_payload_too_large":
    "A single execution result exceeded the size limit",
  "cause.queue_capacity_failure":
    "The execution queue had insufficient capacity to continue",
  "cause.ui_pipeline_failure": "Response delivery failed",
  "cause.agent_failure": "Agent execution failed",
  "cause.provider_failure": "Model service request failed",
  "cause.tool_failure": "The tool process could not complete",
  "cause.image_input_unsupported":
    "The current model could not accept this image input",
  "cause.dependency_contract_failure": "Task runtime became incompatible",
  "cause.stale_catalog":
    "Skill execution did not start because the catalog is out of date",
  "cause.skill_not_found":
    "Skill execution did not start because the skill is no longer available",
  "cause.invalid_skill_arguments":
    "This Skill could not start with the message provided",
  "cause.skill_policy_violation":
    "Skill execution did not start because it is not allowed in this task",
  "cause.skill_unavailable":
    "Skill execution did not start because it is unavailable in the current execution environment",
  "cause.resource_limit": "Task runtime resource limit reached",
  "cause.permission_required": "Permission required",
  "workspace.selection_unavailable":
    "That workspace is no longer available. Refresh and choose another one.",
  "account.options_updated":
    "Available options were updated. Review them and choose again.",
  "mutation.transport_failed": "MetaWork could not confirm the change.",
  "mutation.reason.session_releasing":
    "Releasing an idle session. Please retry shortly.",
  "mutation.reason.session_capacity":
    "No execution session can currently be safely released. Please retry later.",
  "mutation.reason.session_close_failed":
    "The session for task “{task}” could not close. Resolve that task before retrying.",
  "mutation.reason.execution_changed":
    "Your execution settings changed. Review them and try again.",
  "mutation.reason.execution_unavailable":
    "The selected execution setup is not available right now.",
  "mutation.reason.workspace_changed":
    "This workspace changed. Review its latest state and try again.",
  "mutation.reason.project_unavailable":
    "This project is no longer available. Choose another project.",
  "mutation.reason.workspace_unavailable":
    "This workspace is no longer available.",
  "mutation.reason.workspace_removing":
    "This workspace is being removed. Wait for it to finish.",
  "mutation.reason.binding_changed":
    "This task's execution setup changed. Review it before continuing.",
  "mutation.reason.binding_unavailable":
    "This task's execution setup is no longer available.",
  "mutation.reason.models_catalog_loading":
    "Waiting for the Metask model catalog to refresh.",
  "mutation.reason.models_catalog_failed":
    "The Metask model catalog failed to refresh.",
  "mutation.reason.metask_authorization_required":
    "Sign in to Metask to use this model.",
  "mutation.reason.metask_authorization_recovering":
    "Connecting to Metask. This message runs once connected, or is marked not run if this attempt fails.",
  "mutation.reason.metask_connection_unavailable":
    "Can't reach Metask right now. The message was not run.",
  "mutation.reason.session_poisoned":
    "The current session can no longer continue.",
  "mutation.reason.checkpoint_unavailable":
    "The saved checkpoint is unavailable.",
  "mutation.reason.execution_rebind_required":
    "The saved conversation needs a valid execution setup.",
  "input.retry_models_catalog": "Retry model refresh",
  "input.session_close_failed": "This task's session could not close.",
  "input.retry_session_close": "Retry closing session",
  "mutation.reason.model_changed":
    "This task's model changed elsewhere. Refresh and choose again.",
  "task.model.updated": "Task model updated.",
  "mutation.reason.task_unavailable": "This task is no longer available.",
  "mutation.reason.recovery_unavailable":
    "This conversation can no longer be restored from the current saved state.",
  "mutation.reason.persistence_unavailable":
    "Model selection cannot be saved. Recover task history first.",
  "mutation.reason.persistence_failed":
    "Model selection was not saved. The previous selection is unchanged.",
  "mutation.reason.persistence_outcome_unknown":
    "The model selection save is unconfirmed. Recover task history before sending.",
  "mutation.reason.task_busy": "This task is already working.",
  "mutation.reason.no_history": "Run this task once before compacting context.",
  "mutation.reason.catalog_loading":
    "Capabilities are refreshing. Please wait a moment and try again.",
  "mutation.reason.catalog_unavailable":
    "Skills are unavailable for this workspace or task.",
  "mutation.reason.model_selection_changed":
    "Available models changed. Choose the model again and retry.",
  "mutation.reason.stale_catalog":
    "The skill catalog changed. Refresh it and choose the skill again.",
  "mutation.reason.skill_not_found":
    "The selected skill is no longer in this task's catalog.",
  "mutation.reason.skill_unavailable":
    "The selected skill is disabled for this task.",
  "mutation.reason.invalid_skill_arguments":
    "Review the message or choose another Skill, then try again.",
  "mutation.reason.missing_instruction":
    "Describe what you want the Agent to do with the attached text.",
  "mutation.reason.unsupported_attachment":
    "The attachment is no longer available or valid.",
  "mutation.reason.capacity_reached":
    "MetaWork is at capacity. Finish or close some work, then try again.",
  "mutation.reason.shutting_down":
    "MetaWork is closing. Try again after restart.",
  "scheduled.title": "Scheduled tasks",
  "scheduled.subtitle":
    "Run tasks on schedule and get notified when they finish.",
  "scheduled.new": "New",
  "scheduled.no_next_run": "No next run",
  "scheduled.pause": "Pause",
  "scheduled.resume": "Resume",
  "scheduled.run_now": "Run now",
  "scheduled.editing": "Editing schedule",
  "scheduled.creating": "New schedule",
  "scheduled.error": "MetaWork could not complete this schedule change.",
  "scheduled.name": "Name",
  "scheduled.what": "What to run",
  "scheduled.instruction_placeholder": "Describe what MetaWork should do…",
  "scheduled.instruction": "Instruction",
  "scheduled.permission": "Permissions",
  "scheduled.permission.approval_required.help":
    "Stops and needs attention when approval is required.",
  "scheduled.permission.full_access.help":
    "Skips routine approval; system protections still apply.",
  "scheduled.when": "When",
  "scheduled.weekday.1": "Mon",
  "scheduled.weekday.2": "Tue",
  "scheduled.weekday.3": "Wed",
  "scheduled.weekday.4": "Thu",
  "scheduled.weekday.5": "Fri",
  "scheduled.weekday.6": "Sat",
  "scheduled.weekday.7": "Sun",
  "scheduled.monthday": "{day}",
  "scheduled.day_separator": ", ",
  "scheduled.repeat": "Repeat",
  "scheduled.recurrence.once": "Once",
  "scheduled.recurrence.hourly": "Hourly",
  "scheduled.recurrence.daily": "Daily",
  "scheduled.recurrence.weekly": "Weekly",
  "scheduled.recurrence.monthly": "Monthly",
  "scheduled.recurrence.yearly": "Yearly",
  "scheduled.invalid_time":
    "This time does not exist or is invalid. Choose another time.",
  "scheduled.recurrence.interval": "Fixed interval",
  "scheduled.date": "Date",
  "date_picker.previous_month": "Previous month",
  "date_picker.next_month": "Next month",
  "date_picker.today": "Today",
  "scheduled.time": "Time",
  "scheduled.every": "Every",
  "scheduled.interval_unit": "Interval unit",
  "scheduled.minutes": "Minutes",
  "scheduled.hours": "Hours",
  "scheduled.days": "Days",
  "scheduled.delete": "Delete schedule",
  "scheduled.confirm": "Confirm",
  "scheduled.saving": "Saving…",
  "scheduled.subtitle_background":
    "Run tasks on schedule, even with the window closed, and get notified when they finish.",
  "scheduled.search_placeholder": "Search scheduled tasks",
  "scheduled.clear_search": "Clear search",
  "scheduled.empty": "No scheduled tasks yet.",
  "scheduled.section.enabled": "Enabled",
  "scheduled.section.disabled": "Disabled",
  "scheduled.no_matches": "No matching schedules",
  "scheduled.no_matches_body": "Try another name or instruction keyword.",
  "scheduled.repeat.hourly": "Every hour",
  "scheduled.repeat.daily": "Every day",
  "scheduled.repeat.weekly": "Every week",
  "scheduled.next_run": "Next run",
  "scheduled.runs_in": "Runs {time}",
  "scheduled.awaiting_run": "Waiting to run",
  "scheduled.latest_run": "Latest run",
  "scheduled.enablement": "Enable schedule: {title}",
  "scheduled.view_history": "Run history: {title}",
  "scheduled.history_title": "Run history",
  "scheduled.actions": "Schedule actions: {title}",
  "scheduled.open_previous_task": "View previous run",
  "scheduled.changed":
    "This schedule has changed. Reloading will replace your unsaved edits.",
  "scheduled.reload": "Reload schedule",
  "scheduled.history_empty": "Results will appear here after the first run.",
  "scheduled.open_task": "View result",
  "scheduled.open_run": "View run",
  "scheduled.occurrence.completed": "Completed",
  "scheduled.occurrence.failed": "Run failed",
  "scheduled.occurrence.running": "Running",
  "scheduled.occurrence.skipped": "Skipped",
  "scheduled.occurrence.rejected": "Could not start",
  "scheduled.occurrence.starting": "Starting",
  "scheduled.persistence.unavailable":
    "Durable schedules are not available on this device.",
  "scheduled.persistence.read_failed": "Saved schedules could not be read.",
  "scheduled.persistence.corrupt":
    "Schedule data is damaged. Automatic runs are stopped to prevent duplicates.",
  "scheduled.persistence.write_failed":
    "The latest change could not be saved. Automatic runs are stopped.",
  "scheduled.persistence.outcome_unknown":
    "MetaWork cannot confirm whether the latest change was saved. Automatic runs are stopped to prevent duplicates.",
  "task.persistence.read_failed":
    "Saved task history could not be read. You can continue, but new work will not be saved in this session.",
  "task.persistence.corrupt":
    "Saved task history is invalid. MetaWork kept the original file; you can continue, but new work will not be saved in this session.",
  "task.persistence.write_failed":
    "The latest task change could not be saved. You can keep working while MetaWork retries later changes.",
  "task.persistence.outcome_unknown":
    "MetaWork could not confirm whether the latest task change was saved. You can keep working while later changes retry the save.",
  "persistence.recovery.action": "Start with a clean store",
  "persistence.recovery.original_retained":
    "The current file will be retained as a recovery copy.",
  "persistence.recovery.task.title": "Replace saved task history?",
  "persistence.recovery.task.body":
    "MetaWork will retain the current history file, then save the tasks and workspaces currently available in this session as the new history.",
  "persistence.recovery.scheduled.title": "Replace saved schedules?",
  "persistence.recovery.scheduled.hard_cut":
    "The current scheduled task file will be retained as a recovery copy.",
  "persistence.recovery.scheduled.body":
    "MetaWork will retain the current scheduled task file, then write the schedules still available in this session as a clean store. Retired formats will not be loaded.",
  "persistence.recovery.scheduled.confirm": "Retain file and reset",
  "persistence.recovery.cancel": "Keep current state",
  "persistence.recovery.confirm": "Retain file and recover",
  "persistence.recovery.running": "Recovering…",
  "persistence.recovery.stale_revision":
    "The app state changed. Review the current warning and try again.",
  "persistence.recovery.outcome_unknown":
    "MetaWork could not confirm the replacement. Review the current state before trying again.",
  "persistence.recovery.shutting_down":
    "MetaWork is closing and cannot start recovery.",
  "persistence.recovery.failed": "The store could not be replaced.",
  "mcp.mutation.busy":
    "This server has an authorization operation in progress.",
  "mcp.mutation.cancelled": "The confirmation was cancelled.",
  "mcp.mutation.capability_unavailable":
    "This action is unavailable on this device.",
  "mcp.auth.none": "None",
  "mcp.auth.static": "Static secrets",
  "mcp.auth.oauth": "OAuth",
  "mcp.negotiation.automatic": "Automatic",
  "mcp.negotiation.modern_only": "2026-07-28 only",
  "mcp.negotiation.compat_only": "2025-11-25 only",
  "mcp.detail.protocol": "Protocol policy",
  "mcp.detail.authentication": "Authentication",
  "mcp.detail.executable": "Executable",
  "mcp.detail.arguments": "Arguments",
  "mcp.detail.cwd": "Working directory",
  "mcp.detail.environment_names": "Environment names",
  "mcp.detail.header_names": "Header names",
  "mcp.detail.connection_unavailable": "Connection settings unavailable",
  "mcp.detail.connection_unavailable_help":
    "The configuration is invalid or contains recognized sensitive text. Remove the server and add it again.",
  "mcp.detail.registration": "Client registration",
  "mcp.summary.not_configured": "Not configured",
  "mcp.registration.none": "None",
  "mcp.registration.automatic": "Automatic (DCR)",
  "mcp.registration.pre_registered": "Existing client",
  "mcp.detail.authorization": "Authorization",
  "mcp.approval.required": "Legacy connection is not authorized",
  "mcp.approval.help":
    "This setting was saved by an older version. Connect it once to continue.",
  "mcp.approval.action": "Connect and enable",
  "mcp.capability.capture_unavailable":
    "Credential submission is currently unavailable.",
  "mcp.authorization_status.not_required": "No authorization required",
  "mcp.authorization_status.missing_static_secret":
    "One or more secrets are missing",
  "mcp.authorization_status.missing_oauth_client_secret":
    "OAuth client secret is missing",
  "mcp.authorization_status.client_registration_required": "Sign-in required",
  "mcp.authorization_status.consent_required": "Consent required",
  "mcp.authorization_status.authorizing": "Authorization in progress",
  "mcp.authorization_status.ready": "Authorization ready",
  "mcp.authorization_status.reauth_required": "Sign in again required",
  "mcp.authorization_status.capability_unavailable":
    "Required device capability unavailable",
  "mcp.secret.missing": "Missing",
  "mcp.secret.set": "Set",
  "mcp.secret.not_required": "Not required",
  "mcp.secret.client_secret": "OAuth client secret",
  "mcp.secret.too_long":
    "The credential exceeds {maxBytes} UTF-8 bytes. Shorten it and try again.",
  "mcp.authorization_phase.discovering": "Discovering OAuth metadata…",
  "mcp.authorization_phase.awaiting_consent": "Waiting for confirmation…",
  "mcp.authorization_phase.registering": "Registering client…",
  "mcp.authorization_phase.awaiting_browser": "Waiting for browser sign-in…",
  "mcp.authorization_phase.exchanging": "Completing sign-in…",
  "mcp.authorization_phase.refreshing": "Refreshing authorization…",
  "mcp.authorization_phase.cancelling": "Cancelling local wait…",
  "mcp.authorization_failure.summary": "{step} failed: {reason}.",
  "mcp.authorization_failure.http_status": "(HTTP {status})",
  "mcp.authorization_failure.remote": "Server response:",
  "mcp.authorization_failure.step.discovery": "Finding the sign-in service",
  "mcp.authorization_failure.step.registration": "Registering MetaWork",
  "mcp.authorization_failure.step.authorization": "Browser sign-in",
  "mcp.authorization_failure.step.token_exchange": "Getting the access token",
  "mcp.authorization_failure.reason.network": "the server could not be reached",
  "mcp.authorization_failure.reason.timed_out": "it took too long",
  "mcp.authorization_failure.reason.http_status":
    "the server returned an unexpected status",
  "mcp.authorization_failure.reason.oauth_error":
    "the server returned an error",
  "mcp.authorization_failure.reason.invalid_response":
    "the server's response could not be used",
  "mcp.authorization_failure.reason.resource_mismatch":
    "the server's OAuth metadata describes a different address",
  "mcp.authorization_failure.reason.unsupported_server":
    "the sign-in service lacks a capability MetaWork requires",
  "mcp.authorization_failure.reason.browser_unavailable":
    "the browser could not be opened",
  "mcp.authorization_failure.reason.invalid_callback":
    "the browser returned an invalid response",
  "mcp.authorization_failure.reason.internal":
    "MetaWork could not continue this step",
  "mcp.authorization.action": "Sign in",
  "mcp.authorization.again": "Sign in again",
  "mcp.authorization.cancel": "Cancel",
  "mcp.authorization_status.refreshing": "Updating authorization",
  "mcp.apply_status.waiting_auth": "Waiting for authorization recovery",
  "mcp.next.authorization_recovery.body":
    "Authorization will be recovered before this connection is retried automatically.",
  "mcp.banner.authorization.title": "Authorization in progress",
  "mcp.banner.authorization.body":
    "New server connections wait until authorization finishes. Existing tasks keep their current tools.",
  "mcp.authorization.busy": "Another OAuth authorization is in progress.",
  "mcp.authorization.started": "OAuth authorization started.",
  "mcp.authorization.rejected": "OAuth authorization could not start.",
  "mcp.authorization.stale_generation":
    "Configuration changed; review the latest state.",
  "mcp.authorization.capability_unavailable":
    "OAuth is unavailable on this device.",
  "mcp.cancel.cancelled": "Local authorization wait cancelled.",
  "mcp.cancel.saved": "Authorization state was safely updated.",
  "mcp.cancel.saved_recovery_required":
    "Authorization stopped, but local recovery is required.",
  "mcp.cancel.rejected": "The authorization operation no longer matches.",
  "mcp.cancel.indeterminate":
    "The remote request may have been sent. Sign in again before use.",
  "mcp.cancel.capability_unavailable": "OAuth cancellation is unavailable.",
  "operation.schedule": "schedule change",
  "scheduled.expired_once": "Choose a future time for this one-time run.",
  "scheduled.timeout":
    "The result is unconfirmed. A refresh was requested; check the current state before retrying.",
  "scheduled.occurrence.unavailable": "Original task unavailable",
  "scheduled.occurrence.stopped": "Stopped",
  "scheduled.occurrence.interrupted": "Interrupted",
  "scheduled.occurrence.delayed": "Delayed from {time}",
  "scheduled.reason.previous_task_running":
    "The previous task is still running.",
  "scheduled.reason.execution_changed":
    "The model or connection changed. Edit and confirm.",
  "scheduled.reason.workspace_unavailable":
    "Automatic workspaces are unavailable. Check settings, then edit and confirm.",
  "scheduled.reason.capacity_reached":
    "Run capacity is full. Free capacity, then edit and confirm.",
  "scheduled.reason.shutting_down":
    "The app is shutting down. Reopen it, then edit and confirm.",
  "scheduled.reason.task_start_failed":
    "The task could not start. Check the model and task settings, then edit and confirm.",
  "scheduled.reason.timer_unavailable":
    "The background timer is unavailable. Reopen the app, then edit and confirm.",
  "scheduled.reason.persistence_failed":
    "The run record could not be saved. Resolve the storage error first.",
  "scheduled.reason.host_interrupted":
    "The app interrupted the previous start. Edit and confirm; it will not retry automatically.",
  "scheduled.reason.permission_required":
    "The task stopped because permission was required. Review the instruction and permissions, then edit and confirm.",
  "scheduled.admission.waiting": "Runs once your account or model is ready.",
  "scheduled.admission.signed_out": "Runs after you sign in to Metask.",
  "scheduled.admission.other_account":
    "Bound to another Metask account. Switch back to it, or edit it to use a model from this account.",
  "scheduled.admission.model_unavailable":
    "The selected model is no longer available, so it will not run. Edit it to choose another model.",
  "scheduled.notification_unavailable":
    "The task from this notification is unavailable. Refresh and check your tasks.",
  "notification.schedule.completed": "Scheduled task completed",
  "notification.schedule.failed": "Scheduled task failed",
  "notification.schedule.skipped":
    "A run was skipped because the previous run is still active",
  "notification.schedule.model_unavailable":
    "A run was skipped because its model is no longer available",
  "notification.schedule.needs_attention": "Scheduled task needs attention",
  "notification.run.completed": "Task finished",
  "notification.run.failed": "Task failed",
  "notification.run.needs_approval": "Task is waiting for your approval",
} as const;
export type MessageId = keyof typeof enUS;

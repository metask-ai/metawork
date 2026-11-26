import type { NotificationTextRegistration } from "../../bridge/contracts.ts";
import type { MessageId } from "../../i18n/context.ts";

/**
 * Which catalog message fills each system-notification slot. The Host selects
 * a slot and injects the Task title; every word around it comes from here,
 * because the language only exists in this layer.
 *
 * Keying by the registration's own slots means a slot the Host adds is a type
 * error here until it is given a message — never a banner that arrives with
 * part of it missing.
 */
const slots: Record<keyof NotificationTextRegistration, MessageId> = {
  scheduleCompleted: "notification.schedule.completed",
  scheduleFailed: "notification.schedule.failed",
  scheduleSkipped: "notification.schedule.skipped",
  scheduleModelUnavailable: "notification.schedule.model_unavailable",
  scheduleNeedsAttention: "notification.schedule.needs_attention",
  runCompleted: "notification.run.completed",
  runFailed: "notification.run.failed",
  runNeedsApproval: "notification.run.needs_approval",
};

/**
 * The whole table in the current language. The Host refuses a partial
 * registration, so this builds every slot: there is no state in which one
 * notification has words and another does not.
 */
export function notificationTextRegistration(
  t: (id: MessageId) => string,
): NotificationTextRegistration {
  const registration = {} as Record<keyof NotificationTextRegistration, string>;
  for (const [slot, id] of Object.entries(slots) as [
    keyof NotificationTextRegistration,
    MessageId,
  ][])
    registration[slot] = t(id);
  return registration;
}

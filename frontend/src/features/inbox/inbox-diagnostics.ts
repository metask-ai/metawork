import type { InboxView } from "../../bridge/contracts.ts";
import type { MessageId } from "../../i18n/context.ts";

type Diagnostic = NonNullable<InboxView["diagnostic"]>;

// The inbox request evidence uses the same closed vocabulary as the update
// check (both are the HTTP execution layer's typed facts), so it is described
// with the same words.
const phases: Record<Diagnostic["phase"], MessageId> = {
  admission: "updates.phase.admission",
  resolve: "updates.phase.resolve",
  connect: "updates.phase.connect",
  send: "updates.phase.send",
  head: "updates.phase.head",
  body: "updates.phase.body",
  complete: "updates.phase.complete",
};

const causes: Record<Diagnostic["cause"], MessageId> = {
  invalid_request: "updates.cause.invalid_request",
  dns_failed: "updates.cause.dns_failed",
  connect_failed: "updates.cause.connect_failed",
  tls_failed: "updates.cause.tls_failed",
  write_failed: "updates.cause.write_failed",
  read_failed: "updates.cause.read_failed",
  invalid_response: "updates.cause.invalid_response",
  response_too_large: "updates.cause.response_too_large",
  out_of_memory: "updates.cause.out_of_memory",
  resource_limit: "updates.cause.resource_limit",
  cancelled: "updates.cause.cancelled",
  deadline_exceeded: "updates.cause.deadline_exceeded",
};

const elapsed: Record<Diagnostic["elapsed"], MessageId> = {
  under_1s: "updates.elapsed.under_1s",
  under_5s: "updates.elapsed.under_5s",
  under_15s: "updates.elapsed.under_15s",
  over_15s: "updates.elapsed.over_15s",
};

/** One line built only from catalog words: no endpoint or address. */
export function inboxDiagnosticText(
  diagnostic: Diagnostic,
  t: (id: MessageId, values?: Record<string, string>) => string,
): string {
  return t("updates.diagnostic_line", {
    phase: t(phases[diagnostic.phase]),
    cause: t(causes[diagnostic.cause]),
    elapsed: t(elapsed[diagnostic.elapsed]),
  });
}

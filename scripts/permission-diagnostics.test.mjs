import assert from "node:assert/strict";
import test from "node:test";

import { diagnoseRepeatedPermission } from "../frontend/src/features/approvals/permission-diagnostics.ts";

const pending = {
  requestId: "2",
  runId: "1",
  order: "2",
  redacted: false,
  kind: "permission",
  toolNamespace: "builtin",
  tool: "Bash",
  toolBinding: "bash-binding",
  args: "redacted at the diagnostic boundary",
  availableChoices: ["deny_once", "allow_once", "allow_session"],
  policyGeneration: "7",
  canonicalArgumentsDigest: "digest-a",
  candidate: { ruleId: "rule-a", scope: "exact_arguments" },
};

function record(state = "allowed_always", overrides = {}) {
  return {
    requestId: "1",
    runId: "1",
    order: "1",
    kind: "permission",
    state,
    agentRequestId: "agent-1",
    permission: {
      requestId: "agent-1",
      matchedRuleId: "rule-a",
      toolNamespace: "builtin",
      toolName: "Bash",
      toolBinding: "bash-binding",
      canonicalArgumentsDigest: "digest-a",
      decision: "allow",
      source: "callback",
      policyGeneration: "7",
      usedSessionRule: false,
      callbackOutcome: "answered",
      ...overrides,
    },
    detail: "",
    itemCount: 0,
    detailTruncated: false,
    redacted: false,
  };
}

function task(previous = record(), invalidatedRules = "0") {
  return {
    uiHistory: [previous],
    restorePermission: { restoredRules: "0", invalidatedRules },
  };
}

test("identical request after the same Session grant is diagnosed as a missed grant", () => {
  assert.equal(
    diagnoseRepeatedPermission(task(), pending)?.reason,
    "session_grant_missed",
  );
});

test("one-time approval and policy changes remain explicit explanations", () => {
  assert.equal(
    diagnoseRepeatedPermission(task(record("allowed_once")), pending)?.reason,
    "allowed_once",
  );
  assert.equal(
    diagnoseRepeatedPermission(
      task(record("allowed_always", { policyGeneration: "6" })),
      pending,
    )?.reason,
    "policy_changed",
  );
});

test("exact_arguments changes are not mislabeled as a repeated request", () => {
  assert.equal(
    diagnoseRepeatedPermission(task(), {
      ...pending,
      canonicalArgumentsDigest: "digest-b",
    }),
    null,
  );
});

test("candidate and restore changes explain why a Session grant is unavailable", () => {
  assert.equal(
    diagnoseRepeatedPermission(task(), {
      ...pending,
      candidate: { ruleId: "rule-b", scope: "exact_arguments" },
    })?.reason,
    "candidate_changed",
  );
  assert.equal(
    diagnoseRepeatedPermission(task(record(), "1"), pending)?.reason,
    "session_rule_invalidated",
  );
  assert.equal(
    diagnoseRepeatedPermission(task(), { ...pending, candidate: null })?.reason,
    "session_choice_unavailable",
  );
});

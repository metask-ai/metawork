import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { once } from "node:events";

// Run the actual evaluator: isolated failures continue without retries, while
// unusable credentials stop sampling. Complete attempts do not imply quality.
const executable = process.argv[2];
assert.ok(executable);
for (const scenario of [
  { name: "overloaded", calls: "full", error: "EvaluationAcceptanceFailed" },
  { name: "invalid-json", calls: "full", error: "EvaluationAcceptanceFailed" },
  { name: "all-invalid-json", calls: "full", error: "EvaluationUnjudgedCases" },
  { name: "unauthorized", calls: 1, error: "EvaluationTerminalFailure" },
  {
    name: "bounded-success",
    calls: 2,
    error: "DiagnosticSamplesOnly",
    overrides: {
      METAWORK_REVIEW_EVAL_MAX_SAMPLES: "2",
      METAWORK_REVIEW_EVAL_DEADLINE_MS: "120000",
    },
  },
  {
    name: "invalid-limit",
    calls: 0,
    error: "InvalidDiagnosticSampleLimit",
    overrides: { METAWORK_REVIEW_EVAL_MAX_SAMPLES: "0" },
  },
  {
    name: "invalid-deadline",
    calls: 0,
    error: "InvalidDiagnosticDeadline",
    overrides: { METAWORK_REVIEW_EVAL_DEADLINE_MS: "120001" },
  },
]) {
  const failure = scenario.name;
  let calls = 0;
  const server = createServer(async (request, response) => {
    for await (const _ of request) {
      /* drain the synthetic request */
    }
    calls++;
    response.setHeader("content-type", "application/json");
    if (failure === "unauthorized") {
      response.writeHead(401);
      response.end(
        '{"error":{"type":"authentication_error","message":"private fixture diagnostic"}}',
      );
    } else if (failure === "overloaded" && calls === 1) {
      response.writeHead(503);
      response.end(
        '{"error":{"type":"overloaded_error","message":"private fixture diagnostic"}}',
      );
    } else if (
      failure === "bounded-success" ||
      (failure !== "all-invalid-json" && calls > 1)
    ) {
      response.end(
        JSON.stringify({
          type: "message",
          stop_reason: "end_turn",
          content: [
            {
              type: "text",
              text: '{"decision":"allow_once","reason":"synthetic local request"}',
            },
          ],
        }),
      );
    } else {
      response.end(
        JSON.stringify({
          type: "message",
          stop_reason: "end_turn",
          content: [{ type: "text", text: '{"decision":"allow_once"' }],
        }),
      );
    }
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  try {
    const env = {
      ...process.env,
      METAWORK_REVIEW_EVAL_PROTOCOL: "anthropic_messages",
      METAWORK_REVIEW_EVAL_MODEL: "fixture-review",
      METAWORK_REVIEW_EVAL_BASE_URL: `http://127.0.0.1:${server.address().port}/v1/messages`,
      METAWORK_REVIEW_EVAL_API_KEY: "synthetic-review-key",
      METAWORK_REVIEW_EVAL_REVISION: "local-failure-regression",
      METAWORK_REVIEW_EVAL_REPEATS: "3",
    };
    delete env.METAWORK_REVIEW_EVAL_CASE;
    delete env.METAWORK_REVIEW_EVAL_DEADLINE_MS;
    delete env.METAWORK_REVIEW_EVAL_SCHEMA_PROBE;
    delete env.METAWORK_REVIEW_EVAL_MAX_SAMPLES;
    Object.assign(env, scenario.overrides);
    const child = spawn(executable, [], {
      env,
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
      timeout: 45_000,
    });
    let output = "";
    let errors = "";
    child.stdout.setEncoding("utf8").on("data", (text) => {
      output += text;
    });
    child.stderr.setEncoding("utf8").on("data", (text) => {
      errors += text;
    });
    const [code, signal] = await once(child, "close");
    assert.equal(signal, null, errors);
    assert.notEqual(code, 0);
    assert.ok(errors.includes(scenario.error), errors);
    if (scenario.calls === 0) {
      assert.equal(calls, 0);
      assert.equal(output.trim(), "");
      process.stdout.write(
        `permission evaluation ${failure}: rejected before HTTP\n`,
      );
      continue;
    }
    const rows = output
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line));
    const coverage = rows.find((row) => row.kind === "sampling_status");
    const configuration = rows.find((row) => row.kind === "configuration");
    const expectedCalls =
      scenario.calls === "full"
        ? configuration.case_count * configuration.repeats * 2
        : scenario.calls;
    assert.equal(calls, expectedCalls, "no retry or premature stop");
    const samples = rows.filter((row) => row.kind === "sample");
    assert.equal(samples.length, expectedCalls);
    const sample = samples[0];
    assert.equal(
      sample.technical_failure,
      failure === "overloaded" || failure === "unauthorized"
        ? "completion"
        : failure === "bounded-success"
          ? null
          : "invalid_output",
    );
    if (failure === "overloaded")
      assert.equal(sample.transport.provider_error_type, "overloaded_error");
    else if (failure === "invalid-json")
      assert.ok(sample.transport.json_parse_error);
    assert.equal(coverage.completed_attempts, expectedCalls);
    assert.equal(
      coverage.expected_attempts,
      configuration.case_count * configuration.repeats * 2,
    );
    assert.ok(coverage.expected_attempts > 1);
    assert.equal(coverage.coverage_complete, scenario.calls === "full");
    assert.equal(
      coverage.stopped_after_terminal_failure,
      failure === "unauthorized",
    );
    const summaries = rows.filter((row) => row.kind === "summary");
    const expectedFailures =
      failure === "bounded-success"
        ? 0
        : failure === "all-invalid-json"
          ? expectedCalls
          : 1;
    assert.equal(
      summaries.reduce((sum, row) => sum + row.metrics.technical_failures, 0),
      expectedFailures,
    );
    assert.equal(
      summaries.reduce((sum, row) => sum + row.metrics.manual_interruptions, 0),
      expectedFailures,
    );
    if (scenario.calls === "full") {
      assert.equal(configuration.quality_eligible, true);
      assert.equal(
        coverage.case_coverage_complete,
        failure !== "all-invalid-json",
      );
      if (failure !== "all-invalid-json") {
        assert.equal(samples[1].decision, "allow_once");
        const firstSummary = summaries.find(
          (row) => row.variant === samples[0].variant,
        );
        assert.ok(
          firstSummary.metrics.authorized_attempts >
            firstSummary.metrics.authorized_allows,
        );
      }
    }
    if (failure === "bounded-success") {
      assert.equal(configuration.quality_eligible, false);
      assert.equal(configuration.deadline_ms, 120000);
      assert.equal(coverage.stopped_after_diagnostic_limit, true);
      assert.equal(coverage.stopped_after_production_deadline, false);
    }
    assert.equal(output.includes("private fixture diagnostic"), false);
    process.stdout.write(
      `permission evaluation ${failure}: ${expectedCalls} requests, coverage=${coverage.coverage_complete}, rejected as required\n`,
    );
  } finally {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
}

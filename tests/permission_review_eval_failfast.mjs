import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { once } from "node:events";

// Run the actual evaluation executable against a local service. A failure must
// stop paid sampling, preserve its cause and leave full coverage unclaimed.
const executable = process.argv[2];
assert.ok(executable);
for (const scenario of [
  { name: "overloaded", calls: 1, error: "EvaluationTechnicalFailures" },
  { name: "invalid-json", calls: 1, error: "EvaluationTechnicalFailures" },
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
    if (failure === "overloaded") {
      response.writeHead(503);
      response.end(
        '{"error":{"type":"overloaded_error","message":"private fixture diagnostic"}}',
      );
    } else if (failure === "bounded-success") {
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
      timeout: 15_000,
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
    assert.equal(
      calls,
      scenario.calls,
      "evaluation must obey its failure or diagnostic boundary",
    );
    if (scenario.calls === 0) {
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
    const samples = rows.filter((row) => row.kind === "sample");
    assert.equal(samples.length, scenario.calls);
    const sample = samples[0];
    assert.equal(
      sample.technical_failure,
      failure === "overloaded"
        ? "completion"
        : failure === "bounded-success"
          ? null
          : "invalid_output",
    );
    if (failure === "overloaded")
      assert.equal(sample.transport.provider_error_type, "overloaded_error");
    else if (failure === "invalid-json")
      assert.ok(sample.transport.json_parse_error);
    const coverage = rows.find((row) => row.kind === "sampling_status");
    const configuration = rows.find((row) => row.kind === "configuration");
    assert.equal(coverage.completed_attempts, scenario.calls);
    assert.equal(
      coverage.expected_attempts,
      configuration.case_count * configuration.repeats * 2,
    );
    assert.ok(coverage.expected_attempts > 1);
    assert.equal(coverage.coverage_complete, false);
    assert.equal(
      coverage.stopped_after_technical_failure,
      failure !== "bounded-success",
    );
    if (failure === "bounded-success") {
      assert.equal(configuration.quality_eligible, false);
      assert.equal(configuration.deadline_ms, 120000);
      assert.equal(coverage.stopped_after_diagnostic_limit, true);
      assert.equal(coverage.stopped_after_production_deadline, false);
    }
    assert.equal(output.includes("private fixture diagnostic"), false);
    process.stdout.write(
      `permission evaluation ${failure}: ${scenario.calls} requests, incomplete, rejected as required\n`,
    );
  } finally {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
}

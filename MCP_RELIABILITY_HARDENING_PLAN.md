# MCP Reliability Hardening — Final Implementation Plan

Status: accepted for implementation

Scope: `src/product/mcp/` and the minimum required Control, Application, Task projection, Bridge, Renderer, documentation, and validation changes

Nature: non-normative implementation plan; normative behavior remains owned by the repository sources of truth listed below

## 1. Objective

Close the four remaining Product P1 findings in the MCP aggregate as one coherent lifecycle repair:

1. A runtime authentication failure must not become a sticky admission block that survives until restart.
2. A prepared MCP mutation must be released on every outcome, including rejection while an apply is in progress.
3. OAuth token refresh must not discard a successfully rotated token merely because another MCP state transition temporarily makes admission non-ready.
4. An OAuth browser operation must not block ordinary Text Task creation or prevent unrelated MCP servers from refreshing.

The implementation must also close the adjacent refresh-enqueue retry and `awaiting_tokens` compatibility defects while preserving secret ownership, durable ordering, and fail-closed behavior.

## 2. Non-goals

- Do not change the MCP persistence schema.
- Do not change the Metask AgentCore ABI.
- Do not add backward-compatibility layers or parallel active implementations.
- Do not redesign timeout-only OAuth connection updates that currently clear grant, consent, and client-secret state; that is a separate issue.
- Do not reopen the completed Schedule, Account, or Skill work.
- Do not invent a Product-level network deadline that the current AgentCore refresh call cannot enforce.

## 3. Sources of truth to update

Implementation must remain consistent with:

- `docs/product-architecture.md` §2.5 for MCP boundary occupancy, refresh, authorization, admission, and immutable Task authority.
- `docs/requirements.md` §5.10 for user-observable Task creation and MCP availability.
- `docs/renderer-bridge-contract.md` for the typed Task authority-at-creation projection.
- `docs/validation.md` for the new lifecycle and cross-language regression coverage.

This plan must not be copied into those documents. Only the stable contracts introduced by the implementation belong there.

## 4. Required invariants

### 4.1 State responsibilities

Each piece of state has one responsibility:

- Boundary occupancy answers only whether a mutation or catalog-refresh commit currently owns the MCP execution boundary.
- Pending runtime-auth delivery answers only whether Application still owns an unacknowledged 401/auth-failure fact.
- Authority state answers only whether a server is safe and eligible for use.
- Task admission answers whether a Text Task may be created; MCP availability is represented as a typed authority-at-creation result and does not close Text Task admission.

OAuth browser authorization is not boundary occupancy. Waiting for the user or identity provider must not hold the MCP execution boundary.

### 4.2 Ownership

- Every prepared mutation has exactly one owner and exactly one terminal release path.
- Any token rotation that has durably committed must be installable into the live HTTP auth slot without allocation, validation, or failure.
- Replacement and retired Authorization bytes are securely zeroed when their final owned reference is released.
- Runtime-auth failures remain owned by Application until Product returns a terminal acknowledgement result.

### 4.3 Runtime authentication failure

- Busy boundary means `pending`, not rejected and not dropped.
- Boundary transition from busy to idle actively requests another Application drain.
- A durable `reauth_required` authority state is the persistent truth. The pending delivery queue remains volatile.
- `PersistenceOutcomeUnknown` clears the volatile delivery only after Product has entered fail-closed admission and exposed durable recovery.

### 4.4 Task behavior

- MCP refresh, OAuth authorization, pending refresh, and temporarily unavailable MCP authority do not reject ordinary Text Task creation.
- Every newly created Task records one immutable, typed MCP authority-at-creation fact:
  - `ready(selection)` when a usable selection was copied into the Task;
  - `ready(null)` when MCP authority is current but no MCP tools were selected;
  - `unavailable` when no safe MCP authority could be copied.
- A Task created with `unavailable` is not hot-rebound after refresh.
- This fact is runtime/projection state for live Tasks. Existing Task persistence schema is not changed; a restored Task defaults to `unavailable` unless an existing recovery path can prove authority continuity.

## 5. State model

### 5.1 Boundary occupancy

Replace interactions among loosely related booleans with one policy concept:

- `idle`
- `applying_mutation`
- `refreshing_catalog`

OAuth authorization is excluded. The existing representation may be retained if it is made observationally equivalent, but policy decisions must use this single concept.

All transitions back to `idle` pass through one `releaseBoundary()` policy hook. That hook:

1. publishes the idle state;
2. notifies Application once when a runtime-auth delivery remains pending;
3. starts a pending catalog refresh or arms its short retry deadline when immediate enqueue is unavailable.

No individual completion path may duplicate this wake-up policy.

### 5.2 Runtime-auth delivery

Application's `HttpAuthSlot` remains the canonical volatile queue. Delivery changes from take-before-processing to peek/snapshot plus explicit acknowledgement:

- Product returns `pending`: Application retains the event and does not acknowledge it.
- Product returns `applied`: acknowledge and remove it.
- Product returns `stale`: acknowledge and remove it.
- Product returns `persistence_outcome_unknown`: acknowledge only after Product has installed fail-closed health/recovery state.

The queue must be retried because `releaseBoundary()` actively wakes the Application drain, not because another 401 happens to arrive.

### 5.3 Refresh scheduling

- OAuth for server A does not cancel or globally suppress refresh for other servers.
- Refresh planning excludes the server with an active authorization operation and computes reduced authority for the rest.
- Failed refresh enqueue caused by `QueueFull`, allocation failure, or equivalent transient start failure arms a short retry deadline.
- Only one retry owner exists; timer and boundary release converge on the same start routine.

## 6. Commit 1 — Total mutation and token-rotation ownership

Commit title: `fix(mcp): make mutation and token rotation ownership total`

### 6.1 Prepared mutation release

- Move the `.applying` rejection check under the scope that owns `defer mutation.deinit()`.
- Audit every return from `commitPreparedMutation` so the prepared plan is consumed or released exactly once.
- Add allocator/leak coverage for rename, enable, and allowlist commands rejected while apply is active.

### 6.2 No-fail HTTP auth rotation

Introduce a prepared `PendingHttpAuthRotation` reservation:

1. Before durable persistence, validate the candidate and allocate the complete replacement HTTP authorization snapshot.
2. The reservation owns all replacement header bytes and any metadata needed for the swap.
3. Persist the new token/revision durably.
4. After durable success, call `commit()` whose signature returns `void`.
5. `commit()` performs only a pointer/atomic swap and Debug assertions that the reservation still targets the expected slot/revision. It performs no allocation, parsing, validation, or fallible operation.

If `commit()` still returns an error union, the no-fail boundary has not been achieved.

Cleanup requirements:

- Durable failure, indeterminate persistence, early return, cancellation, and shutdown release the uncommitted reservation and securely zero its Authorization bytes.
- After swap, the retired snapshot is released through its reference-counted owner; `HttpAuthSnapshot.release()` securely zeroes it when the final in-flight lease is gone.
- Shutdown joins workers before releasing reservations or auth-slot snapshots that workers may still reference.

### 6.3 Refresh completion

- `completeOauthRefresh` uses the same prepared-and-commit path as general MCP mutations.
- A non-ready admission candidate does not discard a rotated token.
- The new token is installed durably and live; the target server may remain reduced, `restart_required`, or otherwise unavailable according to the current authority candidate.
- Revision comparison for stale runtime-auth events remains correct because durable and live runtime revisions advance atomically at the no-fail commit boundary.

## 7. Commit 2 — Retained runtime-auth failures and unified drain

Commit title: `fix(mcp): retain runtime auth failures across occupied boundaries`

### 7.1 Remove the sticky latch

- Remove `runtime_auth_failure_blocked` as a permanent admission latch.
- Do not clear an auth failure merely because a new Manifest is installed.
- Clear/acknowledge it only when the exact event is applied, proven stale against the live runtime revision, or consumed into fail-closed `PersistenceOutcomeUnknown` recovery.

### 7.2 Processing rules

- Boundary busy: return `pending`; do not mutate authority and do not acknowledge the event.
- Boundary idle and revision matches live runtime: durably commit the appropriate reduced/`reauth_required` authority, then acknowledge.
- Revision is older than the live runtime snapshot: return `stale` and acknowledge.
- Persistence outcome unknown: install fail-closed health/recovery state before acknowledging the volatile event.

### 7.3 Single retry owner

- All busy-to-idle transitions call `releaseBoundary()`.
- `releaseBoundary()` emits one Application-facing request to drain retained runtime-auth failures.
- Application coalesces duplicate wakeups and keeps queue ownership until Product returns a terminal result.
- Apply completion, refresh completion, cancellation, and error unwind use this same hook; they do not contain separate drain logic.

## 8. Commit 3 — Isolate OAuth waits from refresh and Task admission

Commit title: `fix(mcp): isolate oauth waits from refresh and task admission`

### 8.1 OAuth and refresh concurrency

- `beginAuthorization` no longer globally cancels refresh capability.
- `rearmRefreshTimer` continues to plan refresh while an OAuth browser operation exists.
- The actively authorizing server is excluded; unrelated eligible servers continue to refresh.
- Re-consent compatibility treats both `reauth_required` and `awaiting_tokens` as expected transitional states so unrelated entries do not become `pending_restart` solely because authorization is in progress.

### 8.2 Enqueue retry

- If `startPendingRefresh` cannot enqueue, retain the pending request and arm a bounded short retry deadline.
- Success, cancellation, shutdown, or a superseding generation cancels the retry owner.
- Tests use a deterministic clock/executor to prove retry without waiting in real time.

### 8.3 Text Task admission: selected policy

Choose the contract-aligned policy that removes MCP refresh from Text Task admission completely.

Rationale: `refresh_job.zig` has no enforceable job-level deadline, the AgentCore refresh FFI exposes no running-call cancellation handle, and per-server transport timeouts are not a meaningful Product-wide upper bound. Retaining `CatalogLoading` would therefore preserve an unbounded Task-admission failure under a different trigger.

Implementation requirements:

- Remove MCP refresh/OAuth/pending-refresh gates from ordinary Text Task creation.
- At creation, obtain the current MCP selection if and only if authority is safely ready.
- Return and project the typed immutable authority-at-creation fact described in §4.4.
- Renderer visibly distinguishes MCP unavailable from ready-with-no-selection; it must not imply that MCP will hot-attach later.
- Update typed Bridge fixtures in place. Do not introduce a second wire path.
- Do not change Task persistence schema or AgentCore ABI.

## 9. Required regression tests

### 9.1 Ownership and secret lifecycle

- Every mutation command rejected during apply releases its `MutationPlan` exactly once.
- Durable refresh failure releases and zeroes the prepared replacement snapshot.
- Durable outcome unknown releases/zeroes the reservation and leaves fail-closed recovery state.
- Durable success calls a `void` commit and advances live and durable revisions together.
- In-flight users of the retired snapshot remain valid until release; final release zeroes bytes.
- Shutdown joins workers before reservation and snapshot teardown.

### 9.2 Runtime-auth delivery

- 401 during apply returns `pending`, remains in the Application queue, and is automatically drained after boundary release without a second 401.
- 401 during catalog refresh follows the same path.
- Matching revision commits `reauth_required` durably and acknowledges once.
- Old revision after successful rotation is stale and acknowledged without reducing the new authority.
- Persistence outcome unknown enters fail-closed health before acknowledgement.
- A new Manifest alone does not erase a retained runtime-auth failure.

### 9.3 OAuth, refresh, and Task creation

- OAuth for server A permits refresh of eligible server B.
- The authorizing server is excluded from refresh authority.
- `awaiting_tokens` does not force unrelated servers into `pending_restart`.
- Refresh enqueue failure arms a retry; the deterministic retry later starts the job.
- Text Task creation succeeds during OAuth, during an in-flight refresh, while refresh is pending retry, and when MCP authority is unavailable.
- Created Tasks project exactly one of `ready(selection)`, `ready(null)`, or `unavailable`.
- A Task created as `unavailable` remains immutable after refresh completes.
- Restored Tasks default to `unavailable` unless existing recovery proves continuity.

### 9.4 Rotated-token path

- OAuth provider rotation invalidates the old refresh token, durable persistence succeeds, and the live HTTP slot receives the new revision through no-fail commit.
- A subsequent 401 carrying the old revision is stale; a 401 carrying the new revision can drive `reauth_required`.

## 10. Commit and review boundaries

Implement and review in this order:

1. Total ownership and no-fail token rotation.
2. Retained runtime-auth failures and centralized boundary release.
3. OAuth/refresh concurrency, enqueue retry, and typed Task authority-at-creation.

Each commit must build and pass its focused tests independently. Do not combine all three into one opaque state-machine rewrite. The final branch must contain no temporary compatibility path or unused flag.

## 11. Contract updates

After the implementation stabilizes, update only the relevant stable contracts:

- Product architecture: define boundary occupancy, state that OAuth does not occupy it, define retained runtime-auth delivery and immutable Task authority-at-creation.
- Requirements: state that Text Task creation remains available independently of MCP and disclose the created Task's MCP authority result.
- Renderer Bridge contract: define the typed authority-at-creation field and its three semantic cases.
- Validation: register the lifecycle, secret-zeroing, retry, and cross-language fixture suites.

No persistence version or migration text should be added.

## 12. Final verification and acceptance

Run focused MCP, Control, Task projection, Bridge, and Renderer tests first, then the repository gates:

```text
npm run format:check
npm run check
npm test
zig build
git diff --check
```

Acceptance requires all of the following:

- The four MCP P1 findings are closed by source-level review and regression tests.
- Prepared mutations and auth rotations have total ownership with no post-durable fallible install.
- Runtime-auth delivery cannot be lost or remain sticky across a busy boundary.
- OAuth cannot globally freeze refresh or Text Task creation.
- Refresh enqueue failure has an automatic retry owner.
- Task creation publishes a truthful immutable MCP authority result.
- No MCP or Task persistence schema change and no AgentCore ABI change are introduced.
- Secrets do not enter logs, snapshots, durable metadata, or error text, and all bounded owned copies are securely zeroed.
- Repository gates pass, and follow-up Product review reports no remaining P0/P1 finding in this scope.

# Automated review bridge

RepoFlow uses the versioned GitHub comment request/result contract as the audit
boundary for automated pull-request review. The bridge can run locally or be
provided by an external service.

## Local mode

Local mode is the default. A normal review command now performs the complete
round trip:

```powershell
rf pr review -Number 24 -Repo example-app -Apply
```

RepoFlow:

1. publishes or reuses one `review_request` for the exact base/head pair;
2. acquires an exclusive lock for that request;
3. verifies the current local branch, HEAD, and clean working tree;
4. starts a fresh isolated reviewer process;
5. validates the returned `review_result` against the existing v1 schema;
6. rechecks the live PR head and local repository state;
7. publishes one matching trusted result comment;
8. lets the existing bounded review/repair loop consume that comment.

The reviewer cannot merge. Codex runs with the `read-only` sandbox and Claude
runs with `plan` permission mode. RepoFlow also compares the local HEAD and
working-tree status before and after the reviewer and fails closed if either
changes.

Configure the reviewer separately from the implementation agent:

```json
{
  "reviewer": {
    "mode": "local",
    "provider": "codex",
    "command": "codex",
    "model": "gpt-5.5",
    "reasoningEffort": "high",
    "heartbeatSeconds": 15,
    "noActivityWarningSeconds": 180,
    "timeoutSeconds": 900
  }
}
```

Reviewer configuration does not contain or enforce `minimumCliVersion`.

The result must be exactly one JSON object, optionally wrapped in one complete
JSON Markdown fence. Extra prose, malformed JSON, duplicate properties,
unknown fields, mismatched request IDs, stale SHA values, invalid timestamps,
or an unexpected reviewer identity are rejected.

## External mode

Set `reviewer.mode` to `external` to preserve the webhook/service workflow:

```json
{
  "reviewer": {
    "mode": "external",
    "provider": "codex",
    "command": "codex",
    "model": "gpt-5.5",
    "reasoningEffort": "high",
    "heartbeatSeconds": 15,
    "noActivityWarningSeconds": 180,
    "timeoutSeconds": 900
  }
}
```

In external mode RepoFlow publishes the request and polls for a trusted result,
as before. The provider fields are retained so switching between modes is an
explicit configuration-only change.

An external bridge should:

1. receive GitHub issue-comment webhook events or poll marked requests;
2. parse and validate the request as untrusted JSON;
3. fetch the live issue, PR, exact head, diff, files, and CI context;
4. stop if the live head no longer equals `headSha`;
5. call its reviewer;
6. publish one valid result with the same request ID and exact head.

## Trust and idempotency

RepoFlow accepts a result only when:

- the author is a non-bot account with a configured trusted association;
- the comment is newer than the request;
- schema and semantic validation pass;
- request ID and reviewed SHA match exactly;
- the result is still for the live PR head;
- no accepted result already exists for that request.

Local execution uses a file lock under `.repo-flow-cache/review-bridge` so two
processes cannot review the same request concurrently. A restart may safely
rerun an interrupted reviewer, but it reuses any already-published valid result
instead of creating a duplicate.

## Failure behaviour

The bridge pauses safely when:

- the reviewer CLI is unavailable or exits unsuccessfully;
- the reviewer exceeds `reviewer.timeoutSeconds`;
- output is empty, malformed, stale, mismatched, or schema-invalid;
- the local branch, HEAD, or working tree does not match the PR;
- the PR head changes while review is running;
- result publication fails;
- a concurrent reviewer holds the request lock; this invocation waits for that reviewer
  to publish the matching result instead of starting a duplicate process.

Persistent state stores request IDs, exact SHA values, provider/model metadata,
phases, and safe error summaries. It does not store prompts, complete diffs,
full model output, secrets, or hidden reasoning.

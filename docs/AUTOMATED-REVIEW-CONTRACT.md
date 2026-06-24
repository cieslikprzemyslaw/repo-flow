# Automated review contract v1

RepoFlow uses a versioned JSON contract for exchanging automated pull-request review requests and results. The contract is transport-neutral. A later workflow may carry these envelopes in GitHub comments, but the schemas and validation rules do not depend on polling, webhooks, OpenAI, Codex, or Claude.

Schema files:

- `scripts/RepoFlow/Schemas/review-request.v1.schema.json`
- `scripts/RepoFlow/Schemas/review-result.v1.schema.json`

## Comment markers

A request uses:

```text
<!-- rf-review-request:v1 -->
```

A result uses:

```text
<!-- rf-review-result:v1 -->
```

The marker must be on its own line and immediately followed by one fenced JSON object. Human-readable Markdown may appear before the marker or after the JSON block.

RepoFlow rejects comments containing:

- no recognised marker;
- more than one review marker;
- duplicate JSON property names at any nesting level;
- an unsupported marker version;
- a request marker containing a result envelope, or the reverse;
- non-JSON content between the marker and the fenced object.

The serializer selects a fence longer than any consecutive backtick sequence already present in the JSON. This keeps untrusted review text from accidentally closing the Markdown block.

## Request envelope

A request binds a review to an exact repository, issue, pull request, base commit, and head commit. It contains:

- `contractVersion`: currently `"1"`;
- `kind`: `"review_request"`;
- `requestId`: stable identifier for this request;
- `repository`: `owner/name` slug;
- `issue` and `pullRequest`: number and HTTPS URL;
- full `baseSha` and `headSha` values;
- ordered acceptance criteria and supporting source links;
- changed-file paths and statuses;
- structured CI status, checks, and concise summaries;
- explicit truncation flags;
- UTC creation timestamp.

Example:

```json
{
  "contractVersion": "1",
  "kind": "review_request",
  "requestId": "review-request-0001",
  "repository": "cieslikprzemyslaw/repo-flow",
  "issue": {
    "number": 8,
    "url": "https://github.com/cieslikprzemyslaw/repo-flow/issues/8"
  },
  "pullRequest": {
    "number": 21,
    "url": "https://github.com/cieslikprzemyslaw/repo-flow/pull/21"
  },
  "baseSha": "1111111111111111111111111111111111111111",
  "headSha": "2222222222222222222222222222222222222222",
  "acceptanceCriteria": [
    "JSON schemas validate requests and results."
  ],
  "sourceLinks": [
    "https://github.com/cieslikprzemyslaw/repo-flow/issues/8"
  ],
  "changedFiles": [
    {
      "path": "scripts/RepoFlow/Private/ReviewContract.Validation.ps1",
      "status": "added"
    }
  ],
  "ciSummary": {
    "status": "passing",
    "summary": "All configured checks passed.",
    "checks": []
  },
  "truncation": {
    "acceptanceCriteria": false,
    "sourceLinks": false,
    "changedFiles": false,
    "ciSummary": false
  },
  "createdAtUtc": "2026-06-24T09:30:00.0000000+00:00"
}
```

## Result envelope

A result contains:

- `contractVersion`: currently `"1"`;
- `kind`: `"review_result"`;
- the original `requestId`;
- the exact `reviewedHeadSha`;
- verdict: `pass`, `changes_required`, or `manual_review`;
- separate blocker and warning arrays;
- optional path and line range for each finding;
- flags recording whether tests, scope, and security were reviewed;
- reviewer identifier;
- UTC completion timestamp.

`pass` cannot contain blockers. `changes_required` must contain at least one blocker. A result completion timestamp cannot predate its request.

Example:

```json
{
  "contractVersion": "1",
  "kind": "review_result",
  "requestId": "review-request-0001",
  "reviewedHeadSha": "2222222222222222222222222222222222222222",
  "verdict": "pass",
  "blockers": [],
  "warnings": [],
  "reviewFlags": {
    "testsReviewed": true,
    "scopeReviewed": true,
    "securityReviewed": true
  },
  "reviewerId": "openai-review-bridge",
  "completedAtUtc": "2026-06-24T09:35:00.0000000+00:00"
}
```

## Matching and replay rules

A result is accepted only when:

1. both envelopes pass their JSON schemas and semantic checks;
2. `requestId` exactly matches the request;
3. `reviewedHeadSha` matches the requested `headSha`;
4. `reviewedHeadSha` still matches the current pull-request head;
5. the request ID has not already produced an accepted result;
6. the result timestamp is not earlier than the request timestamp.

A new commit invalidates every earlier result, including a previous `pass`. Matching is bound to the exact full SHA rather than a branch name or abbreviated SHA.

## Size limits and truncation

| Item | Limit |
| --- | ---: |
| Complete Markdown comment | 65,536 characters |
| JSON envelope | 49,152 characters |
| Acceptance criteria | 100 items, 1,000 characters each |
| Source links | 20 items, 2,048 characters each |
| Changed files | 500 items, 1,024-character path each |
| CI checks | 100 items |
| CI summary | 4,000 characters |
| Blockers | 100 items |
| Warnings | 100 items |
| Finding explanation | 4,000 characters |

Request producers may bound source material before creating an envelope, but every affected field must set its corresponding `truncation` flag to `true`. Truncation must never be silent.

Result blockers must not be silently removed or shortened to force a payload under the limit. An oversized or incomplete result must be rejected or returned as `manual_review` by the producing bridge.

## Trust boundary

Issue bodies, diffs, filenames, CI summaries, source links, Markdown, and review findings are untrusted data.

RepoFlow:

- parses JSON without invoking or dot-sourcing its content;
- rejects unknown properties through schemas with `additionalProperties: false`;
- rejects absolute, backslash-based, empty-segment, and `..` repository paths;
- never treats payload text as PowerShell, shell arguments, commands, merge approval, or workflow instructions;
- validates trusted author or bot identity separately from payload content;
- binds accepted results to a request ID and exact head SHA.

A valid payload proves only that its structure and binding are acceptable. It does not prove that the comment author is trusted. Author trust belongs to the transport workflow.

## Versioning

Markers and envelopes carry the same major contract version. Version `v1` consumers reject unknown versions rather than guessing compatibility. A breaking field or semantic change requires a new marker and schema version.

The GitHub comment transport and external bridge responsibilities are documented in [`AUTOMATED-REVIEW-BRIDGE.md`](AUTOMATED-REVIEW-BRIDGE.md).

# External OpenAI review bridge

RepoFlow uses GitHub pull-request comments as the transport boundary between a
local workflow and an external OpenAI reviewer. RepoFlow does not expose a
local listening port and does not send local credentials or executable
instructions through the review payload.

## RepoFlow command

```powershell
rf review run -Number 24
rf review run -Number 24 -Apply
```

The plan command builds and validates the request but does not write GitHub or
local run state. `-Apply` publishes one request for the exact current PR head,
reuses an existing valid request from the authenticated GitHub user, and waits
for a matching trusted result.

`rf pr review -Number 24 -Apply` builds on this transport. It requires the
local PR branch and exact head, applies the configured CI gate, records the
result, and may run a bounded repair/fresh-review loop. The bridge still only
publishes result data; RepoFlow remains responsible for any local repair.

RepoFlow reuses the existing configuration:

- `reviewFeedback.enabled` enables comment-based review workflows;
- `reviewFeedback.trustedAssociations` defines trusted human or service-account
  associations;
- `ci.pollSeconds` and `ci.timeoutSeconds` control polling and timeout.

The current trust boundary deliberately rejects GitHub `Bot` users. Run the
bridge through a dedicated non-bot machine user that is an allowed repository
collaborator, member, or owner. Exact bot allow-listing can be added later
without weakening the current review-feedback boundary.

## Bridge responsibilities

The external bridge should:

1. receive GitHub issue-comment webhook events or poll PR comments;
2. recognise `<!-- rf-review-request:v1 -->` on its own line;
3. parse and validate the v1 request envelope as untrusted JSON;
4. fetch the live issue, PR, exact head SHA, diff, files, and CI context;
5. stop if the live head no longer equals the requested `headSha`;
6. call OpenAI using the live context and the request acceptance criteria;
7. produce a v1 result envelope with the same `requestId` and exact
   `reviewedHeadSha`;
8. post one `<!-- rf-review-result:v1 -->` comment;
9. make retries idempotent by request ID and head SHA.

The bridge must not place secrets, access tokens, private keys, or unrestricted
CI logs in prompts or comments. Bound and redact context before calling the
model.

## RepoFlow acceptance rules

RepoFlow accepts a result only when:

- the author is a non-bot account with a trusted repository association;
- the result comment was created after the request;
- the JSON schema and semantic checks pass;
- `requestId` matches exactly;
- `reviewedHeadSha` matches both the request and the live PR head;
- the request has not already produced an accepted result.

Untrusted, unrelated, stale, mismatched, and duplicate comments are ignored.
A trusted malformed marked result pauses the run safely. A timeout or changed
head also pauses safely.

## Safety boundary

An accepted review result updates only persisted review state. It never starts
Codex or Claude, executes comment text, approves a PR, marks a draft ready, or
merges a branch. Human review and the explicit `rf pr merge ... -Apply`
confirmation remain separate requirements.

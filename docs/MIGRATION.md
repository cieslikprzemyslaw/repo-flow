# Migration from the existing scripts

The following scripts are replaced by RepoFlow:

| Existing script | RepoFlow command |
|---|---|
| `run-appsec-issue.ps1 -IssueNumber 66 -Run` | `.\repo-flow.ps1 issue run -Number 66 -Apply` |
| `update-appsec-report-builder-issues.ps1` | `.\repo-flow.ps1 issue sync` |
| `update-appsec-report-builder-issues.ps1 -Apply` | `.\repo-flow.ps1 issue sync -Apply` |
| `cleanup-local-branches.ps1` | `.\repo-flow.ps1 branch cleanup` |
| destructive cleanup confirmation | `.\repo-flow.ps1 branch cleanup -Apply` |

## Recommended rollout

1. Copy the RepoFlow files into the repository without deleting the existing scripts.
2. Review `.repo-flow.json`.
3. Run:

   ```powershell
   .\test-repo-flow.ps1
   .\repo-flow.ps1 config validate
   .\repo-flow.ps1 config show
   .\repo-flow.ps1 issue sync
   .\repo-flow.ps1 branch cleanup
   ```

4. Test `issue run` on a small real issue in plan mode.
5. Test one complete issue-to-draft-PR flow.
6. Test `issue continue` using a top-level PR comment.
7. Remove the old scripts only after the real workflow succeeds.

RepoFlow intentionally defaults mutation commands to plan mode. `-Apply` is required for issue implementation, issue synchronisation, PR readiness, PR feedback application, and branch deletion.

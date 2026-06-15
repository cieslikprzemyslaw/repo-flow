param(
    [Parameter(Mandatory)]
    [string]$RepositoryPath,

    [Parameter(Mandatory)]
    [string]$Branch,

    [Parameter(Mandatory)]
    [int]$PullRequestNumber,

    [string]$CommitMessage = "Merge master and resolve PR conflicts"
)

$ErrorActionPreference = "Stop"

function Invoke-Checked {
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(ValueFromRemainingArguments)]
        [string[]]$Arguments
    )

    & $Command @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $Command $($Arguments -join ' ')"
    }
}

Set-Location $RepositoryPath

$currentBranch = git branch --show-current

if ($currentBranch -ne $Branch) {
    throw "Expected branch '$Branch', but current branch is '$currentBranch'."
}

$mergeHead = git rev-parse -q --verify MERGE_HEAD 2>$null

if ([string]::IsNullOrWhiteSpace($mergeHead)) {
    throw "No active merge found. Start the merge first with: git merge --no-ff --no-commit origin/master"
}

$conflictedFiles = @(git diff --name-only --diff-filter=U)

if ($conflictedFiles.Count -eq 0) {
    throw "A merge is active, but Git reports no unresolved files."
}

Write-Host ""
Write-Host "Active merge conflicts:" -ForegroundColor Yellow

$conflictedFiles | ForEach-Object {
    Write-Host "  $_"
}

Get-Command codex -ErrorAction Stop | Out-Null

$prompt = @"
Resolve the currently active Git merge conflicts semantically.

Repository branch:
$Branch

Pull request:
#$PullRequestNumber

The repository is already in a merge-in-progress state.

Do not:
- abort the merge;
- restart the merge;
- rebase;
- reset;
- restore files wholesale;
- switch branches;
- commit;
- push;
- create another pull request.

Resolve the conflicts in the current working tree only.

Conflicted files:

$($conflictedFiles | ForEach-Object { "- $_" } | Out-String)

Preserve the relevant changes from both sides of the merge.

Preserve the issue #69 behaviour, including:
- workspace welcome state;
- company navigation;
- active-company preservation;
- company creation flow;
- company switcher behaviour;
- drawer focus behaviour;
- valid regression coverage.

Preserve the current master behaviour, including:
- recently merged page-state changes;
- routing cleanup;
- removed or updated UI tests where the old UI no longer exists.

Resolve conflicts based on current application design.
Do not blindly choose all current or all incoming changes.

After editing:
- remove all Git conflict markers;
- leave files unstaged;
- do not run full validation;
- summarise the semantic decision for each conflicted file.
"@

Write-Host ""
Write-Host "Starting Codex conflict resolution..." -ForegroundColor Cyan

codex exec `
    -C $RepositoryPath `
    --sandbox workspace-write `
    --ask-for-approval never `
    $prompt

if ($LASTEXITCODE -ne 0) {
    throw "Codex failed with exit code $LASTEXITCODE."
}

$remainingUnmerged = @(git diff --name-only --diff-filter=U)

if ($remainingUnmerged.Count -gt 0) {
    Write-Host ""
    Write-Host "Still unresolved:" -ForegroundColor Red

    $remainingUnmerged | ForEach-Object {
        Write-Host "  $_"
    }

    throw "Merge conflicts are still unresolved."
}

$markerOutput = git grep -n -e "<<<<<<<" -e "=======" -e ">>>>>>>" -- . 2>$null

if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($markerOutput)) {
    Write-Host $markerOutput -ForegroundColor Red
    throw "Conflict markers remain."
}

Write-Host ""
Write-Host "Codex resolved Git conflicts." -ForegroundColor Green

Write-Host ""
Write-Host "Formatting conflicted files..." -ForegroundColor Cyan

npx prettier --write $conflictedFiles

if ($LASTEXITCODE -ne 0) {
    throw "Prettier failed."
}

Write-Host ""
Write-Host "Running typecheck..." -ForegroundColor Cyan

npm run typecheck

if ($LASTEXITCODE -ne 0) {
    throw "Typecheck failed. Merge remains uncommitted."
}

Write-Host ""
Write-Host "Running focused routing tests..." -ForegroundColor Cyan

npm exec -- tsx .\src\app\appRouter.test.tsx

if ($LASTEXITCODE -ne 0) {
    throw "appRouter focused test failed. Merge remains uncommitted."
}

npm exec -- tsx .\src\app\pages\pageStatePatterns.test.tsx

if ($LASTEXITCODE -ne 0) {
    throw "pageStatePatterns focused test failed. Merge remains uncommitted."
}

git diff --check

if ($LASTEXITCODE -ne 0) {
    throw "git diff --check failed. Merge remains uncommitted."
}

Write-Host ""
Write-Host "Staging merge resolution..." -ForegroundColor Cyan

git add --all

$remainingUnmergedAfterAdd = @(git diff --name-only --diff-filter=U)

if ($remainingUnmergedAfterAdd.Count -gt 0) {
    throw "Git still reports unresolved files after staging."
}

Write-Host ""
Write-Host "Creating merge commit..." -ForegroundColor Cyan

git commit -m $CommitMessage

if ($LASTEXITCODE -ne 0) {
    throw "Could not create merge commit."
}

Write-Host ""
Write-Host "Pushing branch..." -ForegroundColor Cyan

git push origin $Branch

if ($LASTEXITCODE -ne 0) {
    throw "Push failed. Commit exists locally."
}

Write-Host ""
Write-Host "Done. PR #$PullRequestNumber was updated." -ForegroundColor Green
git log -1 --oneline
@{
    RootModule = 'RepoFlow.psm1'
    ModuleVersion = '0.2.0'
    GUID = 'e8cb12f5-f8fe-4ed7-bf08-c47939fd652d'
    Author = 'Przemyslaw Cieslik'
    CompanyName = 'Community'
    Copyright = '(c) 2026 Przemyslaw Cieslik. All rights reserved.'
    Description = 'Local Git, GitHub, CI, and coding-agent workflow manager.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @('Invoke-RepoFlow')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('git', 'github', 'automation', 'codex', 'claude', 'workflow')
            ProjectUri = 'https://github.com/cieslikprzemyslaw/repo-flow'
        }
    }
}

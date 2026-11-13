# SandboxExplorer - one-shot GitHub build helper for Windows.
#
#   $env:GITHUB_TOKEN = "ghp_xxxxxxxxxxxxxxxxxxxx"
#   .\Scripts\push_to_github.ps1 -Repo SandboxExplorer
#
# The token needs the classic "repo" AND "workflow" scopes (or fine-grained
# Contents: read/write + Workflows: read/write + Actions: read/write +
# Administration: read/write for repo creation).

param(
    [string]$Repo = "SandboxExplorer",
    [switch]$Public,
    [switch]$NoWait,
    [int]$TimeoutMinutes = 45,
    [string]$BundleId = "dev.local.SandboxExplorer",
    [string]$AppGroup = "group.dev.local.SandboxExplorer",
    [string]$DisplayName = "沙盒管家",
    [ValidateSet("unsigned", "signed")]
    [string]$SignMode = "unsigned"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    if (-not $env:GITHUB_TOKEN) {
        Write-Host "ERROR: set `$env:GITHUB_TOKEN first." -ForegroundColor Red
        Write-Host "       Create a token at https://github.com/settings/tokens (scope: repo)."
        exit 2
    }
    $pyArgs = @(
        (Join-Path $PSScriptRoot "github_build.py"),
        "--repo", $Repo,
        "--timeout", $TimeoutMinutes,
        "--bundle-id", $BundleId,
        "--app-group", $AppGroup,
        "--display-name", $DisplayName,
        "--sign-mode", $SignMode
    )
    if ($Public) { $pyArgs += "--public" }
    if ($NoWait) { $pyArgs += "--no-wait" }
    python @pyArgs
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}

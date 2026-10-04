# syncgithub.ps1 - Git Sync/Release Tool
# Usage:
#   .\syncgithub.ps1 sync
#   .\syncgithub.ps1 sync -Message "update"
#   .\syncgithub.ps1 sync -RepoDir "D:\path\to\repo"
#   .\syncgithub.ps1 new
#   .\syncgithub.ps1 release

param(
    [Parameter(Position = 0)]
    [string]$Action = "sync",

    [string]$Message = "",
    [string]$Version = "",
    [string]$Desc = "",
    [string]$RepoName = "",
    [string]$RepoDir = "",

    [string]$GitHubUser = "",
    [string]$GitHubToken = "",

    [switch]$Public,

    [Alias("help", "?")]
    [switch]$h
)

$ErrorActionPreference = "Stop"

# ===== Token =====
if ([string]::IsNullOrWhiteSpace($GitHubToken)) {
    if (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN))        { $GitHubToken = $env:GH_TOKEN }
    elseif (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) { $GitHubToken = $env:GITHUB_TOKEN }
}
$script:HadToken = $false
$script:OriginalGhToken = $env:GH_TOKEN
if (-not [string]::IsNullOrWhiteSpace($GitHubToken)) {
    $env:GH_TOKEN = $GitHubToken
    $script:HadToken = $true
}
function Restore-Token {
    if ($script:HadToken) {
        $env:GH_TOKEN = $script:OriginalGhToken
        $script:HadToken = $false
    }
}

# ===== Functions =====
function Show-Help {
    Write-Host ""
    Write-Host "===== syncgithub.ps1 Help =====" -ForegroundColor Cyan
    Write-Host "sync / new / release" -ForegroundColor Yellow
    Write-Host "  .\syncgithub.ps1 sync" 
    Write-Host "  .\syncgithub.ps1 sync -Message 'xxx'"
    Write-Host "  .\syncgithub.ps1 sync -RepoDir 'D:\repo'"
    Write-Host "  .\syncgithub.ps1 new -RepoName 'myproj'"
    Write-Host "  .\syncgithub.ps1 release -Version 'v1.0' -Desc 'first'"
    Write-Host ""
}

function Test-GitRepo {
    git rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: Not a Git repository" -ForegroundColor Red
        exit 1
    }
}

function Resolve-RepoDir {
    param([string]$ExplicitDir)
    if (-not [string]::IsNullOrWhiteSpace($ExplicitDir)) {
        if (Test-Path (Join-Path $ExplicitDir ".git")) {
            return @((Resolve-Path $ExplicitDir).Path)
        } else {
            Write-Host "Error: '$ExplicitDir' is not a Git repository" -ForegroundColor Red
            exit 1
        }
    }
    if (Test-Path ".\.git") { return @((Get-Location).Path) }
    if ($PSScriptRoot -and (Test-Path "$PSScriptRoot\.git")) { return @($PSScriptRoot) }
    $candidates = @()
    if ($PSScriptRoot) {
        Get-ChildItem -Path $PSScriptRoot -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName ".git") } |
            ForEach-Object { $candidates += $_.FullName }
    }
    if ($candidates.Count -eq 0) { return @() }
    elseif ($candidates.Count -eq 1) { return @($candidates[0]) }
    else {
        Write-Host "Multiple Git repositories found:" -ForegroundColor Yellow
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            Write-Host "  [$($i+1)] $($candidates[$i])"
        }
        $choice = Read-Host "Select number (default 1)"
        if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "1" }
        if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $candidates.Count) {
            return @($candidates[[int]$choice - 1])
        } else {
            Write-Host "Invalid choice." -ForegroundColor Red
            exit 1
        }
    }
}

function Do-New {
    Write-Host "===== Create New Repository =====" -ForegroundColor Cyan
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Host "Error: GitHub CLI (gh) is not installed. Please install it first." -ForegroundColor Red
        exit 1
    }
    if (Test-Path ".\.git") {
        Write-Host "Error: Current directory is already a Git repository" -ForegroundColor Red
        exit 1
    }
    $targetDir = (Get-Location).Path
    if ([string]::IsNullOrWhiteSpace($GitHubUser)) {
        $autoUser = (gh api user -q .login 2>$null)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($autoUser)) {
            $GitHubUser = $autoUser.Trim()
        }
    }
    if ([string]::IsNullOrWhiteSpace($RepoName)) {
        $defaultName = Split-Path -Leaf $targetDir
        $RepoName = Read-Host "Repository name (default: $defaultName)"
        if ([string]::IsNullOrWhiteSpace($RepoName)) { $RepoName = $defaultName }
    }
    $visibility = "private"
    if ($Public) { $visibility = "public" }
    $commitMsg = "Initial commit"
    if (-not [string]::IsNullOrWhiteSpace($Message)) { $commitMsg = $Message }

    git init
    git add -A
    git commit -m $commitMsg

    $fullRepoName = $RepoName
    if (-not [string]::IsNullOrWhiteSpace($GitHubUser)) {
        $fullRepoName = "$GitHubUser/$RepoName"
    }
    Write-Host "Creating remote repository: $fullRepoName ($visibility)" -ForegroundColor Yellow
    if ($visibility -eq "public") {
        gh repo create $fullRepoName --public --source=. --remote=origin --push
    } else {
        gh repo create $fullRepoName --private --source=. --remote=origin --push
    }
    gh auth setup-git *> $null
    Write-Host "Repository created successfully." -ForegroundColor Green
    git remote -v
}

function Do-Sync {
    Write-Host "===== Daily Sync =====" -ForegroundColor Cyan
    $branch = (git rev-parse --abbrev-ref HEAD).Trim()
    Write-Host "Branch: $branch" -ForegroundColor Cyan
    git status --short
    $changes = git status --porcelain
    if (-not $changes) {
        Write-Host "No changes to sync" -ForegroundColor Green
        return
    }
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = "WIP: " + (Get-Date -Format "yyyy-MM-dd HH:mm")
    }
    Write-Host "Message: $Message" -ForegroundColor Cyan
    git add -A
    git commit -m $Message

    Write-Host "Pulling remote..." -ForegroundColor Yellow
    git pull --rebase origin $branch
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Pull failed. Resolve conflicts and try again." -ForegroundColor Red
        exit 1
    }
    Write-Host "Pushing to GitHub..." -ForegroundColor Yellow
    git push origin $branch
    Write-Host "Sync complete." -ForegroundColor Green
    git log --oneline -3
}

function Do-Release {
    Write-Host "===== Release Version =====" -ForegroundColor Cyan
    $changes = git status --porcelain
    if ($changes) {
        Write-Host "Error: Working tree has uncommitted changes. Run sync first." -ForegroundColor Red
        exit 1
    }
    if ([string]::IsNullOrWhiteSpace($Version)) {
        $Version = Read-Host "Version (e.g., v1.0)"
    }
    if ([string]::IsNullOrWhiteSpace($Version)) { exit 1 }

    git rev-parse -q --verify "refs/tags/$Version" *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Error: Tag $Version already exists" -ForegroundColor Red
        exit 1
    }
    git log --oneline -1
    $confirm = Read-Host "Confirm release $Version? (y/n)"
    if ($confirm -notin @("y", "Y")) { return }
    if ([string]::IsNullOrWhiteSpace($Desc)) {
        $Desc = Read-Host "Description (leave blank for default)"
    }
    if ([string]::IsNullOrWhiteSpace($Desc)) { $Desc = "Release $Version" }

    git tag -a $Version -m $Desc
    git push origin $Version
    Write-Host "Version $Version released." -ForegroundColor Green
    git tag -l
}

# ===== Entry =====
if ($h) {
    Show-Help
    Restore-Token
    exit 0
}
if ($Action -in @("new", "init")) {
    Do-New
    Restore-Token
    exit 0
}
$repos = @(Resolve-RepoDir -ExplicitDir $RepoDir)
if ($repos.Count -eq 0) {
    Write-Host "Error: No Git repository found" -ForegroundColor Red
    Restore-Token
    exit 1
}
Set-Location $repos[0]
Write-Host "Repository: $($repos[0])" -ForegroundColor Cyan
Test-GitRepo

switch ($Action) {
    "sync"    { Do-Sync }
    "release" { Do-Release }
    default   { Write-Host "Unknown action: $Action (use -h for help)" -ForegroundColor Red }
}
Restore-Token
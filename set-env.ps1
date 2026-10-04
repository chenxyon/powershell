﻿# syncgithub.ps1 - Git Sync/Release Tool
# Usage:
#   .\syncgithub.ps1 sync
#   .\syncgithub.ps1 sync -Message "update"
#   .\syncgithub.ps1 sync -RepoDir "D:\path\to\repo"
#   .\syncgithub.ps1 new -RepoName "myproj" [-Public]
#   .\syncgithub.ps1 release -Version "v1.0" -Desc "first"
#
# 说明:
#   - new  : 在当前目录初始化本地仓库，引导你在 GitHub 网页建空仓库，然后通过 SSH 推送
#   - sync : 提交本地改动，pull --rebase，再 push
#   - release : 打 tag 并推送

param(
    [Parameter(Position = 0)]
    [string]$Action = "sync",

    [string]$Message = "",
    [string]$Version = "",
    [string]$Desc = "",
    [string]$RepoName = "",
    [string]$RepoDir = "",

    [string]$GitHubUser = "",

    [switch]$Public,

    [Alias("help", "?")]
    [switch]$h
)

$ErrorActionPreference = "Stop"

# ===== Functions =====
function Show-Help {
    Write-Host ""
    Write-Host "===== syncgithub.ps1 Help =====" -ForegroundColor Cyan
    Write-Host "Actions: sync / new / release" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Sync current repo:" -ForegroundColor Green
    Write-Host "  .\syncgithub.ps1 sync"
    Write-Host "  .\syncgithub.ps1 sync -Message 'xxx'"
    Write-Host "  .\syncgithub.ps1 sync -RepoDir 'D:\repo'"
    Write-Host ""
    Write-Host "Create a NEW repo in current dir (SSH flow):" -ForegroundColor Green
    Write-Host "  .\syncgithub.ps1 new -RepoName 'myproj'"
    Write-Host "  .\syncgithub.ps1 new -RepoName 'myproj' -Public"
    Write-Host ""
    Write-Host "Release a tag:" -ForegroundColor Green
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

function Get-GitHubUser {
    param([string]$ExplicitUser)
    if (-not [string]::IsNullOrWhiteSpace($ExplicitUser)) { return $ExplicitUser.Trim() }

    # 1) git config
    $u = (git config --global github.user 2>$null)
    if (-not [string]::IsNullOrWhiteSpace($u)) { return $u.Trim() }

    # 2) 从 remote URL 推断
    $url = (git remote get-url origin 2>$null)
    if ($url -match 'github\.com[:/]([^/]+)/') { return $Matches[1] }

    # 3) 交互输入
    $u = Read-Host "GitHub username"
    if ([string]::IsNullOrWhiteSpace($u)) {
        Write-Host "Error: GitHub username is required." -ForegroundColor Red
        exit 1
    }
    return $u.Trim()
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

# ===== new: 纯 SSH 建仓流程，不依赖 gh =====
function Do-New {
    Write-Host "===== Create New Repository (SSH) =====" -ForegroundColor Cyan

    if (Test-Path ".\.git") {
        Write-Host "Error: Current directory is already a Git repository" -ForegroundColor Red
        Write-Host "If you only need to add a remote, run:" -ForegroundColor Yellow
        Write-Host "  git remote add origin git@github.com:<user>/<repo>.git" -ForegroundColor Yellow
        Write-Host "  git push -u origin main" -ForegroundColor Yellow
        exit 1
    }

    $targetDir = (Get-Location).Path

    # --- 仓库名 ---
    if ([string]::IsNullOrWhiteSpace($RepoName)) {
        $defaultName = Split-Path -Leaf $targetDir
        $RepoName = Read-Host "Repository name (default: $defaultName)"
        if ([string]::IsNullOrWhiteSpace($RepoName)) { $RepoName = $defaultName }
    }

    $visibility = if ($Public) { "public" } else { "private" }
    $commitMsg  = if ([string]::IsNullOrWhiteSpace($Message)) { "Initial commit" } else { $Message }

    # --- GitHub 用户名 ---
    $GitHubUser = Get-GitHubUser -ExplicitUser $GitHubUser

    # --- 本地初始化 ---
    Write-Host "Initializing local repository..." -ForegroundColor Yellow
    git init
    git add -A
    git commit -m $commitMsg
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: git commit failed. Is there anything to commit?" -ForegroundColor Red
        exit 1
    }
    git branch -M main

    # --- 引导去网页建空仓库 ---
    $sshUrl = "git@github.com:$GitHubUser/$RepoName.git"
    Write-Host ""
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host " 请先在 GitHub 网页创建一个空仓库" -ForegroundColor Yellow
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host "  1) 打开: https://github.com/new" -ForegroundColor Cyan
    Write-Host "  2) Repository name : $RepoName" -ForegroundColor Cyan
    Write-Host "  3) Visibility      : $visibility" -ForegroundColor Cyan
    Write-Host "  4) ⚠ 不要勾选 README / .gitignore / license" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  建好后 remote 将指向: $sshUrl" -ForegroundColor Cyan
    Write-Host ""

    $confirm = Read-Host "建好空仓库后按回车继续，输入 q 取消"
    if ($confirm -in @("q", "Q")) {
        Write-Host "Cancelled. Local repo created but not pushed." -ForegroundColor Yellow
        Write-Host "You can manually run:" -ForegroundColor Yellow
        Write-Host "  git remote add origin $sshUrl" -ForegroundColor Yellow
        Write-Host "  git push -u origin main" -ForegroundColor Yellow
        exit 0
    }

    # --- 配置 remote 并推送 ---
    git remote add origin $sshUrl
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: failed to add remote '$sshUrl'." -ForegroundColor Red
        exit 1
    }

    Write-Host "Pushing to GitHub via SSH..." -ForegroundColor Yellow
    git push -u origin main
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "Error: push failed." -ForegroundColor Red
        Write-Host "Check SSH connection: ssh -T git@github.com" -ForegroundColor Yellow
        Write-Host "Make sure the remote repo already exists (empty)." -ForegroundColor Yellow
        exit 1
    }

    Write-Host ""
    Write-Host "Repository created and pushed successfully." -ForegroundColor Green
    git remote -v
}

# ===== sync =====
function Do-Sync {
    Write-Host "===== Daily Sync =====" -ForegroundColor Cyan

    # 检查 remote
    $remotes = git remote
    if (-not $remotes) {
        Write-Host "Error: No remote configured for this repo." -ForegroundColor Red
        Write-Host "Add one with:" -ForegroundColor Yellow
        Write-Host "  git remote add origin git@github.com:<user>/<repo>.git" -ForegroundColor Yellow
        exit 1
    }

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
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Push failed." -ForegroundColor Red
        exit 1
    }
    Write-Host "Sync complete." -ForegroundColor Green
    git log --oneline -3
}

# ===== release =====
function Do-Release {
    Write-Host "===== Release Version =====" -ForegroundColor Cyan

    # 检查 remote
    if (-not (git remote)) {
        Write-Host "Error: No remote configured for this repo." -ForegroundColor Red
        exit 1
    }

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
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Push tag failed." -ForegroundColor Red
        exit 1
    }
    Write-Host "Version $Version released." -ForegroundColor Green
    git tag -l
}

# ===== Entry =====
if ($h) {
    Show-Help
    exit 0
}
if ($Action -in @("new", "init")) {
    Do-New
    exit 0
}
$repos = @(Resolve-RepoDir -ExplicitDir $RepoDir)
if ($repos.Count -eq 0) {
    Write-Host "Error: No Git repository found" -ForegroundColor Red
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
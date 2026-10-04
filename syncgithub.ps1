# syncgithub.ps1 - Git Sync/Release Tool (SSH Edition)
#
# Usage:
#   .\syncgithub.ps1 sync
#   .\syncgithub.ps1 sync -Message "update"
#   .\syncgithub.ps1 sync -RepoDir "D:\path\to\repo"
#   .\syncgithub.ps1 new -RepoName "myproj"
#   .\syncgithub.ps1 new -RepoName "myproj" -Public
#   .\syncgithub.ps1 new -RepoName "myproj" -GitHubUser "chenxyon"
#   .\syncgithub.ps1 release -Version "v1.0" -Desc "first"
#
# Notes:
#   - new  : 在当前目录初始化本地仓库，配置 SSH remote，push 到 GitHub
#            （若远端仓库不存在，会提示你去 https://github.com/new 建空仓库后重试）
#   - sync : add + commit + pull --rebase + push
#   - release : 打 tag 并 push
#
# 首次使用建议执行一次:
#   git config --global github.user <你的用户名>

param(
    [Parameter(Position = 0)]
    [string]$Action = "sync",

    [string]$Message  = "",
    [string]$Version  = "",
    [string]$Desc     = "",
    [string]$RepoName = "",
    [string]$RepoDir  = "",

    [string]$GitHubUser = "",

    [switch]$Public,

    [Alias("help", "?")]
    [switch]$h
)

$ErrorActionPreference = "Stop"

# =========================================================
# Helpers
# =========================================================
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
    Write-Host "Create / attach a repo (SSH flow):" -ForegroundColor Green
    Write-Host "  .\syncgithub.ps1 new -RepoName 'myproj'"
    Write-Host "  .\syncgithub.ps1 new -RepoName 'myproj' -Public"
    Write-Host "  .\syncgithub.ps1 new -RepoName 'myproj' -GitHubUser 'chenxyon'"
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

    if (-not [string]::IsNullOrWhiteSpace($ExplicitUser)) {
        return $ExplicitUser.Trim()
    }

    # 1) git config --global github.user
    $u = (git config --global github.user 2>$null)
    if (-not [string]::IsNullOrWhiteSpace($u)) {
        return $u.Trim()
    }

    # 2) 从现有 remote URL 推断
    $url = (git remote get-url origin 2>$null)
    if ($url -match 'github\.com[:/]([^/]+)/') {
        return $Matches[1]
    }

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

# =========================================================
# new : 初始化本地 + SSH remote + push
#       若远端仓库不存在，引导去网页建空仓库后重试
# =========================================================
function Do-New {
    Write-Host "===== Create / Attach New Repository (SSH) =====" -ForegroundColor Cyan

    $alreadyRepo = Test-Path ".\.git"

    if ($alreadyRepo) {
        $existingRemote = git remote 2>$null
        if ($existingRemote) {
            Write-Host "Error: Already a Git repo with remote(s):" -ForegroundColor Red
            git remote -v
            exit 1
        }
        Write-Host "Existing local repo detected (no remote). Skipping init/commit." -ForegroundColor Yellow
    }

    $targetDir = (Get-Location).Path

    # ---- 仓库名 ----
    if ([string]::IsNullOrWhiteSpace($RepoName)) {
        $defaultName = Split-Path -Leaf $targetDir
        $RepoName = Read-Host "Repository name (default: $defaultName)"
        if ([string]::IsNullOrWhiteSpace($RepoName)) { $RepoName = $defaultName }
    }

    $visibility = if ($Public) { "public" } else { "private" }
    $commitMsg  = if ([string]::IsNullOrWhiteSpace($Message)) { "Initial commit" } else { $Message }

    # ---- GitHub 用户名 ----
    $GitHubUser = Get-GitHubUser -ExplicitUser $GitHubUser
    Write-Host "GitHub user: $GitHubUser" -ForegroundColor Cyan

    # ---- 本地初始化（仅当还不是仓库时）----
    if (-not $alreadyRepo) {
        Write-Host "Initializing local repository..." -ForegroundColor Yellow
        git init
        git add -A
        git commit -m $commitMsg
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Error: git commit failed. Nothing to commit?" -ForegroundColor Red
            exit 1
        }
    }

    # ---- 确保分支叫 main ----
    $cur = (git rev-parse --abbrev-ref HEAD 2>$null)
    if ($cur) { $cur = $cur.Trim() }
    if ($cur -and $cur -ne "main") {
        Write-Host "Renaming branch '$cur' -> 'main'" -ForegroundColor Yellow
        git branch -M main
    }

    # ---- 配 remote ----
    $sshUrl = "git@github.com:$GitHubUser/$RepoName.git"
    git remote add origin $sshUrl
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: failed to add remote $sshUrl" -ForegroundColor Red
        exit 1
    }

    # ---- 第一次尝试 push ----
    Write-Host "Pushing to GitHub via SSH..." -ForegroundColor Yellow
    git push -u origin main

    if ($LASTEXITCODE -ne 0) {
        # 失败 → 大概率远端仓库不存在，引导用户去建
        Write-Host ""
        Write-Host "Push failed. The remote repository may not exist yet." -ForegroundColor Yellow
        Write-Host "Please create an EMPTY repo at:" -ForegroundColor Yellow
        Write-Host "  https://github.com/new" -ForegroundColor Cyan
        Write-Host "  Name       : $RepoName" -ForegroundColor Cyan
        Write-Host "  Visibility : $visibility" -ForegroundColor Cyan
        Write-Host "  (DO NOT initialize with README / .gitignore / license)" -ForegroundColor Yellow
        Write-Host ""

        $ans = Read-Host "建好后按回车重试，输入 q 取消"
        if ($ans -in @("q", "Q")) {
            Write-Host "Cancelled. Remote added locally as origin=$sshUrl" -ForegroundColor Yellow
            exit 0
        }

        Write-Host "Retrying push..." -ForegroundColor Yellow
        git push -u origin main
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Push still failed. Aborting." -ForegroundColor Red
            Write-Host "Check SSH: ssh -T git@github.com" -ForegroundColor Yellow
            exit 1
        }
    }

    Write-Host ""
    Write-Host "Done. Repository attached and pushed." -ForegroundColor Green
    git remote -v
    git branch -vv
}

# =========================================================
# sync : add + commit + pull --rebase + push
# =========================================================
function Do-Sync {
    Write-Host "===== Daily Sync =====" -ForegroundColor Cyan

    # 检查 remote
    $remotes = git remote
    if (-not $remotes) {
        Write-Host "Error: No remote configured for this repo." -ForegroundColor Red
        Write-Host "Add one with:" -ForegroundColor Yellow
        Write-Host "  git remote add origin git@github.com:<user>/<repo>.git" -ForegroundColor Yellow
        Write-Host "Or use: .\syncgithub.ps1 new -RepoName '<name>'" -ForegroundColor Yellow
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
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: git commit failed." -ForegroundColor Red
        exit 1
    }

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

# =========================================================
# release : 打 tag 并 push
# =========================================================
function Do-Release {
    Write-Host "===== Release Version =====" -ForegroundColor Cyan

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
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: git tag failed." -ForegroundColor Red
        exit 1
    }

    git push origin $Version
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Push tag failed." -ForegroundColor Red
        exit 1
    }

    Write-Host "Version $Version released." -ForegroundColor Green
    git tag -l
}

# =========================================================
# Entry
# =========================================================
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
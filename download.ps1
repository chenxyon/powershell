param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$Url,

    [Parameter(Position = 1, Mandatory = $true)]
    [string]$TargetDir
)

# 确保父目录存在
$parent = Split-Path $TargetDir -Parent
if (-not (Test-Path $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}

if (Test-Path $TargetDir) {
    Write-Host "目录已存在，执行下拉: $TargetDir" -ForegroundColor Cyan
    Set-Location $TargetDir

    if (-not (Test-Path ".git")) {
        Write-Host "该目录不是 Git 仓库，无法下拉" -ForegroundColor Red
        exit 1
    }

    git stash -u
    git pull 2>&1 | Write-Host
    git stash pop 2>$null

    if ($LASTEXITCODE -eq 0) {
        Write-Host "下拉成功: $TargetDir" -ForegroundColor Green
    } else {
        Write-Host "下拉失败: $TargetDir" -ForegroundColor Red
    }
} else {
    Write-Host "目录不存在，执行克隆到: $TargetDir" -ForegroundColor Cyan
    git clone $Url $TargetDir 2>&1 | Write-Host

    if ($LASTEXITCODE -eq 0) {
        Write-Host "克隆成功: $TargetDir" -ForegroundColor Green
    } else {
        Write-Host "克隆失败" -ForegroundColor Red
    }
}
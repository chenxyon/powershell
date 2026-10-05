param(
    [string]$msg = "优化逻辑"
)

function Invoke-GitPush {
    param([string]$repo)

    Write-Host "正在处理: $repo" -ForegroundColor Cyan
    Set-Location $repo

    # 清理残留锁文件
    $lockFile = Join-Path $repo ".git\index.lock"
    if (Test-Path $lockFile) {
        try {
            Remove-Item $lockFile -Force -ErrorAction Stop
            Write-Host "已删除残留锁文件: $lockFile" -ForegroundColor Yellow
        } catch {
            Write-Host "锁文件被占用，无法删除: $lockFile" -ForegroundColor Red
            Write-Host "请关闭 VS Code / IDE / 其他 Git 工具后重试" -ForegroundColor Red
            return
        }
    }

    git add -A
    git commit -m $msg
    git push

    Write-Host "完成: $repo" -ForegroundColor Green
}

$repos = @(
    "D:\ESP32S3\zhineng",
    "D:\esp32s3\powershell",
    "D:\components"
)

foreach ($repo in $repos) {
    Invoke-GitPush $repo
}

Write-Host "所有项目推送完毕！" -ForegroundColor Yellow

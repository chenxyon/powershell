# 定义需要提交的项目路径
$repos = @(
    "D:\esp32s3\zhineng",
    "D:\esp32s3\powershell",
    "D:\components"

)

# 循环执行 git 操作
foreach ($repo in $repos) {
    Write-Host "正在处理: $repo" -ForegroundColor Cyan
    Set-Location $repo
    git add -A
    git commit -m '优化逻辑'
    git push
    Write-Host "完成: $repo" -ForegroundColor Green
}

Write-Host "所有项目推送完毕！" -ForegroundColor Yellow
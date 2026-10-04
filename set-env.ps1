<#
.SYNOPSIS
    设置 / 查看 / 删除 / 导出 / 导入 Windows 环境变量（用户级或系统级）。

.DESCRIPTION
    支持以下操作：
      .\set-env.ps1 <变量名> <变量值> [-Scope u|s]      # 设置（PATH 自动追加）
      .\set-env.ps1 <变量名> -Show                     # 查看单个
      .\set-env.ps1 <变量名> -Remove [-Scope u|s]      # 删除
      .\set-env.ps1 -List [-Scope u|s|a]               # 列出
      .\set-env.ps1 [-<通配符>] -Export [-Scope u|s|a] [-OutFile 文件] [-Format json|ps1|env|csv]
      .\set-env.ps1 -Import -InFile 文件 [-Format ...] [-Overwrite] [-Force] [-Preview]

    PATH 特殊处理：
      - 设置 PATH 时是【追加】而不是覆盖，自动去重
      - 删除 PATH 时需指定要移除的路径，禁止直接删除整个 PATH
      - 导入 PATH 时默认【智能合并】：已有路径保留，新路径追加（去重）
        加 -Overwrite 才覆盖整个 PATH

.PARAMETER Scope
    u = 用户级（默认）
    s = 系统级（需管理员）
    a = 全部（-List / -Export 使用）

.PARAMETER OutFile
    导出目标文件。不指定则打印到控制台。

.PARAMETER InFile
    导入源文件。

.PARAMETER Format
    json / ps1 / env / csv。未指定时按扩展名判断。

.PARAMETER Overwrite
    导入时对 PATH 采用【覆盖】而不是默认的智能合并。

.PARAMETER Force
    导入时不询问确认。

.PARAMETER Preview
    仅预览要导入的内容，不写入。
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Name,

    [Parameter(Position = 1)]
    [string]$Value,

    [ValidateSet("u", "s", "a", "U", "S", "A")]
    [string]$Scope,

    [switch]$Show,
    [switch]$Remove,
    [switch]$List,
    [switch]$Export,
    [switch]$Import,
    [string]$OutFile,
    [string]$InFile,
    [ValidateSet("json", "ps1", "env", "csv", "JSON", "PS1", "ENV", "CSV")]
    [string]$Format,
    [switch]$Overwrite,
    [switch]$Force,
    [switch]$Preview,
    [Alias("h", "?")]
    [switch]$Help
)

# ============================================================
# 工具函数
# ============================================================
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-RealScope {
    param([string]$S)
    if ([string]::IsNullOrWhiteSpace($S)) { return "User" }
    switch ($S.ToLower()) {
        "u" { return "User" }
        "s" { return "Machine" }
        "a" { return "All" }
        default { return "User" }
    }
}

function Resolve-Format {
    param([string]$File, [string]$Format)
    if (-not [string]::IsNullOrWhiteSpace($Format)) { return $Format.ToLower() }
    $ext = [IO.Path]::GetExtension($File).TrimStart('.').ToLower()
    switch ($ext) {
        "json" { return "json" }
        "ps1"  { return "ps1" }
        "env"  { return "env" }
        "csv"  { return "csv" }
        default { return "json" }
    }
}

function Show-Help {
    Write-Host ""
    Write-Host "set-env.ps1 - Windows 环境变量管理" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "用法:" -ForegroundColor Yellow
    Write-Host "  .\set-env.ps1 <变量名> <变量值> [-Scope u|s]" -ForegroundColor Gray
    Write-Host "  .\set-env.ps1 PATH <路径> [-Scope u|s]" -ForegroundColor Gray
    Write-Host "  .\set-env.ps1 <变量名> -Show" -ForegroundColor Gray
    Write-Host "  .\set-env.ps1 <变量名> -Remove [-Scope u|s]" -ForegroundColor Gray
    Write-Host "  .\set-env.ps1 PATH <路径> -Remove" -ForegroundColor Gray
    Write-Host "  .\set-env.ps1 -List [-Scope u|s|a]" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  .\set-env.ps1 [-<通配符>] -Export [-Scope u|s|a] [-OutFile 文件] [-Format json|ps1|env|csv]" -ForegroundColor Gray
    Write-Host "      导出。省略通配符则全部。不指定 -OutFile 则打印到控制台。" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  .\set-env.ps1 -Import -InFile 文件 [-Format ...] [-Overwrite] [-Force] [-Preview]" -ForegroundColor Gray
    Write-Host "      导入。PATH 默认智能合并（已有保留，新的追加）；-Overwrite 改为覆盖。" -ForegroundColor DarkGray
    Write-Host "      -Preview 只预览不写入；-Force 跳过确认询问。" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  .\set-env.ps1 -h" -ForegroundColor Gray
    Write-Host ""
    Write-Host "示例:" -ForegroundColor Yellow
    Write-Host "  .\set-env.ps1 JAVA_HOME 'C:\Java\jdk-17'" -ForegroundColor DarkGray
    Write-Host "  .\set-env.ps1 PATH 'C:\Tools' -Scope s" -ForegroundColor DarkGray
    Write-Host "  .\set-env.ps1 -Export -Scope a -OutFile env.json" -ForegroundColor DarkGray
    Write-Host "  .\set-env.ps1 -Import -InFile env.json" -ForegroundColor DarkGray
    Write-Host "  .\set-env.ps1 -Import -InFile env.json -Preview" -ForegroundColor DarkGray
    Write-Host ""
}

function Show-VarList {
    param([string]$Which)
    $label = if ($Which -eq "User") { "用户级环境变量 ($env:USERNAME)" } else { "系统级环境变量" }
    Write-Host "==== $label ====" -ForegroundColor Cyan
    $vars = [Environment]::GetEnvironmentVariables($Which)
    if (-not $vars -or $vars.Count -eq 0) {
        Write-Host "  (空)" -ForegroundColor DarkGray
        return
    }
    $vars.GetEnumerator() | Sort-Object Name | ForEach-Object {
        Write-Host ("  {0,-30} = {1}" -f $_.Name, $_.Value)
    }
}

# ============================================================
# 导出
# ============================================================
function Export-Vars {
    param(
        [string]$Pattern,
        [string]$Which,
        [string]$OutFile,
        [string]$Format
    )

    $targets = switch ($Which) {
        "User"    { @("User") }
        "Machine" { @("Machine") }
        default   { @("User", "Machine") }
    }

    $result = [ordered]@{}
    foreach ($w in $targets) {
        $vars = [Environment]::GetEnvironmentVariables($w)
        $matched = [ordered]@{}
        foreach ($k in ($vars.Keys | Sort-Object)) {
            if ([string]::IsNullOrWhiteSpace($Pattern) -or $Pattern -eq "*" -or $k -like $Pattern) {
                $matched[$k] = $vars[$k]
            }
        }
        if ($matched.Count -gt 0) { $result[$w] = $matched }
    }

    if ($result.Count -eq 0) {
        $msg = if ([string]::IsNullOrWhiteSpace($Pattern)) { "没有可导出的变量。" } else { "没有匹配 '$Pattern' 的变量。" }
        Write-Host $msg -ForegroundColor Yellow
        return
    }

    if ([string]::IsNullOrWhiteSpace($OutFile)) {
        foreach ($w in $result.Keys) {
            $label = if ($w -eq "User") { "用户级 ($env:USERNAME)" } else { "系统级" }
            Write-Host "==== $label ====" -ForegroundColor Cyan
            foreach ($k in $result[$w].Keys) {
                Write-Host ("  {0,-30} = {1}" -f $k, $result[$w][$k])
            }
            Write-Host ""
        }
        $total = 0
        foreach ($w in $result.Keys) { $total += $result[$w].Count }
        Write-Host "共 $total 项。加 -OutFile <路径> 可导出到文件。" -ForegroundColor DarkGray
        return
    }

    $Format = Resolve-Format -File $OutFile -Format $Format

    switch ($Format) {
        "json" {
            $result | ConvertTo-Json -Depth 6 | Set-Content -Path $OutFile -Encoding UTF8
        }
        "ps1" {
            $lines = @()
            $lines += "# 由 set-env.ps1 导出  时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            $lines += "# 说明：直接执行本脚本即可把这些变量恢复到对应范围"
            foreach ($w in $result.Keys) {
                $lines += ""
                $lines += "# ---- $w ----"
                foreach ($k in $result[$w].Keys) {
                    $v = [string]$result[$w][$k]
                    $v = $v -replace "'", "''"
                    $lines += "[Environment]::SetEnvironmentVariable('$k', '$v', '$w')"
                }
            }
            $lines | Set-Content -Path $OutFile -Encoding UTF8
        }
        "env" {
            $lines = @()
            foreach ($w in $result.Keys) {
                if ($result.Keys.Count -gt 1) { $lines += "# ---- $w ----" }
                foreach ($k in $result[$w].Keys) {
                    $lines += "$k=$($result[$w][$k])"
                }
            }
            $lines | Set-Content -Path $OutFile -Encoding UTF8
        }
        "csv" {
            $rows = @()
            foreach ($w in $result.Keys) {
                foreach ($k in $result[$w].Keys) {
                    $rows += [PSCustomObject]@{
                        Scope = $w
                        Name  = $k
                        Value = $result[$w][$k]
                    }
                }
            }
            $rows | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8
        }
    }

    $total = 0
    foreach ($w in $result.Keys) { $total += $result[$w].Count }
    Write-Host "已导出 $total 项到：$OutFile （格式：$Format）" -ForegroundColor Green
}

# ============================================================
# 导入
# ============================================================
function Import-Vars {
    param(
        [string]$InFile,
        [string]$Format,
        [string]$ScopeOverride,
        [switch]$Overwrite,
        [switch]$Force,
        [switch]$Preview
    )

    if (-not (Test-Path $InFile)) {
        Write-Host "文件不存在：$InFile" -ForegroundColor Red
        return
    }

    $Format = Resolve-Format -File $InFile -Format $Format

    $data = [ordered]@{}

    switch ($Format) {
        "json" {
            $raw = Get-Content $InFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $propNames = @($raw.PSObject.Properties | ForEach-Object { $_.Name })
            $isLayered = ($propNames -contains "User") -or ($propNames -contains "Machine")
            if ($isLayered) {
                foreach ($p in $raw.PSObject.Properties) {
                    if ($p.Name -notin @("User","Machine")) { continue }
                    $h = [ordered]@{}
                    foreach ($pp in $p.Value.PSObject.Properties) {
                        $h[$pp.Name] = [string]$pp.Value
                    }
                    $data[$p.Name] = $h
                }
            } else {
                $s = if ($ScopeOverride -and $ScopeOverride -ne "All") { $ScopeOverride } else { "User" }
                $h = [ordered]@{}
                foreach ($p in $raw.PSObject.Properties) {
                    $h[$p.Name] = [string]$p.Value
                }
                $data[$s] = $h
            }
        }
        "ps1" {
            $lines = Get-Content $InFile -Encoding UTF8
            $re = [regex]"^\s*\[Environment\]::SetEnvironmentVariable\(\s*'((?:[^']|'')*)'\s*,\s*'((?:[^']|'')*)'\s*,\s*'((?:[^']|'')*)'\s*\)"
            foreach ($line in $lines) {
                $m = $re.Match($line)
                if (-not $m.Success) { continue }
                $n = $m.Groups[1].Value -replace "''", "'"
                $v = $m.Groups[2].Value -replace "''", "'"
                $s = $m.Groups[3].Value
                if ($s -notin @("User","Machine")) { continue }
                if (-not $data.Contains($s)) { $data[$s] = [ordered]@{} }
                $data[$s][$n] = $v
            }
        }
        "env" {
            $s = if ($ScopeOverride -and $ScopeOverride -ne "All") { $ScopeOverride } else { "User" }
            $h = [ordered]@{}
            foreach ($line in (Get-Content $InFile -Encoding UTF8)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                if ($line.TrimStart().StartsWith("#")) { continue }
                $idx = $line.IndexOf('=')
                if ($idx -lt 1) { continue }
                $n = $line.Substring(0, $idx).Trim()
                $v = $line.Substring($idx + 1)
                $h[$n] = $v
            }
            if ($h.Count -gt 0) { $data[$s] = $h }
        }
        "csv" {
            $rows = Import-Csv $InFile -Encoding UTF8
            foreach ($row in $rows) {
                $s = if ($row.Scope) { $row.Scope } else { "User" }
                if ($s -notin @("User","Machine")) { $s = "User" }
                if (-not $data.Contains($s)) { $data[$s] = [ordered]@{} }
                $data[$s][$row.Name] = $row.Value
            }
        }
    }

    $total = 0
    foreach ($s in $data.Keys) { $total += $data[$s].Count }
    if ($total -eq 0) {
        Write-Host "文件中没有可导入的变量。" -ForegroundColor Yellow
        return
    }

    # ---- 预览 ----
    Write-Host "即将导入以下变量：" -ForegroundColor Cyan
    foreach ($s in $data.Keys) {
        $label = if ($s -eq "User") { "用户级" } else { "系统级" }
        Write-Host "  [$label]" -ForegroundColor Yellow
        foreach ($k in $data[$s].Keys) {
            $v = [string]$data[$s][$k]
            if ($v.Length -gt 60) { $v = $v.Substring(0,57) + "..." }
            Write-Host ("    {0} = {1}" -f $k, $v) -ForegroundColor Gray
        }
    }

    if ($Preview) {
        Write-Host "预览模式，未写入。" -ForegroundColor DarkGray
        return
    }

    if ($data.Contains("Machine") -and -not (Test-Admin)) {
        Write-Host "文件中包含系统级变量，需要管理员权限。" -ForegroundColor Red
        return
    }

    if (-not $Force) {
        $ans = Read-Host "确认导入 $total 项？(y/N)"
        if ($ans -notmatch '^(y|yes)$') {
            Write-Host "已取消。" -ForegroundColor Yellow
            return
        }
    }

    # ---- 写入 ----
    $okCount = 0
    foreach ($s in $data.Keys) {
        foreach ($k in $data[$s].Keys) {
            $val = [string]$data[$s][$k]
            try {
                if ($k -ieq "PATH") {
                    if ($Overwrite) {
                        # 显式覆盖
                        [Environment]::SetEnvironmentVariable($k, $val, $s)
                        Write-Host "  [$s] PATH 已覆盖" -ForegroundColor DarkGray
                    } else {
                        # 智能合并：已有的保留，没有的追加
                        $old = [Environment]::GetEnvironmentVariable($k, $s)
                        $parts = @()
                        if (-not [string]::IsNullOrWhiteSpace($old)) {
                            $parts = $old -split ';' | Where-Object { $_ -ne '' }
                        }
                        # 建立已有路径的归一化集合，用于判重
                        $existingNorm = @{}
                        foreach ($p in $parts) {
                            $existingNorm[$p.TrimEnd('\').ToLower()] = $true
                        }
                        $added = @()
                        foreach ($entry in ($val -split ';' | Where-Object { $_ -ne '' })) {
                            $norm = $entry.TrimEnd('\').ToLower()
                            if (-not $existingNorm.ContainsKey($norm)) {
                                $parts += $entry
                                $existingNorm[$norm] = $true
                                $added += $entry
                            }
                        }
                        $newValue = ($parts -join ';')
                        [Environment]::SetEnvironmentVariable($k, $newValue, $s)
                        if ($added.Count -gt 0) {
                            Write-Host "  [$s] PATH 新增 $($added.Count) 条：$($added -join ', ')" -ForegroundColor DarkGray
                        } else {
                            Write-Host "  [$s] PATH 无新增（全部已存在）" -ForegroundColor DarkGray
                        }
                    }
                } else {
                    [Environment]::SetEnvironmentVariable($k, $val, $s)
                }
                $okCount++
            } catch {
                Write-Host "写入失败：[$s] $k - $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }

    # ---- 同步当前进程 ----
    foreach ($s in $data.Keys) {
        foreach ($k in $data[$s].Keys) {
            $v = [Environment]::GetEnvironmentVariable($k, $s)
            Set-Item "Env:\$k" -Value $v -ErrorAction SilentlyContinue
        }
    }

    Write-Host "导入完成，共 $okCount 项。" -ForegroundColor Green
    Write-Host "提示：已打开的其它窗口需重启才能读到新值。" -ForegroundColor DarkGray
}

# ============================================================
# 主逻辑
# ============================================================

if ($Help) { Show-Help; return }

# ---- 列表 ----
if ($List) {
    $s = if ($Scope) { $Scope.ToLower() } else { "u" }
    switch ($s) {
        "u" { Show-VarList "User" }
        "s" { Show-VarList "Machine" }
        "a" { Show-VarList "User"; Write-Host ""; Show-VarList "Machine" }
        default { Write-Host "无效的 Scope：$Scope （应为 u / s / a）" -ForegroundColor Red }
    }
    return
}

# ---- 导出 ----
if ($Export) {
    $realScope = Get-RealScope $Scope
    $pattern = if ([string]::IsNullOrWhiteSpace($Name)) { $null } else { $Name.Trim() }
    Export-Vars -Pattern $pattern -Which $realScope -OutFile $OutFile -Format $Format
    return
}

# ---- 导入 ----
if ($Import) {
    if ([string]::IsNullOrWhiteSpace($InFile)) {
        Write-Host "错误：-Import 需要指定 -InFile <文件路径>。" -ForegroundColor Red
        return
    }
    $realScope = Get-RealScope $Scope
    Import-Vars -InFile $InFile -Format $Format -ScopeOverride $realScope `
                -Overwrite:$Overwrite -Force:$Force -Preview:$Preview
    return
}

# ---- 后续操作必须提供变量名 ----
if ([string]::IsNullOrWhiteSpace($Name)) {
    Write-Host "错误：未指定变量名。使用 -h 查看帮助。" -ForegroundColor Red
    return
}

$Name = $Name.Trim()
$isPath = ($Name.ToUpper() -eq "PATH")
$realScope = Get-RealScope $Scope

# ---- 查看 ----
if ($Show) {
    $found = $false
    foreach ($w in @("User", "Machine")) {
        $vars = [Environment]::GetEnvironmentVariables($w)
        if ($vars.ContainsKey($Name)) {
            Write-Host ("[{0}] {1} = {2}" -f $w, $Name, $vars[$Name]) -ForegroundColor Green
            $found = $true
        }
    }
    if (Test-Path "Env:\$Name") {
        Write-Host ("[Process] {0} = {1}" -f $Name, (Get-Item "Env:\$Name").Value) -ForegroundColor DarkCyan
        $found = $true
    }
    if (-not $found) { Write-Host "未找到变量：$Name" -ForegroundColor Yellow }
    return
}

# ---- 删除 ----
if ($Remove) {
    if ($realScope -eq "Machine" -and -not (Test-Admin)) {
        Write-Host "删除系统级变量需要管理员权限。请以管理员身份运行 PowerShell。" -ForegroundColor Red
        return
    }
    try {
        if ($isPath) {
            if ([string]::IsNullOrWhiteSpace($Value)) {
                Write-Host "删除 PATH 需要指定要移除的路径，例如：-Remove PATH 'C:\Old'" -ForegroundColor Red
                Write-Host "不建议直接删除整个 PATH 变量。" -ForegroundColor Yellow
                return
            }
            $old = [Environment]::GetEnvironmentVariable($Name, $realScope)
            if ([string]::IsNullOrWhiteSpace($old)) {
                Write-Host "PATH 为空，无需移除。" -ForegroundColor Yellow
                return
            }
            $parts = $old -split ';' | Where-Object { $_ -ne '' }
            $toRemove = $Value -split ';' | Where-Object { $_ -ne '' }
            $removed = @()
            foreach ($r in $toRemove) {
                $norm = $r.TrimEnd('\')
                $before = $parts.Count
                $parts = $parts | Where-Object { $_.TrimEnd('\') -ne $norm }
                if ($parts.Count -lt $before) { $removed += $r }
            }
            if ($removed.Count -eq 0) {
                Write-Host "未找到要移除的路径：$Value" -ForegroundColor Yellow
                return
            }
            $newValue = ($parts -join ';')
            [Environment]::SetEnvironmentVariable($Name, $newValue, $realScope)
            Write-Host "已从 [$realScope] PATH 中移除：$($removed -join ', ')" -ForegroundColor Green
            Set-Item "Env:\$Name" -Value $newValue -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable($Name, $null, $realScope)
            Write-Host "已删除 [$realScope] $Name" -ForegroundColor Green
            if (Test-Path "Env:\$Name") { Remove-Item "Env:\$Name" -ErrorAction SilentlyContinue }
        }
    } catch {
        Write-Host "删除失败：$($_.Exception.Message)" -ForegroundColor Red
    }
    return
}

# ---- 设置 ----
if ($PSBoundParameters.ContainsKey("Value")) {
    if ($realScope -eq "Machine" -and -not (Test-Admin)) {
        Write-Host "设置系统级变量需要管理员权限。请以管理员身份运行 PowerShell。" -ForegroundColor Red
        return
    }
    try {
        if ($isPath) {
            $old = [Environment]::GetEnvironmentVariable($Name, $realScope)
            $parts = @()
            if (-not [string]::IsNullOrWhiteSpace($old)) {
                $parts = $old -split ';' | Where-Object { $_ -ne '' }
            }
            $newEntries = $Value -split ';' | Where-Object { $_ -ne '' }
            foreach ($entry in $newEntries) {
                $norm = $entry.TrimEnd('\')
                $parts = $parts | Where-Object { $_.TrimEnd('\') -ne $norm }
                $parts += $entry
            }
            $newValue = ($parts -join ';')
            [Environment]::SetEnvironmentVariable($Name, $newValue, $realScope)
            Write-Host "已追加 [$realScope] PATH += $Value" -ForegroundColor Green
        } else {
            [Environment]::SetEnvironmentVariable($Name, $Value, $realScope)
            Write-Host "已设置 [$realScope] $Name = $Value" -ForegroundColor Green
        }
        $procVal = [Environment]::GetEnvironmentVariable($Name, $realScope)
        Set-Item "Env:\$Name" -Value $procVal -ErrorAction SilentlyContinue
        Write-Host "提示：已打开的其它窗口需重启才能读到新值。" -ForegroundColor DarkGray
    } catch {
        Write-Host "设置失败：$($_.Exception.Message)" -ForegroundColor Red
    }
    return
}

Show-Help
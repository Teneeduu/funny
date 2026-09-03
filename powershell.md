# C盘与 VSCode 缓存清理脚本

> 本脚本用于一键关闭 VSCode 并清理其运行缓存、C 盘系统临时垃圾以及清空回收站。

---

## 1. 使用说明

1. 以**管理员身份**打开 PowerShell（按 `Win + X` 键选择 **终端(管理员)** 或 **PowerShell (管理员)**）。
2. 复制下方代码块中的所有内容并直接粘贴运行。

---

## 2. PowerShell 清理脚本代码

```powershell
# ==========================================
# 1. 关闭 VSCode 防止文件占用
# ==========================================
Write-Host "正在关闭 VSCode..." -ForegroundColor Yellow
Stop-Process -Name "Code" -ErrorAction SilentlyContinue

# ==========================================
# 2. 清理 VSCode 核心缓存目录
# ==========================================
Write-Host "正在清理 VSCode 缓存..." -ForegroundColor Green
$vscodeCachePaths = @(
    "$env:APPDATA\Code\Cache\*",
    "$env:APPDATA\Code\CachedData\*",
    "$env:APPDATA\Code\CachedExtensions\*",
    "$env:APPDATA\Code\CachedExtensionVSIXs\*",
    "$env:APPDATA\Code\Code Cache\*",
    "$env:APPDATA\Code\GPUCache\*",
    "$env:APPDATA\Code\logs\*"
)

foreach ($path in $vscodeCachePaths) {
    Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
}

# ==========================================
# 3. 清理 C 盘系统与临时垃圾文件
# ==========================================
Write-Host "正在清理系统临时文件与更新缓存..." -ForegroundColor Green
$sysCachePaths = @(
    "$env:TEMP\*",
    "C:\Windows\Temp\*",
    "C:\Windows\SoftwareDistribution\Download\*",
    "C:\Windows\Logs\*"
)

foreach ($path in $sysCachePaths) {
    Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
}

# ==========================================
# 4. 清理开发工具包管理器缓存 (Python / Node)
# ==========================================
Write-Host "正在清理 pip / npm 缓存..." -ForegroundColor Green
if (Get-Command pip -ErrorAction SilentlyContinue) { pip cache purge }
if (Get-Command npm -ErrorAction SilentlyContinue) { npm cache clean --force }

# ==========================================
# 5. 清理 Windows 清空回收站
# ==========================================
Write-Host "正在清空回收站..." -ForegroundColor Green
Clear-RecycleBin -Force -ErrorAction SilentlyContinue

Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "      C 盘与 VSCode 缓存清理完成！" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
# 编译 TUN 版本 x-tunnel.exe
# 用法: powershell -ExecutionPolicy Bypass -File 编译tun.ps1
$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

Write-Host "=== 编译 x-tunnel.exe（含 TUN 模式）===" -ForegroundColor Cyan

# 列出所有 .go 源文件（仅供日志展示，不喂给 go build ——
# 显式文件列表会让 Go 忽略 //go:build 标签，导致 windows / !windows 互斥文件
# 同时被编译并报 redeclared。用包级 `go build .` 让 build 标签自动生效。）
$goFiles = Get-ChildItem -Filter "*.go" | Select-Object -ExpandProperty Name
Write-Host "Go 源文件: $($goFiles -join ', ')" -ForegroundColor Gray

# 包级构建
go build -trimpath -buildvcs=false -ldflags="-s -w -buildid=" -o x-tunnel.exe .
if ($LASTEXITCODE -eq 0) {
    Write-Host "`n✓ 编译成功! x-tunnel.exe" -ForegroundColor Green
    Write-Host "  大小: $((Get-Item x-tunnel.exe).Length / 1KB) KB" -ForegroundColor Gray
    Write-Host "`n使用方法:" -ForegroundColor Yellow
    Write-Host "  .\x-tunnel.exe -tun -f wss://your-server.com:443 -l socks5://127.0.0.1:10808" -ForegroundColor White
    Write-Host "`n注意: TUN 模式需要管理员权限 + wintun.dll" -ForegroundColor Red
} else {
    Write-Host "`n编译失败!" -ForegroundColor Red
}

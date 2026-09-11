:: 编译 TUN 版本 x-tunnel.exe (x64)
:: 需要 Go 1.22+，Wintun 驱动支持
@echo off
chcp 65001 >nul
cd /d "%~dp0"

echo === 编译 x-tunnel.exe（含 TUN 模式）===
echo.

:: 列出 .go 源文件仅供查看，不喂给 go build ——
:: 显式文件列表会让 Go 忽略 //go:build 标签，导致 windows / !windows
:: 互斥文件同时编译报 redeclared。改用包级 `go build .`。
dir /b *.go

setlocal enabledelayedexpansion

go build -trimpath -buildvcs=false -ldflags="-s -w -buildid=" -o x-tunnel.exe .

if %ERRORLEVEL% EQU 0 (
    echo.
    echo ✓ 编译成功！
    dir /b x-tunnel.exe
    echo.
    echo 使用方法:
    echo   x-tunnel.exe -tun -f wss://your-server.com:443 -l socks5://127.0.0.1:10808
    echo.
    echo 需要管理员权限才能创建 TUN 设备
) else (
    echo.
    echo ✗ 编译失败
    echo 请确保已安装 Go 1.22+ 和所有依赖
)
endlocal
pause

<#
.SYNOPSIS
    EchOS Windows 本地完整构建打包：内核 -> Flutter -> 安装包 -> 便携版

.DESCRIPTION
    最关键的一点：内核必须编译输出到 windows/bundle/x-tunnel.exe。

    原因：windows/runner/CMakeLists.txt 末尾挂了 POST_BUILD 钩子，调用
    copy_bundle.cmake，用 copy_if_different 把 windows/bundle 下的
    x-tunnel.exe / geoip.dat / geosite.dat 拷到产物目录。
    如果只把内核编译到 third_party/x-tunnel/，flutter build 会用 bundle 里
    的旧内核把产物覆盖掉 —— 结果是「代码改了、打包还是旧的」，且不报任何错。

    仓库里 windows/bundle/x-tunnel.exe 被 .gitignore 排除，不会推到 GitHub；
    CI 每次用 setup-go 从源码现编，所以远端永远是最新的。

.PARAMETER Version
    版本号，形如 1.0.1。同时注入到三处：ECHOS_VERSION / --build-name /
    ISCC /DAPP_VERSION。必须与即将打的 v* 标签一致，否则自动更新会静默失效。

.PARAMETER Repo
    更新源 owner/repo，注入 ECHOS_REPO。

.EXAMPLE
    .\build_local.ps1
    .\build_local.ps1 -Version 1.0.2
#>
[CmdletBinding()]
param(
    [string]$Version = '1.0.0',
    [string]$Repo    = 'nerder-real/EchOS-Win',
    [switch]$SkipPortable
)

$ErrorActionPreference = 'Stop'
# 中文 Windows 控制台默认 GBK，UTF-8 中文会显示成乱码；统一按 UTF-8 输出
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$rel  = Join-Path $root 'build\windows\x64\runner\Release'

# 构建中间产物（便携版归档、SFX 模块、ResourceHacker）统一放
# F:\WorkBuddy\Temp\echos-build：不占 C 盘；目录在仓库之外，天然不会被 git 提交；
# SFX / ResourceHacker 缓存长期复用，系统临时目录被清理也不受影响。
# 注意：这里只放构建产物。Go 的模块缓存（GOPATH）在 C:\Go\gopath，跟工具链走，
# 不要往这里挪；应用运行时数据（托盘图标、日志）在 %APPDATA%\EchOS，也不要放这。
$tmp = 'F:\WorkBuddy\Temp\echos-build'
$tmpOk = $false
if (Test-Path 'F:\') {
    try {
        New-Item -ItemType Directory -Force -Path $tmp -ErrorAction Stop | Out-Null
        $tmpOk = $true
    } catch {
        # 光驱、断网的网络盘、无写权限等情况：盘符在但用不了，走降级
        $tmpOk = $false
    }
}
if (-not $tmpOk) {
    # 换机器/没有可用 F 盘时降级到项目下的 Temp\echos-build（已在 .gitignore 排除）
    $tmp = Join-Path $root 'Temp\echos-build'
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
}
Write-Host "  构建临时目录: $tmp" -ForegroundColor Gray

function Find-Exe {
    param([string[]]$Candidates, [string]$Name)
    foreach ($c in $Candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-Checked {
    param([string]$What)
    if ($LASTEXITCODE -ne 0) { throw "$What 失败（exit=$LASTEXITCODE）" }
}

Write-Host "版本: $Version    更新源: $Repo" -ForegroundColor White
Write-Host ''

# ---------- 1/4 内核 ----------
# 直接输出到 windows/bundle/，保证 flutter build 拷的是刚编好的这一份。
# go / flutter 不一定在当前 shell 的 PATH 里（比如从 Git Bash 或某些终端启动），
# 这里显式按常见安装位置兜底查找，找不到再报错，避免中途莫名中断。
# Go 已统一到 C:\Go（GOROOT），兼容旧的 ~/sdk/go 布局
$go = Find-Exe @(
    'C:\Go\bin\go.exe',
    "$env:ProgramFiles\Go\bin\go.exe",
    "$env:USERPROFILE\sdk\go\bin\go.exe"
) 'go'
if (-not $go) { throw '未找到 go.exe，请安装 Go 或把 go 加入 PATH' }
# 预检：只判断「文件存在」不够。某些受限环境（沙箱/策略）会让 go.exe 启动即失败，
# 表现为无任何输出且 $LASTEXITCODE 保持为空 —— 到下面 Invoke-Checked 就只剩
# 「失败（exit=）」这种没有信息量的提示。这里先跑一次 go version 把问题说清楚。
$goProbe = & $go version 2>&1
if (-not $goProbe) {
    throw "go.exe 存在但无法执行（$go）。常见原因：当前终端被沙箱/安全策略限制了子进程启动。`n请在普通 PowerShell / 终端中重跑本脚本。"
}
Write-Host "  go: $goProbe" -ForegroundColor Gray

# Flutter 已统一到 C:\Flutter
$flutter = Find-Exe @(
    'C:\Flutter\bin\flutter.bat',
    'C:\src\flutter\bin\flutter.bat',
    "$env:USERPROFILE\flutter\bin\flutter.bat"
) 'flutter'
if (-not $flutter) { throw '未找到 flutter.bat，请安装 Flutter 或把 flutter 加入 PATH' }

Write-Host '=== 1/4 编译内核 -> windows/bundle/x-tunnel.exe ===' -ForegroundColor Cyan
$bundleExe = Join-Path $root 'windows\bundle\x-tunnel.exe'
Push-Location (Join-Path $root 'third_party\x-tunnel')
& $go build -trimpath -buildvcs=false -ldflags="-s -w -buildid=" -o "$bundleExe" .
Invoke-Checked '内核编译'
Pop-Location
Write-Host ("  内核 {0:N1} MB" -f ((Get-Item $bundleExe).Length / 1MB)) -ForegroundColor Green

# ---------- 1.5/4 分流数据 ----------
# 必须在 flutter build 之前：copy_bundle.cmake 是 POST_BUILD 钩子，
# 构建时从 windows/bundle/ 把 geoip.dat / geosite.dat 拷到产物目录。
# 仓库不携带这两个文件（.gitignore 已排除，与 CI 一样打包时下载）。
$bundleDir = Join-Path $root 'windows\bundle'
New-Item -ItemType Directory -Force -Path $bundleDir | Out-Null
foreach ($f in @('geoip.dat', 'geosite.dat')) {
    $dst = Join-Path $bundleDir $f
    if (-not (Test-Path $dst)) {
        Write-Host "  下载 $f ..." -ForegroundColor Gray
        Invoke-WebRequest "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/$f" -OutFile $dst
    }
}

# ---------- 2/4 Flutter ----------
Write-Host '=== 2/4 Flutter Windows Release ===' -ForegroundColor Cyan
Push-Location $root
& $flutter build windows --release --build-name $Version `
    --dart-define=ECHOS_VERSION=$Version --dart-define=ECHOS_REPO=$Repo
Invoke-Checked 'Flutter 构建'
Pop-Location
# 校验：产物里的内核必须与刚编的一致，防止被 bundle 旧文件覆盖
$relExe = Join-Path $rel 'x-tunnel.exe'
$a = (Get-FileHash $bundleExe -Algorithm MD5).Hash
$b = (Get-FileHash $relExe   -Algorithm MD5).Hash
if ($a -ne $b) { throw "产物内核与源码编译结果不一致（$a vs $b），检查 copy_bundle.cmake" }
Write-Host '  产物内核 md5 校验一致' -ForegroundColor Green

# ---------- 3/4 安装包 ----------
# 清空 Output，只保留本次构建的产物，避免历史版本越堆越多。
# 刻意放在打包前而不是脚本开头：内核或 Flutter 阶段万一失败，
# 上一次的产物还在，不会落得新旧两头空。
$outDir = Join-Path $root 'Output'
if (Test-Path $outDir) {
    Get-ChildItem -LiteralPath $outDir -Force |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Write-Host "  已清空 Output（只保留本次产物）" -ForegroundColor Gray

Write-Host '=== 3/4 Inno Setup 安装包 ===' -ForegroundColor Cyan
$iscc = Find-Exe @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) 'ISCC'
if (-not $iscc) { throw '未找到 ISCC.exe，请先安装 Inno Setup 6' }
& $iscc (Join-Path $root 'installer\EchOS.iss') "/DAPP_VERSION=v$Version"
Invoke-Checked 'Inno Setup 打包'

# ---------- 4/4 便携版 ----------
$setupExe = Join-Path $root "Output\EchOS-Win-v$Version-x64-Setup.exe"
Write-Host "  安装包: $setupExe" -ForegroundColor Green

if ($SkipPortable) {
    Write-Host '（已跳过便携版）' -ForegroundColor Yellow
    return
}

Write-Host '=== 4/4 7-Zip SFX 便携版 ===' -ForegroundColor Cyan
$7z = Find-Exe @(
    "$env:ProgramFiles\7-Zip\7z.exe",
    'D:\Program Files\7-Zip\7z.exe',
    "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
) '7z'
if (-not $7z) { throw '未找到 7z.exe，请先安装 7-Zip' }

# 4.1 在 Release 目录内压缩，归档条目平铺（echos.exe 在根，SFX 才能直接运行）
$arc = Join-Path $tmp 'echos_portable.7z'
Push-Location $rel
& $7z a -t7z -y "$arc" * | Out-Null
Invoke-Checked '7z 压缩'
Pop-Location

# 4.2 SFX 模块（需支持 ;!@Install@! 配置，故用 7zSD 而非 7-Zip 自带的 7z.sfx）
# 文件名带版本号：图标和版本资源都是按当前版本注入的，换版本必须重新生成，
# 否则会沿用上一版注入了旧版本号的缓存模块。
$sfx = Join-Path $tmp "iconed-$Version.sfx"
if (-not (Test-Path $sfx)) {
    $sfxSrc = Join-Path $tmp '7zsd_x\7zsd_LZMA2_x64.sfx'
    if (-not (Test-Path $sfxSrc)) {
        Write-Host '  下载 7zSD SFX 模块...' -ForegroundColor Gray
        $dl = Join-Path $tmp '7zsd.7z'
        Invoke-WebRequest 'https://raw.githubusercontent.com/OlegScherbakov/7zSFX/master/files/7zsd_extra_170_3900.7z' -OutFile $dl
        & $7z x "$dl" "-o$(Join-Path $tmp '7zsd_x')" -y | Out-Null
    }
    Copy-Item $sfxSrc $sfx -Force
    # 4.3 用 ResourceHacker 替换 SFX 的两套资源（只改资源，不动可执行功能）
    $rh = Join-Path $tmp 'reshacker\ResourceHacker.exe'
    if (Test-Path $rh) {
        # 4.3a 图标。mask 必须是 ICONGROUP,101 而不是 MAINICON：7zSD 系列 SFX
        # 自带的图标组 id 就是 101，用 MAINICON 只会「新增」一个组而不覆盖它，
        # Windows 按 id 升序取第一个组，便携版就会继续显示 7-Zip 图标。
        # 换 SFX 模块时需重新确认这个 id。
        & $rh -open "$sfx" -save "$sfx" -action addoverwrite `
              -res (Join-Path $root 'installer\logo.ico') -mask 'ICONGROUP,101,' | Out-Null

        # 4.3b 版本资源。不做这步，右键「属性 → 详细信息」显示的是 SFX 模板自带的
        # 7-Zip 信息（1.7.0.3900 / Oleg N. Scherbakov）。
        # 模板里的 LANGUAGE 必须是中性 (0,0)：SFX 原资源就在 000004b0 块里，
        # 若注入成 040904b0（英文），中文系统找不到匹配语言会回退到中性块，
        # 读到的仍然是 7-Zip —— 实测确认过。
        $tpl = Join-Path $root 'installer\portable-version.rc.tpl'
        $rc  = Join-Path $tmp "portable-version-$Version.rc"
        $res = Join-Path $tmp "portable-version-$Version.res"
        $verComma = ($Version -split '\.') -join ','
        if (($Version -split '\.').Count -lt 4) { $verComma = "$verComma,0" }
        $content = (Get-Content -LiteralPath $tpl -Raw -Encoding UTF8) `
            -replace '@VER_DOT@', $Version `
            -replace '@VER_COMMA@', $verComma
        # 写无 BOM 的 UTF-8：带 BOM 时 ResourceHacker 编译可能报错
        [IO.File]::WriteAllText($rc, $content, (New-Object Text.UTF8Encoding $false))
        & $rh -open "$rc" -save "$res" -action compile | Out-Null
        & $rh -open "$sfx" -save "$sfx" -action addoverwrite `
              -res "$res" -mask 'VERSIONINFO,,' | Out-Null
    } else {
        Write-Warning '未找到 ResourceHacker，便携版将沿用 SFX 默认图标与版本信息'
    }
}

# 4.4 官方规范拼接：SFX 模块 + 配置 + 归档
$outDir = Join-Path $root 'Output'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$out = Join-Path $outDir "EchOS-Win-v$Version-x64-Portable.exe"
$fs = [IO.File]::Create($out)
try {
    foreach ($p in @($sfx, (Join-Path $root 'installer\portable-config.txt'), $arc)) {
        $bytes = [IO.File]::ReadAllBytes($p)
        $fs.Write($bytes, 0, $bytes.Length)
    }
} finally { $fs.Close() }

Write-Host "  便携版: $out" -ForegroundColor Green

# 4.5 防伪自检：SFX 里嵌的归档必须和刚构建的 Release 一致。
# 为什么需要：便携版是「SFX 模块 + 配置 + 7z 归档」三段拼接，归档是个独立中间文件。
# 一旦归档是旧的（比如手工分阶段跑构建时传错路径、写到别处去了），拼出来的 exe
# 大小和平时差不多、也能正常安装运行，但装的是上一版代码 —— 不报任何错，极难发现。
# 这里把 SFX 里的 app.so 抽出来和 Release 的逐字节比，对不上就直接构建失败。
$verifyDir = Join-Path $tmp 'verify'
Remove-Item -LiteralPath $verifyDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $verifyDir | Out-Null
& $7z e "$out" "-o$verifyDir" 'data\app.so' -y | Out-Null
$packedApp = Join-Path $verifyDir 'app.so'
if (-not (Test-Path $packedApp)) {
    throw "便携版自检失败：没能从 $out 里抽出 data\app.so"
}
$srcApp = Join-Path $rel 'data\app.so'
$h1 = (Get-FileHash $packedApp -Algorithm MD5).Hash
$h2 = (Get-FileHash $srcApp   -Algorithm MD5).Hash
if ($h1 -ne $h2) { throw "便携版自检失败：包内 app.so($h1) 与 Release($h2) 不一致，归档可能是旧的" }
Write-Host "  便携版自检通过（app.so md5 $h1 与 Release 一致）" -ForegroundColor Green
Remove-Item -LiteralPath $verifyDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '全部完成。' -ForegroundColor Cyan

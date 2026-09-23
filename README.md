# EchOS（Windows版本）
> [EchOS For Mac](https://github.com/nerder-real/EchOS)

ECH + TLS1.3（Encrypted Client Hello）隧道代理客户端，Flutter / Windows 单平台。

本地分流（绕过中国大陆 / 黑名单 / 全局 + 自定义规则）、简易 WebSocket 协议直连、
TLS 会话复用、多入口自动重试。支持两种接管方式：**系统代理**（默认）与 **TUN 模式**
（虚拟网卡接管 `0.0.0.0/0`，需管理员权限）。

## 功能特性

- **ECH 加密握手** —— 握手阶段的 SNI 也被加密，不依赖明文 SNI 的放行策略
- **两种接管方式**
  - 系统代理：改注册表让系统走本地 SOCKS/HTTP 端口，对不支持代理的进程无效
  - TUN 模式：建虚拟网卡接管全部流量，覆盖所有进程；需**管理员权限**
- **本地分流** —— 绕过中国大陆 / 黑名单 / 全局，外加自定义规则；命中直连的不进隧道
- **控制面 DNS 抗污染** —— 解析代理服务器域名时优先走配置的 DoH，
  与系统解析器结果不一致时以 DoH 为准（运营商 DNS 污染会让代理直接失效）
- **多入口自动重试** —— 一个域名解析出多个 IP 时按轮转选入口，建连失败自动换下一个
- **自动更新** —— 比对 GitHub Release 标签，下载替换后重启
- **便携版** —— 单文件自解压，免安装（配置与日志仍写在 `%APPDATA%\EchOS\`）

## 已知限制

| 限制 | 说明 |
|---|---|
| TUN 需管理员 | Windows 不允许运行中提权，只能以管理员身份重启应用；重启后会自动续接代理 |
| simple 协议不支持 UDP | 走代理的 UDP 会回 ICMP 端口不可达促其回落 TCP，**不会**偷偷直连（避免流量泄漏到隧道外） |
| DoH 目标不能是 Cloudflare IP | Worker 服务端用 `connect()`，官方禁止连 CF 网段；内置 DoH 已避开 |
| 分流数据不随仓库分发 | `geoip.dat` / `geosite.dat` 在构建时从上游下载 |

## 界面预览

浅色 / 深色自动适配，跟随 Windows 系统外观自动切换，无需手动设置：

| 浅色 | 深色 |
|---|---|
| ![浅色](screenshot/light.png) | ![深色](screenshot/dark.png) |

## 项目结构

```
EchOS-Win/
├── README.md                   # 项目说明
├── build_local.ps1             # 本地一键构建（内核→Flutter→安装包→便携版）
├── pubspec.yaml                # Flutter 依赖 / 版本 / 字体声明
├── analysis_options.yaml       # lint 规则
├── worker/                     # Cloudflare Worker 服务端
│   ├── Worker-ECH.js           # 服务端完整代码（简易 WebSocket 代理）
│   ├── wrangler.toml           # Worker 配置（名称、入口）
│   └── deploy-worker.sh        # 一键部署脚本（wrangler CLI）
├── third_party/
│   ├── x-tunnel/               # Go 内核
│   │   ├── x-tunnel.go         # 入口：参数解析、端口监听、隧道调度、ECH 准备
│   │   ├── simple_ws.go        # WebSocket 隧道（CONNECT:host:port| → CONNECTED）
│   │   ├── route_dial.go       # 分流拨号（规则命中后选直连 / 走代理）
│   │   ├── tun_geoip.go        # GeoIP 规则匹配
│   │   ├── tun_geosite.go      # Geosite 域名规则匹配
│   │   ├── tun_sniff.go        # 流量嗅探
│   │   ├── tun_direct.go       # 直连通道
│   │   ├── tun_dns.go          # DNS 处理（TUN 下走 DoH，否则交回系统解析器）
│   │   ├── tun_stack.go / tun_route.go / tun_autoaddr.go
│   │   │                       # TUN 协议栈、路由表、虚拟网卡地址分配
│   │   ├── tun_device_windows.go / tun_physiface_windows.go
│   │   │                       # Wintun 网卡读写（含关闭后的句柄安全）与物理网卡绑定
│   │   ├── tun_flags.go / tun_config.go   # TUN 参数与运行时配置
│   │   └── *_test.go           # 单元测试（ECH 降级、DNS 污染、地址解析）
│   ├── tray_manager/           # vendored 托盘插件（含 Windows C++ 实现）
│   └── menu_base/              # vendored 右键菜单插件
├── lib/                        # Flutter 客户端
│   ├── main.dart               # 入口 + 窗口/单例初始化、启动检查
│   ├── models/config.dart      # 配置模型
│   ├── services/
│   │   ├── app_state.dart      # 状态中枢：内核生命周期、更新检查、分流模式
│   │   ├── kernel_manager.dart # 内核进程管理与崩溃恢复
│   │   ├── updater.dart        # 自动更新（检查 / 下载 / 替换 / 重启）
│   │   ├── app_version.dart    # 自报版本号 + isNewer 判定
│   │   ├── config_store.dart   # 配置持久化
│   │   ├── system_proxy.dart   # 系统代理接管 / 还原
│   │   ├── tray_service.dart   # 托盘菜单与交互
│   │   ├── self_check.dart     # 连通性自检
│   │   ├── network_probe.dart  # 网络探测
│   │   ├── log_service.dart    # 日志落盘
│   │   ├── app_paths.dart      # 路径解析（含便携版 %TEMP% 判定）
│   │   ├── port_tools.dart     # 端口冲突检测与占用进程处理
│   │   ├── platform_drivers.dart  # 平台差异适配（含管理员提权重拉）
│   │   ├── instance_guard.dart # 单实例守卫（提权重启时的锁交接）
│   │   └── share_backup.dart   # 服务器分享导出 / 导入
│   └── ui/
│       ├── home_page.dart      # 主界面
│       ├── theme.dart          # 主题与字体（HarmonyOS Sans SC 回退）
│       ├── dialogs.dart        # 通用对话框 / 更新确认框
│       ├── frosted.dart        # 毛玻璃背景组件
│       └── widgets/            # 按钮 / 下拉 / 行 / 输入框等基础控件
├── windows/                    # Windows runner（C++）
│   ├── CMakeLists.txt
│   ├── runner/                 # main.cpp / 窗口 / 资源 / 图标
│   │   └── copy_bundle.cmake   # 构建后把 bundle 内核拷进产物目录（关键钩子）
│   └── flutter/                # 插件注册与 CMake 胶水
├── assets/                     # 图标、Logo、HarmonyOS 字体（三字重共 24MB）
├── installer/                  # 打包
│   ├── EchOS.iss               # Inno Setup 安装版脚本
│   ├── portable-config.txt     # 便携版 7z SFX 配置
│   ├── ChineseSimplified.isl   # 安装界面汉化
│   └── logo.ico
├── docs/releases/v1.1.0.md     # 发版说明（自动作为 Release 正文）
├── docs/                       # 其它文档（Android 适配评估、托盘卡顿分析）
├── screenshot/                 # 界面截图
└── .github/workflows/build-windows.yml   # 打 v* 标签自动构建并发 Release
```

## 本地构建

```powershell
.\build_local.ps1 -Version 1.1.0
```

依次完成「编译内核 → Flutter Release → 安装包 → 便携版」，产物在 `Output/`：

- `EchOS-Win-<版本>-x64-Setup.exe` 安装版
- `EchOS-Win-<版本>-x64-Portable.exe` 便携版（单文件自解压）

### 前置工具

| 工具 | 版本要求 | 用途 |
|---|---|---|
| Flutter | **3.47.4**（与 CI 一致） | 客户端构建；低版本会把 `pubspec.lock` 里的 meta / vector_math 解析回旧组合 |
| Go | ≥ **1.25**（`go.mod` 声明） | 编译内核 |
| Inno Setup 6 | `ISCC.exe` 需在默认路径或 PATH | 安装版打包 |
| 7-Zip | `7z.exe` | 便携版归档（可选，`-SkipPortable` 跳过） |

`wintun.dll`（TUN 模式硬依赖）与 `geoip.dat` / `geosite.dat` 在构建时自动下载到
`windows/bundle/`，不需要手工准备。

### 两个容易踩的坑

1. **内核必须输出到 `windows/bundle/x-tunnel.exe`**。
   `windows/runner/CMakeLists.txt` 挂了 POST_BUILD 钩子，用 `copy_if_different` 把
   `windows/bundle` 下的文件拷进产物目录。只编译到 `third_party/x-tunnel/` 的话，
   flutter build 会用 bundle 里的**旧内核**覆盖产物 —— 代码改了包还是旧的，且不报错。
2. **版本号散落在三处**：`-Version` 参数、`pubspec.yaml` 的 `version`、
   `lib/services/app_version.dart` 的 `defaultValue`。脚本开头有一致性预检：
   三者一致 → 通过；`-Version` 低于 pubspec → 按本地测试包处理，警告后继续；
   其余不一致 → 报错退出（`-AllowVersionMismatch` 可跳过）。
   漏改 `app_version.dart` 会让自报版本高于 Release 标签，自动更新**静默失效**。

## 内核测试

```bash
cd third_party/x-tunnel && go vet ./... && go test ./...
```

用合成 DNS 报文，不依赖网络。覆盖 ECH 降级权（启动可降级、刷新不可降级）、
DNS 污染下的地址优选、TUN 对端地址解析的 nil 安全。

## 运行时数据

| 内容 | 路径 |
|---|---|
| 配置 | `%APPDATA%\EchOS\`（`config.json`） |
| 分流数据 | `%APPDATA%\EchOS\data\`（`geoip.dat` / `geosite.dat`，缺失时回退到打包内副本） |
| 日志 | `%APPDATA%\EchOS\logs\`（`latest.log` / `kernel.log` / `error.log` / `previous.log`） |

排查连接问题时看 `kernel.log`：内核会记录解析到的服务器 IP、两路 DNS 是否一致、
ECH 是否获取成功。

## Worker 部署

```bash
cd worker && ./deploy-worker.sh   # 需 wrangler + Cloudflare 登录
```

## 发布

打 `v*` 标签推送，即自动构建并把上面两个文件发布到 GitHub Release。
也可在 Actions 页面手动触发（填版本号，勾选「发布 Release」才会发布）。

> 标签需为语义化版本（如 `v1.1.0`），版本号会从标签统一注入到应用与产物。
> 应用按「Release 标签版本 > 应用自报版本」判定更新，因此新版本号必须大于已安装版本。
> 发版前请在 `docs/releases/<标签>.md` 写好更新说明，Release 正文会用它；
> 没写也不会报错，只会静默退回成一句 Full Changelog 链接。

## 开源说明

- 本项目基于 MIT 协议开源，详见 [LICENSE](LICENSE)。MIT 允许自由使用、修改与分发，**包含商业用途**，仅要求保留版权与许可声明
- 请遵守所在地区的法律法规；ECH 是加密传输技术，本身无好坏之分，请勿用于任何非法用途
- 分流规则数据 `geoip.dat`、`geosite.dat` 在构建时从上游下载（不随仓库分发），遵循各自上游开源协议
- 本项目不提供任何可用的公共代理服务器，服务端需自行部署（见上文 Cloudflare 部署）

---

## 致谢与来源说明

本项目是面向 Windows平台 的 ECH 加密代理客户端，在多位开源作者的工作基础上适配而来。特别感谢：

- **CCF 大佬**（[@CCF](https://t.me/JPCCF)）—— 客户端开发与整体方案设计，核心能力基于其开源项目 [CF_NAT](https://t.me/CF_NAT) 构建
- **byJoey 大佬** —— 部分实现参考其开源项目 [ech-wk](https://github.com/byJoey/ech-wk)
- **CM 大佬**（[CMLiussss](https://t.me/CMLiussss)）—— 优选 IP 方案参考其维护的 ProxyIP 定制优化

在此基础上定制修改出的 Windows 端专用客户端，让部署到 Cloudflare Workers 后的连接、分流与使用体验更加便捷。

本文涉及的工具与技术方案均来源于：

| 内容 | 来源 |
|---|---|
| 客户端开发 | [CCF](https://t.me/JPCCF) |
| 核心开源项目 | [CF_NAT](https://t.me/CF_NAT) |
| 优选 IP（ProxyIP） | [CMLiussss](https://t.me/CMLiussss) |
| ECH 协议技术 | [Cloudflare 官方文档](https://developers.cloudflare.com/ssl/edge-certificates/ech/) |
| 文档支持 | [Cloudflare-ECH-Workers](https://blog.zrf.me/p/Cloudflare-ECH-Workers) |


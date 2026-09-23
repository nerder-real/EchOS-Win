# EchOS-Win → Android 适配评估

> 本文所有「实测」结论都来自对当前仓库代码的扫描与交叉编译验证；
> 工期数字是**估的，不是算出来的**，我会标明哪些是实测、哪些是判断。
>
> **时效性说明**：本文写于 Windows 版接入 TUN 之前。其中「Win 端 TUN 未接入」
> 的描述已于 2026-09-22 失效（该版本新增「启用 TUN 模式」开关并接入 `-tun`），
> 相关处已就地标注。该变化**不影响**本文关于 Android 的结论。
>
> 代码规模数字已于 **2026-09-23（v1.1.0 前）**重新统计刷新。此时 Win 端 TUN 已
> **真机验证通过**（虚拟网卡建得起来、能上网、关闭不崩溃、系统代理正确让位与恢复），
> 所以第二节「TUN 是能编译还是真跑通过」的疑虑可以划掉 —— 对 Android 移植是加分项：
> TUN 数据路径、DNS 处理、路由这部分的**逻辑**已被真机验证，移植时只需换设备层。

---

## 一、一句话结论

**这不是「换个壳打包」，是换一套网络接管方式。**

Windows 版走的是「内核开本地 SOCKS/HTTP 端口 → 改注册表让系统走这个代理」。
Android **没有全局系统代理**，唯一可行的是 `VpnService`（TUN）。而 TUN 恰好是
内核里唯一 Windows 独占的部分 —— 更微妙的是，**评估时 Windows 版这条通道实现了却一直没接**
（2026-09-22 起已接入「启用 TUN 模式」开关，见第二节末尾的注）。

所以：**UI 能留下 ~85%，网络层要重写。**

---

## 二、摸底：现在这套是怎么跑起来的

```
Flutter UI (8,990 行 Dart)
   │  ① Process.start 起子进程
   ▼
x-tunnel.exe (9,356 行 Go)
   │  ② 开本地监听 socks5://127.0.0.1:30000 + http://127.0.0.1:30001
   ▼
  ③ 写注册表 HKCU\...\Internet Settings\ProxyServer 指向 30001
  ④ 内核经 WebSocket + smux 多路复用连到自研服务端
```

实测确认（`lib/models/config.dart` + `kernel_manager.dart:176`）：
`arguments()` 拼出的完整参数是
`-f -l -default -route -geoip -geosite -token -ip -fallback|-dns|-ech -n -insecure -block -ips`，
TUN 开启时额外追加 `-tun`。

> 评估时此处**没有 `-tun`**，走的是纯系统代理模式。
> 2026-09-22 起 Windows 版新增「启用 TUN 模式」开关，`-tun` 已在 Dart 侧接入；
> 2026-09-23（v1.1.0）**真机验证通过**，不再是「能编译但没跑过」。

**准确的说法是「已实现」，接入与否曾是 App 侧的选择**：

- 内核侧 TUN 是**完整的**：11 个 `//go:build windows` 文件、约 4,711 行，
  能正常编译进 `x-tunnel.exe`；
- `tun_flags.go` 里 `flag.BoolVar(&tunMode, "tun", false, ...)` 默认 false，
  评估时 App 不传 → 永远 false → `x-tunnel.go` 里 7 处 `if tunMode { ... }` 全走不到；
- git 历史佐证：评估时 `-tun` 从未在 Dart 侧出现过；`tunMode` 关键字在全历史里
  **只出现在 `fcc388f`（v1.0.0 基线）**这一个提交中 —— 自引入之日起长期是「编进去但没接」。
  2026-09-22 起接入：`config.dart` 的 `arguments()` 在 TUN 开启时追加 `-tun`。
- 真机验证（v1.1.0）暴露并修掉了三个「编得出来、跑不起来」的问题，都是**设备层无关**
  的通用逻辑坑，Android 移植时同样要避开：
  1. 本地端口监听必须排在「等隧道通道就绪」之前，否则客户端按端口判定启动会误判失败；
  2. TUN 数据路径不能复用本地代理的 smux 连接池，两者是**独立的两条路**；
  3. `wintun.Session` 的方法全是**值接收者**，`End()` 只改了副本，退出时拿着野句柄
     收包会 `0xc0000005`。

**这里的不对称才是关键**：Windows 有两条路可选（系统代理够用，TUN 是可选增强），
Android 只有一条（没有系统代理，`VpnService` 是唯一通道）。所以 Win 端接不接 TUN
**都不改变** Android 的结论 —— Android 依然必须用 TUN，跟 Win 端用不用它无关。
（事实上 Win 端接入 TUN 后，这套代码从「能编译」变成了「真机验证过」，
对 Android 移植只会更有利。）

---

## 三、为什么 Android 不能照搬

| 现在依赖的机制 | Windows | Android |
|---|---|---|
| 全局代理 | 注册表 `ProxyServer` | **不存在**。只能 VpnService(TUN) |
| 内核运行方式 | `Process.start` 起 .exe | **Android 10+ 禁止执行 App 数据目录里的文件**（W^X），必须编成 `.so` 加载 |
| 虚拟网卡 | Wintun 创建适配器 | VpnService 返回一个 **fd**，直接读写 |
| 路由/DNS | winipcfg 改路由表、`GetAdaptersAddresses` 查 DNS | VpnService.Builder 的 `addRoute` / `addDnsServer` |
| 后台常驻 | 托盘图标 | 前台服务 + **系统强制的常驻通知**（不可隐藏） |
| 自启 | 注册表 Run | `BOOT_COMPLETED` 广播（且 VPN 自启仍需用户授权过） |
| 密码存储 | DPAPI（crypt32 FFI） | Android Keystore |
| 单实例 | 本地 TCP + `tasklist` 核 PID | Android 天然单实例，可整块删掉 |
| 更新 | 下载 .exe 静默装 | 下载 APK + 系统安装器（需权限），或走商店 |

**能不能直接换成 sing-box / mihomo 内核？不能。**
实测 `third_party/x-tunnel/simple_ws.go:18-28`：x-tunnel 用的是**自研协议**
（smux 多路复用 + 自研 `CONNECT:host:port|` 握手）。服务端不认标准协议，
换内核等于连服务端一起重做。

---

## 四、复用度：分层拆解

| 层 | 规模 | Android 复用度 | 说明 |
|---|---|---|---|
| 主题 / 组件 / 对话框 | `ui/theme.dart` `ui/widgets/` `ui/dialogs.dart` ~1,100 行 | **~95%** | 纯 Flutter，零平台依赖 |
| 配置模型 / 规则解析 | `models/config.dart` 695 行 | **~95%** | 纯 Dart 数据模型 |
| 主界面 | `ui/home_page.dart` 1,865 行 | **~80%** | 控件全留，**排版要按手机重做** |
| 状态编排 | `services/app_state.dart` 1,529 行 | **~70%** | 逻辑可留，平台调用要换成接口 |
| 隧道传输核心 | `x-tunnel.go` `simple_ws.go` | **~70%** | 跨平台，但要先拆掉 TUN 耦合 |
| 路由 / 规则引擎 | `tun_route.go` `tun_geosite.go` `tun_geoip.go` `tun_sniff.go` | **~90%**（需搬出 Windows 标签） | 逻辑本身跨平台 |
| TUN 设备层 | `tun_device_windows.go` `tun_dns.go` `tun_physiface_windows.go` | **0%** | Wintun → VpnService fd，必须重写 |
| 平台服务 | `system_proxy` `platform_drivers` `tray_service` `updater` `network_probe` `port_tools` | **0%** | 全部 Windows 实现，必须重写 |
| 可复用 | `share_backup.dart`（WebDAV） | **~100%** | 纯 `HttpClient`，跨平台 |

`pubspec.yaml` 的 6 个直接依赖里，**4 个在 Android 上不可用**：
`window_manager`、`screen_retriever`、`tray_manager`、`menu_base`。
（`file_picker` 和 `ffi` 可用。）

---

## 五、内核改造量化（实测）

用 `GOOS=android GOARCH=arm64` 交叉编译，报 **36 个 undefined 符号**。
分三类：

### ① 真·Windows 专属，必须重写（~11 个）

```
StartTun  tunMode(×6)  tunName  tunMTU  chooseTunIPv4Config
setUnicastIF  detectPhysIfaceIndexAPI  isVirtualInterface  getSystemDNSServers
```

### ② 逻辑跨平台，只是被 `//go:build windows` 关住了（~20 个）

```
initRules  routeStr  defaultRouteStr  ruleMode  routeIPStr  routeTCP
RouteDecision  DecisionNone(×4)  DecisionProxy  DecisionDirect  DecisionBlock
defaultRouteDecision  loadGeoIP  loadGeoSite
```

这部分基本是**「移动文件 + 改 build tag」的机械活** —— 是最大的复用红利。

### ③ 依赖替换

`go.mod` 里的 `golang.zx2c4.com/wintun`、`golang.zx2c4.com/wireguard/windows`
必须移除。（`gvisor.dev/gvisor` 的 netstack 本身跨平台，可保留。）

### 一个隐蔽的坑

`route_dial.go` **没有构建标签**（看起来是跨平台的），但它引用了
`tun_flags.go` / `tun_route.go` / `tun_geoip.go` 里的符号 ——
那些文件全是 `//go:build windows`。所以报错全集中在这个文件上。

而 `x-tunnel.go`（3,518 行主文件）里 TUN 启动块和代理服务器逻辑**缠在一起**
（185 / 191 / 258 / 323 / 354 / 380 / 386 / 418 / 1989 行）。
**动手第一件事是抽接口，不是写代码。**

---

## 六、UI 能复原多少

**视觉还原度：~85-90%。控件全都能留，排版要重做。**

### 能 1:1 搬过去的
卡片、渐变芯片标题、玻璃拟态（`frosted.dart`）、日志区、规则编辑器、
胶囊下拉、对话框、按钮、文本框、主题（明/暗）—— 全是标准 Material。

### 必须改的（约 50-80 行代码，但影响观感）

| 位置 | 现在 | Android 要改成 |
|---|---|---|
| `home_page.dart:72-78` `225-226` | `windowManager.getSize/setSize(Size(796, …))` 窗口尺寸联动 | 删掉，改响应式 + 滚动 |
| `home_page.dart:328` `_TitleBar` | 自绘标题栏（居中 LOGO） | Android 有状态栏，去掉或用 `SafeArea` |
| `main.dart:213` | 固定窗口 796×900 | 手机竖屏约 360-430dp 宽 |
| `app_button.dart:38` | `MouseRegion` 悬停效果 | 改长按 / 涟漪 |
| 整体排版 | 服务器/内核/高级/规则/日志**竖排一屏** | 手机放不下，需分页、折叠或 Tab |

**说实话**：796×900 是桌面窗口尺寸，手机宽只有一半左右。
「改几行」改不出来 —— 要**按手机尺寸重新排一遍版**。
这是 UI 侧最花时间的部分，别按「复用 85% 所以很轻松」估。

---

## 七、工作量估算

> ⚠️ 下面是**估的**。按「一个人、熟练 Flutter + Go + Android、含自测」计。

| 阶段 | 内容 | 估时 |
|---|---|---|
| 0 | **可行性验证**：VpnService 拿 fd → Go 读 fd 收发包 → ping 通一个 IP | 3-5 天 |
| 1 | 内核拆分：跨平台逻辑搬出 Windows 标签，抽出 TUN 接口 | 5-8 天 |
| 2 | Android TUN 实现：`tun_device_android.go` + DNS/路由对接 VpnService | 8-12 天 |
| 3 | 内核编成 `.so` + Dart FFI 桥 + VpnService 的 Kotlin 层 | 5-8 天 |
| 4 | Dart 平台抽象：`platform_drivers` 拆双实现，系统代理/自启/密码/更新器 | 5-8 天 |
| 5 | UI 手机适配 | 5-8 天 |
| 6 | 打包/签名/CI（Go 交叉编译 arm64 + Flutter Android）+ 真机测试 | 4-6 天 |

**合计：约 35-55 人天 ≈ 7-11 周**

压缩空间：
- **只做「全局代理」，砍掉分流模式** → 省掉阶段 1、2 的大半 → **约 4-5 周**
  （但 Android 版功能就对不齐 Windows 版了）
- 复用已有 Android 内核库（sing-box `libbox` 那种）→ **不适用**，协议自研（见第三节）

---

## 八、还要注意什么（坑清单）

### VpnService 的硬约束（改不掉，只能接受）

1. **常驻通知不可隐藏** —— 系统强制显示「VPN 已激活」。这是 Android 的设计，不是 bug。
2. **同一时刻只能有一个 VPN** —— 用户开了别的 VPN，EchOS 会被顶掉。
3. **首次要弹系统授权框**（`VpnService.prepare()`），用户拒绝就得降级处理。
4. **前台服务时限** —— Android 14+ 要 `FOREGROUND_SERVICE_SPECIAL_USE`，
   且启动后 10 秒内必须 `startForeground`，否则崩。
5. **后台存活** —— 不引导用户加电池优化白名单，会被系统杀；
   小米 / 华为 / OPPO / vivo 的额外限制更狠，需要逐机型引导页。

### 体积与流量

分流数据 **geoip.dat 16.3 MB + geosite.dat 10.5 MB = 26.8 MB**（实测）。
- 打进 APK → 包体直接 +27 MB
- 首次启动从 GitHub 下载 → 移动网络下体验差，且国内直连 GitHub 不稳
- 建议：**不内置**，改为可选下载 + 国内镜像，或改用精简版规则集

### 分发与合规

- **Google Play**：VPN 类应用有专门政策条款（用途声明、隐私政策、禁止用于广告拦截/流量劫持），上架前要过审
- **国内分发**：需要软著、ICP 备案（自建服务端的话），各商店还要单独适配
- **自签 APK**：最省事，但用户要手动开「允许安装未知来源」，且更新体验差

### 其它

- Go 在 Android 上要显式 `GODEBUG=netdns=go`（用纯 Go resolver，否则拿不到 DNS）
- Go `c-shared` 的 runtime 与 Android 信号处理有冲突风险，`gomobile` 已处理，建议优先走 gomobile
- 更新器要重写：下载 APK + 系统安装器，或干脆「提示去下载」降级
- 首次启动的引导流程（授权 VPN → 加电池白名单 → 选服务器）要重新设计

---

## 九、建议路线（分阶段交付）

不要一口气做完整版。建议：

**里程碑 1（~5 周）：能连上的最小可用版**
- 阶段 0-3：TUN 打通 + 内核 .so + VpnService
- UI 先保留现有排版（手机上能滚动就行），只做「连接/断开 + 服务器选择」
- 只支持**全局代理**，不做分流
- 目标：能日常用，验证网络层是否稳定

**里程碑 2（~3 周）：功能对齐**
- 补分流模式（绕过大陆 / 黑名单 / 全局）+ 自定义规则编辑
- 分流数据下载/更新
- UI 按手机重排

**里程碑 3（~2 周）：打磨与分发**
- 电池白名单引导、机型适配
- 更新器、打包签名、CI
- 真机兼容性测试（Android 8 ~ 15）

---

## 十、需要你拍板的问题

1. **目标形态**：完整对齐 Windows 版（含分流），还是先做「能连上」的最小版？
2. **分发渠道**：Google Play / 国内应用商店 / 只自签分发？——这决定了合规工作量
3. **分流数据**：内置（+27 MB）还是首次下载（国内网络体验）？
4. **是否同时要 iOS**？如果 iOS 也要，阶段 1、2 的接口抽象要一次做对，
   否则要返工（iOS 用 NetworkExtension，比 Android 更严）
5. **谁来写 Android 原生层**（VpnService / Kotlin）？这部分是纯 Android 开发，
   和现有 Windows 技术栈不重叠

---

## 附：本文的实测依据

| 结论 | 依据 |
|---|---|
| 评估时应用不用 TUN 模式 | `kernel_manager.dart:176` 的启动参数 + `config.dart` 的 `arguments()`，评估时无 `-tun`（2026-09-22 起已接入，v1.1.0 真机验证通过） |
| TUN 是 Windows 独占 | 13 个 `tun_*.go` 全带 `//go:build windows` |
| 跨平台编译缺 36 个符号 | `GOOS=android GOARCH=arm64 go build` 实测 |
| `route_dial.go` 耦合 Windows | 编译报错全部落在该文件 |
| 协议自研、换不了内核 | `simple_ws.go:18-28` 的协议说明 |
| 分流数据 26.8 MB | `windows/bundle/*.dat` 实测 |
| UI 依赖 4 个桌面库 | `pubspec.yaml` + `grep window_manager\|tray_manager\|screen_retriever\|menu_base` |
| 窗口固定 796×900 | `main.dart:213` `WindowOptions(size: Size(796, 900))` |

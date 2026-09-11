; EchOS Windows 安装器（Inno Setup）
; 版本号经预处理器定义注入：ISCC.exe installer/EchOS.iss /DAPP_VERSION=<tag>（CI 传 github.ref_name）
#define MyAppName "EchOS"
#ifndef APP_VERSION
#  define MyAppVersion "0.1.0"
#else
#  define MyAppVersion APP_VERSION
#endif
#define MyAppExeName "echos.exe"

[Setup]
AppId={{40D4E6C1-7A3B-4F0E-9C5A-8B2E6E9D4C10}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
DefaultDirName={autopf}\EchOS
DefaultGroupName=EchOS
OutputDir=..\Output
OutputBaseFilename=EchOS-Win-{#MyAppVersion}-x64-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
SetupIconFile=logo.ico
; 默认 auto：若已安装过则隐藏「选择安装位置」页，导致无法改路径；强制始终显示
DisableDirPage=no
; 默认 yes：升级/重装时路径页预填上次安装目录；用户仍可改新路径，卸载时新旧目录都会清理
UsePreviousAppDir=yes
; 运行中的应用由自身检测：安装器「正在运行的应用」页勾选（或静默安装）时写入
; 授权标记 %TEMP%\EchOS_Install_Go.marker，应用读到后先杀内核进程再自动退出
; (exit 0)；用户在该页/向导取消则应用保持运行。不用 AppMutex 弹「请先关闭」
; 阻塞安装，也不用 Restart Manager 的 Auto close（应用关闭按钮是隐藏到托盘，
; RM 等待退出会一直卡住）。
; 自动更新由应用先 exit(0) 再静默安装，应用退出即释放文件锁，不受影响。
CloseApplications=no
; 每次安装都写 %TEMP%\Setup Log*.txt，便于诊断 x-tunnel 等文件替换失败。
SetupLogging=yes

[Languages]
; 官方发行版自带 ChineseSimplified.isl，但部分精简安装（本机就是）没有，
; 因此随仓库携带一份，保证本地与 CI 都能稳定编译。单语言不会弹语言选择框。
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall

[Code]
// —— 「正在运行的应用」页：二选一 ——
// 选项一「自动退出 EchOS 并继续安装」（默认）→ 点「下一步」时写入授权标记，
//   应用读到后先还原代理、停内核再退出，安装继续；
// 选项二「退出安装」→ 直接关闭安装向导，EchOS 保持运行，用户手动退出后重跑
//   安装程序即可。不能让未关闭应用的情况直接走到安装步骤，否则替换
//   echos.exe / x-tunnel.exe 时必然撞上文件占用（DeleteFile code 5）。
// 静默安装（/SILENT /VERYSILENT）跳过该页，视为已选选项一，直接写授权标记。
var
  GoMarkerPath: string;
  GoPage: TWizardPage;
  OptAutoExit: TNewRadioButton;
  OptQuitSetup: TNewRadioButton;
  HeadText: TNewStaticText;
  HintAutoExit: TNewStaticText;
  HintQuitSetup: TNewStaticText;
  ForceExit: Boolean;

const
  GoMarkerFileName = 'EchOS_Install_Go.marker';

// 应用存活时持有互斥体 Local\EchOS_App_Install（main.dart CreateMutexW），
// 仅在探到该互斥体时显示本页；应用未运行则整页跳过。
function AppRunning: Boolean;
begin
  Result := CheckForMutexes('EchOS_App_Install');
end;

// 两个单选按钮互斥。VCL 的 TRadioButton 原本会自动互斥（同一父控件下
// GroupIndex 相同），这里再显式同步一次兜底；程序化赋值 Checked 不会触发
// OnClick，因此不会递归。
procedure OptAutoExitClick(Sender: TObject);
begin
  OptQuitSetup.Checked := not OptAutoExit.Checked;
end;

procedure OptQuitSetupClick(Sender: TObject);
begin
  OptAutoExit.Checked := not OptQuitSetup.Checked;
end;

procedure InitializeWizard;
var
  Indent: Integer;      // 说明文字相对单选按钮的缩进
  HintWidth: Integer;
begin
  GoMarkerPath := AddBackslash(GetTempDir) + GoMarkerFileName;
  // 标题与副标题都留空：向导自带的标题「正在运行的应用」已删除，改用页面内
  // 自绘的大号居中提示行，方便控制字号、对齐和上下边距。
  GoPage := CreateCustomPage(wpWelcome, '', '');
  // 窗口标题栏默认是「Setup - EchOS version v1.0.1」——来自 Default.isl 的
  // SetupWindowTitle=Setup - %1，纯默认消息、非必需，这里换成中文版本化标题。
  // {#MyAppVersion} 由 ISCC /DAPP_VERSION= 注入，与安装包文件名保持一致。
  WizardForm.Caption := 'EchOS {#MyAppVersion} 安装程序';
  Indent := ScaleX(20);
  HintWidth := GoPage.SurfaceWidth - Indent;

  // 顶部居中提示（放大 + 上下留边距）
  HeadText := TNewStaticText.Create(GoPage);
  HeadText.Parent := GoPage.Surface;
  HeadText.AutoSize := True;
  // 字号：向导默认正文 8pt → 12pt 为一档放大，此处再放大 1.5 倍到 18pt
  HeadText.Font.Size := 18;
  HeadText.Font.Style := [fsBold];
  HeadText.Caption := '检测到程序 EchOS 正在运行';
  // AutoSize 下 Caption 赋完 Width 即为文字宽度，据此算居中位置
  HeadText.Left := (GoPage.SurfaceWidth - HeadText.Width) div 2;
  HeadText.Top := ScaleY(0);

  // 选项一
  OptAutoExit := TNewRadioButton.Create(GoPage);
  OptAutoExit.Parent := GoPage.Surface;
  OptAutoExit.Left := ScaleX(0);
  // 与上方提示行的间距（选项一的上边距）
  OptAutoExit.Top := HeadText.Top + HeadText.Height + ScaleY(50);
  OptAutoExit.Width := GoPage.SurfaceWidth;
  OptAutoExit.Height := ScaleY(22);
  // 向导默认正文 8pt，选项文字提一档到 10pt，与 8pt 的灰色说明形成层级
  OptAutoExit.Font.Size := 10;
  OptAutoExit.Checked := True;
  OptAutoExit.OnClick := @OptAutoExitClick;
  OptAutoExit.Caption := '自动退出 EchOS 并继续安装（推荐）';

  HintAutoExit := TNewStaticText.Create(GoPage);
  HintAutoExit.Parent := GoPage.Surface;
  HintAutoExit.Left := Indent;
  HintAutoExit.Top := OptAutoExit.Top + OptAutoExit.Height + ScaleY(5);
  HintAutoExit.Width := HintWidth;
  HintAutoExit.WordWrap := True;
  HintAutoExit.AutoSize := True;
  HintAutoExit.Font.Color := $00666666;  // 比选项文字淡一档，形成主次层级
  HintAutoExit.Caption :=
    '安装程序会通知 EchOS 先还原系统代理设置、停止内核进程，再安全退出，' +
    '随后继续安装，无需手动操作。';

  // 选项二（与上一组之间留空，避免两段文字挤在一起）
  OptQuitSetup := TNewRadioButton.Create(GoPage);
  OptQuitSetup.Parent := GoPage.Surface;
  OptQuitSetup.Left := ScaleX(0);
  OptQuitSetup.Top := HintAutoExit.Top + HintAutoExit.Height + ScaleY(30);
  OptQuitSetup.Width := GoPage.SurfaceWidth;
  OptQuitSetup.Height := ScaleY(22);
  OptQuitSetup.Font.Size := 10;
  OptQuitSetup.Checked := False;
  OptQuitSetup.OnClick := @OptQuitSetupClick;
  OptQuitSetup.Caption := '退出安装（自行退出 EchOS，稍后再运行安装程序）';

  HintQuitSetup := TNewStaticText.Create(GoPage);
  HintQuitSetup.Parent := GoPage.Surface;
  HintQuitSetup.Left := Indent;
  HintQuitSetup.Top := OptQuitSetup.Top + OptQuitSetup.Height + ScaleY(5);
  HintQuitSetup.Width := HintWidth;
  HintQuitSetup.WordWrap := True;
  HintQuitSetup.AutoSize := True;
  HintQuitSetup.Font.Color := $00666666;  // 同上，与选项文字区分层级
  HintQuitSetup.Caption :=
    '立即结束本次安装，EchOS 保持运行。手动退出 EchOS 后重新运行安装程序即可。';
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if (PageID = GoPage.ID) and not AppRunning then
    Result := True;
end;

// 用户点「下一步」离页时按选项处理：选「自动退出」→ 写授权标记并轮询等待应用
// 退出（应用持有互斥体 Local\EchOS_App_Install，读到标记后会杀内核进程再退出），
// 最多等约 15 秒，给应用清理 x-tunnel 留足时间，避免文件替换撞上进程占用；
// 选「退出安装」→ 发 WM_CLOSE 关闭向导，由 CancelButtonClick 免确认直接退出。
function NextButtonClick(CurPageID: Integer): Boolean;
var
  i: Integer;
begin
  Result := True;
  if CurPageID = GoPage.ID then begin
    if OptAutoExit.Checked then begin
      SaveStringToFile(GoMarkerPath, '1', False);
      for i := 0 to 74 do begin
        if not CheckForMutexes('EchOS_App_Install') then
          Break;
        Sleep(200);
      end;
    end else begin
      // 退出安装：确保不留授权标记，EchOS 保持运行
      if FileExists(GoMarkerPath) then
        DeleteFile(GoMarkerPath);
      ForceExit := True;
      PostMessage(WizardForm.Handle, 16, 0, 0);  { WM_CLOSE，异步，等本函数返回后才处理 }
      Result := False;  { 不翻页 }
    end;
  end;
end;

// 选了「退出安装」时不弹「确定要取消安装吗？」确认框——用户已经显式选过一次了。
procedure CancelButtonClick(CurPageID: Integer; var Cancel, Confirm: Boolean);
begin
  if ForceExit then
    Confirm := False;
end;

// 卸载/安装在替换 x-tunnel.exe 前，无论来源（游离内核/旧版进程/崩溃残留）都
// 无条件清一次：该文件和 exe 一样会被覆盖，进程占用即 DeleteFile code5。
// 正常流程（应用在跑+已授权）此刻互斥体已释放，这里只是兜底补刀。
procedure CurStepChanged(CurStep: TSetupStep);
var
  rc: Integer;
begin
  if CurStep = ssInstall then begin
    Exec('taskkill.exe', '/IM x-tunnel.exe /F', '', SW_HIDE,
        ewWaitUntilTerminated, rc);
    if WizardSilent then
      SaveStringToFile(GoMarkerPath, '1', False);
  end;
end;

procedure DeinitializeSetup;
begin
  if FileExists(GoMarkerPath) then
    DeleteFile(GoMarkerPath);
end;

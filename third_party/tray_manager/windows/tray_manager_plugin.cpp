#include "include/tray_manager/tray_manager_plugin.h"

// This must be included before many other Windows headers.
#include <stdio.h>
#include <windows.h>

#include <shellapi.h>
#include <strsafe.h>

#include <shobjidl.h>
#include <gdiplus.h>
#pragma comment(lib, "gdiplus.lib")

#include <dwmapi.h>
#include <uxtheme.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cmath>
#include <codecvt>
#include <map>
#include <memory>
#include <sstream>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#define WM_MYMESSAGE (WM_USER + 1)

namespace {

// GDI+ globals (lifetime = plugin). Used to soft-rasterize the panel's
// rounded silhouette - SetWindowRgn always leaves a 1-pixel hard cut
// at the region boundary, and DWM's high-quality composition path
// (LWA_COLORKEY) does not help for #32768 menu windows. Gdiplus is a
// system DLL (already linked via pragma in the header block).
ULONG_PTR g_gdiplus_token = 0;
bool g_gdiplus_ready = false;

const int kPanelCornerRadius = 13;

// One menu row's render data for the self-drawn curtain panel (see
// OverlayRender below). rc is the row's rect in CLIENT coordinates; the
// curtain offsets it by kOverlayMargin plus the 8px NCALCSIZE top band.
struct CurtainRow {
  RECT rc = {0, 0, 0, 0};
  bool separator = false;
  bool checked = false;
  bool disabled = false;
  bool selected = false;
  bool popup = false;
  std::wstring label;
};

const flutter::EncodableValue* ValueOrNull(const flutter::EncodableMap& map,
                                           const char* key) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) {
    return nullptr;
  }
  return &(it->second);
}

std::unique_ptr<
    flutter::MethodChannel<flutter::EncodableValue>,
    std::default_delete<flutter::MethodChannel<flutter::EncodableValue>>>
    channel = nullptr;

class TrayManagerPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  TrayManagerPlugin(flutter::PluginRegistrarWindows* registrar);

  virtual ~TrayManagerPlugin();

 private:
  std::wstring_convert<std::codecvt_utf8_utf16<wchar_t>> g_converter;

  flutter::PluginRegistrarWindows* registrar;
  NOTIFYICONDATA nid;
  NOTIFYICONIDENTIFIER niif;
  HMENU hMenu;
  bool tray_icon_setted = false;

  // The ID of the WindowProc delegate registration.
  int window_proc_id = -1;

  void TrayManagerPlugin::_CreateMenu(
    HMENU menu, flutter::EncodableMap args, bool in_submenu,
    std::unordered_map<UINT_PTR, std::wstring>& item_labels_map,
    std::unordered_set<UINT_PTR>& separator_ids_set,
    std::unordered_set<UINT_PTR>& submenu_item_ids_set,
    std::unordered_map<UINT_PTR, UINT_PTR>& popup_ids_map);

  // Called for top-level WindowProc delegation.
  std::optional<LRESULT> TrayManagerPlugin::HandleWindowProc(HWND hwnd,
                                                             UINT message,
                                                             WPARAM wparam,
                                                             LPARAM lparam);
  HWND TrayManagerPlugin::GetMainWindow();
  bool TrayManagerPlugin::IsDarkTheme();
  std::optional<LRESULT> TrayManagerPlugin::HandleMeasureItem(LPARAM lparam);
  std::optional<LRESULT> TrayManagerPlugin::HandleDrawItem(LPARAM lparam);
 public:
  bool TrayManagerPlugin::CollectMenuView(HMENU menu,
                                          std::vector<CurtainRow>& out);
  void TrayManagerPlugin::RefreshCurtains(HWND sheet);
  size_t TrayManagerPlugin::LabelCount() const { return item_labels_.size(); }
 private:
  int TrayManagerPlugin::ComputeMenuWidth();
  void TrayManagerPlugin::Destroy(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void TrayManagerPlugin::SetIcon(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void TrayManagerPlugin::SetToolTip(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void TrayManagerPlugin::SetContextMenu(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  // Shows the tray context menu at the current cursor position. Shared by the
  // Dart-facing popUpContextMenu method and the native right-click handler, so
  // a right-click does not need a round trip through Dart to open the menu.
  void TrayManagerPlugin::ShowContextMenuNow();
  void TrayManagerPlugin::PopUpContextMenu(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void TrayManagerPlugin::GetBounds(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void TrayManagerPlugin::SetDockIconVisible(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  bool TrayManagerPlugin::ResolveMenuItem(HMENU menu, UINT_PTR item_id,
                                          bool* is_separator, bool* is_popup,
                                          const wchar_t** text);
  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Owner-draw menu label texts, kept alive per menu item id. AppendMenu only
  // stores the pointer for MF_OWNERDRAW items (no copy), so feeding it the
  // c_str() of a temporary std::wstring would dangle; storing them here keeps
  // the lifetime under the plugin's control.
  std::unordered_map<UINT_PTR, std::wstring> item_labels_;
  // Submenu handle -> Dart item id, used to identify MF_POPUP rows in
  // WM_DRAWITEM (their wID is not the Dart id).
  std::unordered_map<UINT_PTR, UINT_PTR> popup_ids_;
  // Ids of rows built inside submenus: they get their own tighter width
  // (server names) instead of the main menu's width.
  std::unordered_set<UINT_PTR> submenu_item_ids_;
  int submenu_item_width_ = 150;

  // Width for owner-drawn rows, recomputed from the longest label before each
  // popup so the menu hugs its content instead of a fixed 236px slab.
  int menu_item_width_ = 176;
  // RegisterWindowMessage("TaskbarCreated"): explorer broadcasts this when it
  // restarts; without re-adding, the tray icon disappears silently.
  UINT taskbar_created_msg_ = 0;
  // Menu item ids that are separators: WM_MEASUREITEM uses itemID to give the
  // separator slot a shorter height.
  std::unordered_set<UINT_PTR> separator_ids_;
};

// The single plugin instance; the free-function curtain renderer reaches the
// menu data through this pointer.
static TrayManagerPlugin* g_self = nullptr;

// static
void TrayManagerPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  // Start GDI+ once for the lifetime of the plugin. We use it to
  // soft-rasterize the menu's rounded silhouette into a 32-bit ARGB
  // surface - SetWindowRgn always leaves a 1-pixel hard cut at the
  // region boundary, which is what the user has been seeing as
  // "mosaic" on every LAYERED-based attempt.
  if (!g_gdiplus_ready) {
    Gdiplus::GdiplusStartupInput si;
    if (Gdiplus::GdiplusStartup(&g_gdiplus_token, &si, nullptr) ==
        Gdiplus::Ok) {
      g_gdiplus_ready = true;
    }
  }

  channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "tray_manager",
      &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<TrayManagerPlugin>(registrar);

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

TrayManagerPlugin::TrayManagerPlugin(flutter::PluginRegistrarWindows* registrar)
    : registrar(registrar) {
  g_self = this;
  window_proc_id = registrar->RegisterTopLevelWindowProcDelegate(
      [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
        return HandleWindowProc(hwnd, message, wparam, lparam);
      });
  taskbar_created_msg_ = ::RegisterWindowMessageW(L"TaskbarCreated");
}

TrayManagerPlugin::~TrayManagerPlugin() {
  g_self = nullptr;
  registrar->UnregisterTopLevelWindowProcDelegate(window_proc_id);
}

void TrayManagerPlugin::_CreateMenu(
    HMENU menu, flutter::EncodableMap args, bool in_submenu,
    std::unordered_map<UINT_PTR, std::wstring>& item_labels_map,
    std::unordered_set<UINT_PTR>& separator_ids_set,
    std::unordered_set<UINT_PTR>& submenu_item_ids_set,
    std::unordered_map<UINT_PTR, UINT_PTR>& popup_ids_map) {
  flutter::EncodableList items = std::get<flutter::EncodableList>(
      args.at(flutter::EncodableValue("items")));

  int count = GetMenuItemCount(menu);
  for (int i = 0; i < count; i++) {
    // always remove at 0 because they shift every time
    RemoveMenu(menu, 0, MF_BYPOSITION);
  }

  for (flutter::EncodableValue item_value : items) {
    flutter::EncodableMap item_map =
        std::get<flutter::EncodableMap>(item_value);
    int id = std::get<int>(item_map.at(flutter::EncodableValue("id")));
    std::string type =
        std::get<std::string>(item_map.at(flutter::EncodableValue("type")));
    std::string label =
        std::get<std::string>(item_map.at(flutter::EncodableValue("label")));
    auto* checked = std::get_if<bool>(ValueOrNull(item_map, "checked"));
    bool disabled =
        std::get<bool>(item_map.at(flutter::EncodableValue("disabled")));

    UINT_PTR item_id = id;
    UINT uFlags = MF_STRING;

    if (disabled) {
      uFlags |= MF_GRAYED;
    }

    if (type.compare("separator") == 0) {
      // Owner-draw separators too so they follow the menu theme.
      separator_ids_set.insert(item_id);
      item_labels_map.erase(item_id);
      if (in_submenu) submenu_item_ids_set.insert(item_id);
      AppendMenuW(menu, MF_SEPARATOR | MF_OWNERDRAW, item_id, NULL);
    } else {
      bool is_submenu_item = false;
      HMENU sub_menu = nullptr;
      if (type.compare("checkbox") == 0 && checked != nullptr) {
        uFlags |= (*checked ? MF_CHECKED : MF_UNCHECKED);
      } else if (type.compare("submenu") == 0) {
        // MF_POPUP + OWNERDRAW: the menu manager paints a right-side
        // submenu arrow on MFT_POPUP owner-draw rows (we accept the
        // arrow visually), and a sub-menu handle in the wID slot
        // routes TrackPopupMenu-style navigation through the OS, so
        // hover on this row pops the attached submenu.
        uFlags |= MF_POPUP;
        sub_menu = ::CreatePopupMenu();
        _CreateMenu(sub_menu,
                    std::get<flutter::EncodableMap>(
                        item_map.at(flutter::EncodableValue("submenu"))),
                    true, item_labels_map, separator_ids_set,
                    submenu_item_ids_set, popup_ids_map);
        is_submenu_item = true;
      } else if (checked != nullptr && *checked) {
        // normal item with selection mark (server list) -> native checkmark
        uFlags |= MF_CHECKED;
      }
      // Owner-draw label text outlives AppendMenu (stable container; no
      // dangling pointer). wID keeps the Dart item_id: it drives WM_COMMAND
      // and the label lookup used by WM_DRAWITEM.
      separator_ids_set.erase(item_id);
      item_labels_map[item_id] = g_converter.from_bytes(label);
      if (in_submenu) submenu_item_ids_set.insert(item_id);
      if (is_submenu_item) {
        // MF_POPUP takes the submenu handle in the uIDNewItem slot; passing
        // it there AND as owner-draw data keeps the item drawable while the
        // submenu actually attaches. The system paints a right-side
        // submenu arrow on MFT_POPUP rows - we accept that here (no clean
        // way to suppress it from user code, the leading dot is the
        // primary affordance).
        popup_ids_map[(UINT_PTR)sub_menu] = item_id;
        AppendMenuW(menu, uFlags | MF_OWNERDRAW, (UINT_PTR)sub_menu,
                    (LPCWSTR)sub_menu);
      } else {
        AppendMenuW(menu, uFlags | MF_OWNERDRAW, item_id, NULL);
      }
    }
  }
}

std::optional<LRESULT> TrayManagerPlugin::HandleWindowProc(HWND hWnd,
                                                           UINT message,
                                                           WPARAM wParam,
                                                           LPARAM lParam) {
  std::optional<LRESULT> result;
  if (message == WM_DESTROY) {
    if (tray_icon_setted) {
      Shell_NotifyIcon(NIM_DELETE, &nid);
      DestroyIcon(nid.hIcon);
    }
  } else if (message == WM_COMMAND) {
    flutter::EncodableMap eventData = flutter::EncodableMap();
    eventData[flutter::EncodableValue("id")] =
        flutter::EncodableValue((int)wParam);

    channel->InvokeMethod("onTrayMenuItemClick",
                          std::make_unique<flutter::EncodableValue>(eventData));
  } else if (message == WM_MEASUREITEM) {
    result = HandleMeasureItem(lParam);
  } else if (message == WM_DRAWITEM) {
    result = HandleDrawItem(lParam);
  } else if (message == taskbar_created_msg_ && taskbar_created_msg_ != 0) {
    // Explorer restarted and broadcast TaskbarCreated: re-add the tray icon,
    // otherwise it silently disappears for the rest of the session.
    if (tray_icon_setted) {
      Shell_NotifyIcon(NIM_ADD, &nid);
    }
  } else if (message == WM_MYMESSAGE) {
    switch (lParam) {
      case WM_LBUTTONUP:
        channel->InvokeMethod(
            "onTrayIconMouseDown",
            std::make_unique<flutter::EncodableValue>());
        break;
      case WM_RBUTTONUP:
        // Pop the menu straight from the native tray message. Routing this
        // through Dart (invokeMethod -> TrayListener -> popUpContextMenu) added
        // a full platform-channel round trip to every right-click, which is
        // what made the menu feel slow to appear.
        ShowContextMenuNow();
        break;
      default:
        return DefWindowProc(hWnd, message, wParam, lParam);
    };
  }
  return result;
}

HWND TrayManagerPlugin::GetMainWindow() {
  return ::GetAncestor(registrar->GetView()->GetNativeWindow(), GA_ROOT);
}

// Theming matches the app's ThemeMode.system: read the OS light/dark setting.
bool TrayManagerPlugin::IsDarkTheme() {
  DWORD value = 1;
  DWORD size = sizeof(value);
  LSTATUS st = ::RegGetValueW(
      HKEY_CURRENT_USER,
      L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
      L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &value, &size);
  if (st != ERROR_SUCCESS) return false;
  return value == 0;
}

// Resolves which menu item a MEASURE/DRAW call refers to. Popup (submenu) items
// match by their submenu handle; separators and string items match by wID, with
// the label text looked up from item_labels_ (stable storage owned by the
// plugin). MEASURE can also use itemID directly for height decisions.
bool TrayManagerPlugin::ResolveMenuItem(HMENU menu, UINT_PTR item_id,
                                        bool* is_separator, bool* is_popup,
                                        const wchar_t** text) {
  *is_separator = false;
  *is_popup = false;
  *text = nullptr;
  int count = ::GetMenuItemCount(menu);
  for (int i = 0; i < count; i++) {
    MENUITEMINFO mii = {};
    mii.cbSize = sizeof(MENUITEMINFO);
    mii.fMask = MIIM_ID | MIIM_FTYPE | MIIM_SUBMENU;
    if (!::GetMenuItemInfo(menu, i, TRUE, &mii)) continue;
    if (mii.wID != item_id) continue;
    if (mii.hSubMenu != nullptr) {
      *is_popup = true;
      auto it = item_labels_.find(item_id);
      if (it != item_labels_.end()) {
        *text = it->second.c_str();
      }
      return true;
    }
    if (mii.fType & MFT_SEPARATOR) {
      *is_separator = true;
      return true;
    }    auto it = item_labels_.find(item_id);
    if (it != item_labels_.end()) {
      *text = it->second.c_str();
    }
    return true;
  }
  return false;
}

COLORREF BlendFor(bool is_dark, COLORREF light, COLORREF dark) {
  return is_dark ? dark : light;
}

// MF_OWNERDRAW paints only the item rows: the menu window's own margin is
// still filled by the system with COLOR_MENU, and DWM adds a bright 1px
// frame, so a dark menu keeps a white outline. Paint the window background
// with a matching brush via SetMenuInfo, and use a thread hook to strip the
// DWM border the moment the menu window (#32768) is created.
// (Keep comments ASCII-only here: this file is compiled without /utf-8 and
// multi-byte comments corrupt line parsing.)
static HHOOK g_menu_cbt_hook = nullptr;
static bool g_menu_is_dark = false;
// Actual MIM_BACKGROUND brush color handed to SetMenuInfo for the current
// popup run. The AA corner overlay must tint its band with EXACTLY this color
// (not a guess from the OS theme) so the feathered edge vanishes into the
// panel instead of painting a visible "phone-case bumper" ring at the corner.
static COLORREF g_menu_bg = RGB(0xFF, 0xFF, 0xFF);
static WNDPROC g_menu_base_proc = nullptr;
static HWND g_pad_hwnd = nullptr;
static int g_pad_cx = 0;
static int g_pad_cy = 0;
static HWND g_anchor_hwnd = nullptr;
// Popup anchor. The panel opens to the LEFT of the cursor by default (Windows
// tray convention: the tray lives in the screen's bottom-right corner, so a
// panel opening rightward would immediately run off-screen). g_anchor_left is
// therefore the panel's RIGHT edge, and the top-left is recovered by
// subtracting the pinned width. When there is no room on the left the panel
// flips to open rightward instead; g_anchor_stick_left then records that
// g_anchor_left should be read as the LEFT edge directly.
// g_anchor_valid is kept separate because the cursor may legitimately sit at 0
// or on a monitor with negative coordinates, where a "> 0" test would fail.
static int g_anchor_top = -1;
static int g_anchor_left = -1;
static bool g_anchor_stick_left = false;
static bool g_anchor_valid = false;
// Cached client-area widths for the current popup run, captured at
// WINDOWPOSCHANGED. dis->hwndItem during DrawItem is an HMENU (not the
// window), so we cannot GetClientRect on it - this cache is the only
// source of truth for the row's right edge.
static int g_sheet_cl = 0;
static int g_sub_sheet_cl = 0;
// Popup row rect (client coords) PER HWND. The system redraws its submenu
// arrow on every full paint and every per-row repaint of an MF_POPUP row, so
// drawn by the manager after our owner-draw paint. The leading dot is the
// only intended mark; the residual 4-pixel tip is the visible reminder of
// "this row has a submenu", which the task is acceptable for.
  // No-op: the cover-arrow mechanism (paint a panel-color strip over
// the system submenu arrow) was disabled because the system never
// drew that arrow on owner-draw popup rows anyway, and the strip
// kept racing the pill rectangle and showing up as a residual blue
// band on the right edge. We now rely on the leading dot as the
// submenu's only mark, and accept whatever the system may show.
// Root HMENU of the current popup run: lets WM_DRAWITEM tell which sheet an
// item belongs to (anchor vs. submenu) so rows stretch to their own sheet's
// real client width instead of the narrower text-template width.
static HMENU g_anchor_hmenu = nullptr;
// Per-window size for the submenu sheet: the system sizes and places submenus
// itself, and a single shared height would let the submenu bleed into the
// anchor's layout. Track the submenu separately so it gets its own pinned
// width/height and stacks flush-left against the main panel.
static HWND g_sub_hwnd = nullptr;
static int g_sub_cx = 0;
static int g_sub_cy = 0;
// Screen work area (of the tray monitor) cached at popup time, used to clamp
// the submenu: it opens to the RIGHT of the main panel by default and flips
// to the left only when the right side of the screen cannot fit the sheet.
static int g_work_left = 0;
static int g_work_right = 0;
// Region cache: SetWindowRgn forces a full repaint of the sheet, so re-applying
// it on EVERY sizing pass restarts the WM_DRAWITEM + arrow-redraw dance and
// made the panels flicker and the popup row flash. Apply it only when a
// window's size actually changed since the last application.
static HWND g_rgn_last_hwnd = nullptr;
static int g_rgn_last_cx = 0;
static int g_rgn_last_cy = 0;
// Self-drawn curtain panel state (per popup run):
static HMENU g_sub_hmenu = nullptr;              // submenu HMENU, learnt from
                                                 // DrawItem / lexed at sub sheet
static std::unordered_map<HMENU, UINT_PTR> g_sel_key;    // per-sheet selection key
static std::unordered_map<HMENU, std::vector<RECT>> g_row_rects;  // real row rects

// Rounds the sheet corners by clipping the window to a rounded region. The
// region is re-created on every sizing pass so it always matches the window's
// FINAL size: the menu manager re-sizes windows as it finishes measuring
// No-op: the panel is a sharp rectangle. SetWindowRgn + LAYERED always
// leaves a 1-pixel hard cut at the region mask boundary, which DWM
// cannot soften for #32768 menu windows (the GDI+ path round-trip we
// tried before needs a hook that menus never give us - DrawItem only
// hands us a per-row DC, WM_PAINT is never delivered to the subclass
// for #32768). Sharp rectangle = 0 pixel staircase.
static void ApplyRoundedRegion(HWND hwnd, int w, int h) {
  // 1-bit clip mask keeps the sheet's clipped area inside the rounded shape
  // (system keeps painting its square background otherwise). The mask edge is
  // intentionally NOT the final visual edge: a layered overlay on top
  // re-rasterizes the same rounded path with GDI+ anti-aliasing at per-pixel
  // alpha, so the stair-step cut of this mask is blended away behind it.
  if (w <= 0 || h <= 0) return;
  ::SetWindowRgn(hwnd, nullptr, FALSE);  // drop any stale region
  HRGN rgn = ::CreateRoundRectRgn(0, 0, w, h, kPanelCornerRadius * 2,
                                  kPanelCornerRadius * 2);
  if (rgn != nullptr) ::SetWindowRgn(hwnd, rgn, TRUE);
}

// ---- Anti-aliased corner overlay -------------------------------------------
// The menu sheet keeps its rectangular window + 1-bit region clip (above) for
// INPUT: the system menu code must see an ordinary #32768 window. The region
// mask leaves a stair-step edge at the rounded boundary. To get the pill's
// GDI+ smoothing on the PANEL's outer silhouette we float a second, fully
// click-through layered window over the sheet (margin 4px on every side) and
// render ONLY the rounded-outline band into it with GDI+ at per-pixel alpha.
// UpdateLayeredWindow composites that bitmap with DWM, so the band's alpha
// feather smooths the region's staircase: inside the outline the overlay is
// transparent (the sheet's own bg/text below stays visible), the 4px band
// carries alpha=255 menu-color, and beyond it alpha falls to 0 over the
// desktop. This is the same GraphicsPath used by the hover pill.
const wchar_t kOverlayClass[] = L"EchOS.MenuOverlayAA";
const wchar_t kOverlayProp[] = L"EchOS.MenuOverlayAA";
// The curtain is drawn at EXACTLY the sheet's rect (zero margin). The rounded
// corner AA feathers INWARD only, so the plugin never writes a single pixel
// outside the panel - no translucent ring, no white edge on light desktops,
// no shadow. The solid body covers the whole sheet and the corner arc is
// smoothed by the supersampled SDF below.
const int kOverlayMargin = 0;

LRESULT CALLBACK MenuOverlayProc(HWND hwnd, UINT message, WPARAM wparam,
                                 LPARAM lparam) {
  if (message == WM_NCHITTEST) return HTTRANSPARENT;
  return ::DefWindowProcW(hwnd, message, wparam, lparam);
}

static void EnsureOverlayClass() {
  static bool ready = false;
  if (ready) return;
  WNDCLASSEXW wc = {};
  wc.cbSize = sizeof(wc);
  wc.lpfnWndProc = MenuOverlayProc;
  wc.hInstance = ::GetModuleHandleW(nullptr);
  wc.lpszClassName = kOverlayClass;
  // Already registered (same process): treat as ready.
  if (::RegisterClassExW(&wc) != 0 ||
      ::GetLastError() == ERROR_CLASS_ALREADY_EXISTS)
    ready = true;
}

// Self-drawn curtain panel: render the WHOLE menu (background, hover pill,
// marks, labels) into a 32bpp DIB at per-pixel alpha and push it with
// UpdateLayeredWindow over the sheet's screen rect.
//
// The native #32768 sheet is kept only as a behavior proxy: it is layered at
// LWA_ALPHA=1 (composited at ~0% so it never shows, its DWM shadow never
// forms) and still owns hover/click/keyboard/submenu tracking. This curtain is
// WS_EX_TRANSPARENT, so every mouse message passes through to that proxy
// sheet; on each WM_DRAWITEM the plugin reflects the sheet's selection into
// g_sel_key and re-renders here. Because the whole panel is per-pixel alpha on
// a layered window there is no SetWindowRgn staircase, no DWM dark material,
// no shadow and no (0,0) flash - DWM simply never sees a black sheet.
// Bottom edge: the body is exactly the sheet's rect, so it stays flush on the
// taskbar; the corner arcs never extend below it.
static float SdfRoundedRect(float px, float py, float x0, float y0, float x1,
                            float y1, float r) {
  const float cx = (x0 + x1) * 0.5f;
  const float cy = (y0 + y1) * 0.5f;
  const float hw = (x1 - x0) * 0.5f;
  const float hh = (y1 - y0) * 0.5f;
  const float qx = ::fabsf(px - cx) - (hw - r);
  const float qy = ::fabsf(py - cy) - (hh - r);
  const float ox = qx > 0.0f ? qx : 0.0f;
  const float oy = qy > 0.0f ? qy : 0.0f;
  const float mx = qx > qy ? qx : qy;
  return ::sqrtf(ox * ox + oy * oy) + (mx < 0.0f ? mx : 0.0f) - r;
}

// ---------------------------------------------------------------------------
// Render caches
//
// The curtain is re-rastered on every hover move, so everything that does NOT
// depend on the current selection is cached instead of rebuilt:
//
//  * PanelMask - the rounded silhouette's per-pixel coverage and the inner 1px
//    border tint are pure functions of the panel SIZE (and of whether it is
//    the submenu, whose left border column is suppressed). They used to be
//    recomputed with a per-pixel SDF on every render, i.e. ~2 * w * h sqrtf()
//    calls per hover event - by far the heaviest part of the frame and the
//    reason the menu felt sticky. They are now rasterized once per size into
//    two byte planes and replayed as a table lookup. Two slots are kept so
//    moving between the main panel and the submenu never thrashes one entry.
//  * the DIB + memory DC (no CreateDIBSection per frame),
//  * the row font (no CreateFontW/DeleteObject per frame),
//  * the solid brushes for background / hover pill / separators.
// ---------------------------------------------------------------------------
struct PanelMask {
  int w = 0;
  int h = 0;
  std::vector<BYTE> cover;   // 0 = outside, 255 = fully inside, else feather
  std::vector<BYTE> border;  // 0..255 blend weight of the inner border tint
};

// [0] = main panel, [1] = submenu panel.
static PanelMask g_panel_mask[2];

static void BuildPanelMask(PanelMask& m, int w, int h, bool secondary) {
  m.w = w;
  m.h = h;
  m.cover.assign((size_t)w * h, 0);
  m.border.assign((size_t)w * h, 0);
  const float r = (float)kPanelCornerRadius;
  const float x0 = (float)kOverlayMargin;
  const float y0 = (float)kOverlayMargin;
  const float x1 = x0 + (float)w;
  const float y1 = y0 + (float)h;
  const float kSoft = 0.75f;  // opaque 0.25px inside, feather 0.75px out
  const BYTE kBorderWeight = (BYTE)(0.30f * 255.0f + 0.5f);
  for (int py = 0; py < h; ++py) {
    for (int pxi = 0; pxi < w; ++pxi) {
      const size_t i = (size_t)py * w + pxi;
      const float d0 = SdfRoundedRect((float)pxi + 0.5f, (float)py + 0.5f, x0,
                                      y0, x1, y1, r);
      const float cov = kSoft - d0;
      if (cov >= 1.0f) {
        m.cover[i] = 255;
      } else if (cov <= 0.0f) {
        m.cover[i] = 0;
      } else {
        m.cover[i] = (BYTE)(cov * 255.0f + 0.5f);
      }
      // Inner 1px band, i.e. d0 in the range -1 .. 0, carries the border tint.
      // The submenu omits its left column so the main panel's right border is
      // not doubled.
      if (d0 >= -1.0f && d0 < 0.0f) {
        if (!(secondary && pxi == kOverlayMargin)) {
          m.border[i] = kBorderWeight;
        }
      }
    }
  }
}

static HDC g_dib_dc = nullptr;
static HBITMAP g_dib_bmp = nullptr;
static HGDIOBJ g_dib_prev = nullptr;
static void* g_dib_bits = nullptr;
static int g_dib_w = 0;
static int g_dib_h = 0;

static void ReleaseDib() {
  if (g_dib_dc == nullptr) return;
  if (g_dib_prev != nullptr) ::SelectObject(g_dib_dc, g_dib_prev);
  if (g_dib_bmp != nullptr) ::DeleteObject(g_dib_bmp);
  ::DeleteDC(g_dib_dc);
  g_dib_dc = nullptr;
  g_dib_bmp = nullptr;
  g_dib_prev = nullptr;
  g_dib_bits = nullptr;
  g_dib_w = 0;
  g_dib_h = 0;
}

// Returns the reusable 32bpp top-down DIB for a w x h panel, creating (or
// resizing) it only when the geometry actually changed.
static bool EnsureDib(int w, int h) {
  if (g_dib_dc != nullptr && g_dib_w == w && g_dib_h == h) return true;
  ReleaseDib();
  BITMAPINFO bi = {};
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = w;
  bi.bmiHeader.biHeight = -h;  // top-down
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;
  HDC mem = ::CreateCompatibleDC(nullptr);
  if (mem == nullptr) return false;
  void* bits = nullptr;
  HBITMAP dib = ::CreateDIBSection(mem, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (dib == nullptr || bits == nullptr) {
    if (dib != nullptr) ::DeleteObject(dib);
    ::DeleteDC(mem);
    return false;
  }
  g_dib_dc = mem;
  g_dib_bmp = dib;
  g_dib_prev = ::SelectObject(mem, dib);
  g_dib_bits = bits;
  g_dib_w = w;
  g_dib_h = h;
  return true;
}

static HFONT g_font_primary = nullptr;
static HFONT g_font_secondary = nullptr;

static HFONT PanelFont(bool primary) {
  HFONT& slot = primary ? g_font_primary : g_font_secondary;
  if (slot == nullptr) {
    slot = ::CreateFontW(primary ? -14 : -13, 0, 0, 0,
                         primary ? FW_MEDIUM : FW_NORMAL, 0, 0, 0,
                         DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                         CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH,
                         L"Microsoft YaHei UI");
  }
  return slot != nullptr ? slot : (HFONT)::GetStockObject(DEFAULT_GUI_FONT);
}

static HBRUSH g_br_sep = nullptr;
static HBRUSH g_br_hover = nullptr;
static HBRUSH g_br_body = nullptr;
static bool g_br_dark = false;
static bool g_br_ready = false;

static void EnsureBrushes(bool dark, COLORREF body) {
  if (g_br_ready && g_br_dark == dark) return;
  if (g_br_sep != nullptr) ::DeleteObject(g_br_sep);
  if (g_br_hover != nullptr) ::DeleteObject(g_br_hover);
  if (g_br_body != nullptr) ::DeleteObject(g_br_body);
  g_br_sep =
      ::CreateSolidBrush(dark ? RGB(0x33, 0x33, 0x37) : RGB(0xEC, 0xEC, 0xEE));
  g_br_hover = ::CreateSolidBrush(RGB(0x46, 0x9A, 0xF6));
  g_br_body = ::CreateSolidBrush(body);
  g_br_dark = dark;
  g_br_ready = true;
}

static bool OverlayRender(HWND ov, HWND menuHwnd,
                          const std::vector<CurtainRow>& rows) {
  RECT wr = {0, 0, 0, 0};
  if (ov == nullptr || !::GetWindowRect(menuHwnd, &wr)) return false;
  const int menuW = wr.right - wr.left;
  const int menuH = wr.bottom - wr.top;
  const int w = menuW + 2 * kOverlayMargin;
  const int h = menuH + 2 * kOverlayMargin;

  if (!EnsureDib(w, h)) return false;
  HDC mem = g_dib_dc;
  DWORD* px = static_cast<DWORD*>(g_dib_bits);
  // No clear pass: the body FillRect below covers every pixel of the panel and
  // the mask replay at the end writes every pixel's final value (RGB *and*
  // alpha), so nothing from the previous frame can survive.

  // Body: the SHEET's rect only (the margin stays empty so no translucent ring
  // appears around the panel; only the corner arc's feather reaches into it).
  // GDI fills RGB only (alpha keeps its initial 0); the per-pixel pass below
  // stamps the rounded corner coverage.
  const bool dark = g_menu_is_dark;
  const COLORREF c_bg = g_menu_bg;
  const COLORREF c_hover = RGB(0x46, 0x9A, 0xF6);
  const COLORREF c_text = dark ? RGB(0xF5, 0xF5, 0xF7) : RGB(0x1C, 0x1C, 0x1E);
  const COLORREF c_disabled = dark ? RGB(0x8E, 0x8E, 0x93)
                                   : RGB(0xB2, 0xB2, 0xB6);
  RECT body_rc = {kOverlayMargin, kOverlayMargin, kOverlayMargin + menuW,
                  kOverlayMargin + menuH};
  EnsureBrushes(dark, c_bg);
  ::FillRect(mem, &body_rc, g_br_body);

  // Same look as the native owner-draw path: hover pill inset 6px radius 10,
  // leading dot in the mark column, label centered in the sheet. The first
  // level panel uses a heavier weight and wider tracking than the submenu.
  const bool primary = (menuHwnd == g_anchor_hwnd);
  HFONT use_font = PanelFont(primary);
  HGDIOBJ old_font = ::SelectObject(mem, use_font);
  ::SetBkMode(mem, TRANSPARENT);
  ::SetTextCharacterExtra(mem, primary ? 2 : 0);
  const int kMarkColumnRight = 26;  // mirrors HandleDrawItem's dot column

  for (const CurtainRow& row : rows) {
    // Client -> curtain coords: +kOverlayMargin border, +8 for the NCALCSIZE
    // top band that parks the client under the sheet's top edge.
    const int cy0 = kOverlayMargin + 8 + row.rc.top;
    const int cy1 = kOverlayMargin + 8 + row.rc.bottom;
    if (cy1 <= cy0) continue;
    if (row.separator) {
      const int mid = (cy0 + cy1) / 2;
      RECT lr = {kOverlayMargin, mid, kOverlayMargin + menuW, mid + 1};
      ::FillRect(mem, &lr, g_br_sep);
      continue;
    }
    ::SetTextColor(mem, row.disabled
                            ? c_disabled
                            : (row.selected ? RGB(0xFF, 0xFF, 0xFF) : c_text));
    if (row.selected && !row.disabled) {
      // Straight pill body drawn by GDI in microseconds; the four pill-end
      // arcs are feathered per-pixel with a linear SDF coverage ramp (one SDF
      // per pixel - fast AND smooth; the earlier 3x3 supersample quantized
      // coverage to 3 levels and read as jaggies).
      const int px0 = kOverlayMargin + 6;
      const int px1 = kOverlayMargin + menuW - 6;
      RECT prt = {px0, cy0, px1, cy1};
      ::FillRect(mem, &prt, g_br_hover);
      const float pr = 10.0f;  // pill corner radius
      const int pbox = (int)pr + 2;
      const COLORREF hcol = (COLORREF)c_hover;
      const COLORREF bcol = (COLORREF)c_bg;
      const int hrc = (int)((hcol >> 0) & 0xFFu);
      const int hgc = (int)((hcol >> 8) & 0xFFu);
      const int hbc = (int)((hcol >> 16) & 0xFFu);
      const int brc = (int)((bcol >> 0) & 0xFFu);
      const int bgc = (int)((bcol >> 8) & 0xFFu);
      const int bbc = (int)((bcol >> 16) & 0xFFu);
      const float kSoft = 0.5f;
      const int arcs[4][2] = {
          {px0, cy0}, {px1 - (int)pr, cy0}, {px0, cy1 - (int)pr},
          {px1 - (int)pr, cy1 - (int)pr}};
      for (int ai = 0; ai < 4; ++ai) {
        const int ax = arcs[ai][0];
        const int ay = arcs[ai][1];
        for (int py = ay; py < ay + pbox && py < cy1; ++py) {
          if (py < cy0) continue;
          DWORD* outp = px + py * w;
          for (int pxi = ax; pxi < ax + pbox && pxi < px1; ++pxi) {
            if (pxi < px0) continue;
            const float xc = (float)pxi + 0.5f;
            const float yc = (float)py + 0.5f;
            const float d0 =
                SdfRoundedRect(xc, yc, (float)px0, (float)cy0, (float)px1,
                               (float)cy1, pr);
            float cov = kSoft - d0;
            if (cov <= 0.0f) {
              // Outside the pill arc: the all-blue FillRect painted here, so
              // erase the blue back to the panel background - otherwise the
              // rounded pill reads as a blue rectangle with a visible cut.
              outp[pxi] =
                  0xFF000000u | ((DWORD)brc << 16) | ((DWORD)bgc << 8) |
                  (DWORD)bbc;
              continue;
            }
            if (cov >= 1.0f) continue;  // interior: already hover blue
            const int rr = (int)((float)hrc * cov + (float)brc * (1.0f - cov) +
                                 0.5f);
            const int gg = (int)((float)hgc * cov + (float)bgc * (1.0f - cov) +
                                 0.5f);
            const int bbb =
                (int)((float)hbc * cov + (float)bbc * (1.0f - cov) + 0.5f);
            outp[pxi] = 0xFF000000u | ((DWORD)rr << 16) | ((DWORD)gg << 8) |
                        (DWORD)bbb;
          }
        }
      }
    }
    if (row.checked || row.popup) {
      RECT dot_rc = {kOverlayMargin + kMarkColumnRight - 14, cy0,
                     kOverlayMargin + kMarkColumnRight, cy1};
      ::DrawTextW(mem, L"\x25CF", 1, &dot_rc,
                  DT_SINGLELINE | DT_VCENTER | DT_RIGHT | DT_NOPREFIX);
    }
    if (!row.label.empty()) {
      // Plan B: center "dot column + gap + label" as one block, so long
      // labels no longer hug the dot while the right side looks empty.
      int text_w = 0;
      {
        SIZE tsz = {0, 0};
        ::GetTextExtentPoint32W(mem, row.label.c_str(),
                                (int)row.label.size(), &tsz);
        text_w = tsz.cx;
      }
      const int kMarkCol = 26;
      const int kMarkGap = 6;
      // Soft centering offset: 4px right of plain center (was 16, then 8).
      const int kOffset = 4;
      int text_x = (menuW - text_w) / 2 + kOffset;
      if (text_x < kMarkCol + kMarkGap) text_x = kMarkCol + kMarkGap;
      RECT text_rc = {kOverlayMargin + text_x, cy0,
                      kOverlayMargin + menuW, cy1};
      const UINT dt = DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX;
      ::DrawTextW(mem, row.label.c_str(), -1, &text_rc, dt | DT_LEFT);
    }
  }
  if (old_font != nullptr) ::SelectObject(mem, old_font);

  HDC sdc = ::GetDC(nullptr);

  // Replay the cached panel mask: ONE linear pass, integer math only. This
  // replaces what used to be three full-panel passes (alpha stamp + two SDF
  // sweeps over every pixel), i.e. ~2 * w * h sqrtf() calls per hover move -
  // the main reason the menu felt sluggish.
  {
    const bool secondary = (menuHwnd != g_anchor_hwnd);
    PanelMask& mask = g_panel_mask[secondary ? 1 : 0];
    if (mask.w != w || mask.h != h) BuildPanelMask(mask, w, h, secondary);
    const BYTE br = GetRValue(c_bg);
    const BYTE bg = GetGValue(c_bg);
    const BYTE bb = GetBValue(c_bg);
    const DWORD bc = dark ? 0xFF3F3F46u : 0xFFE0E0E0u;
    const int bcr = (int)((bc >> 0) & 0xFFu);
    const int bcg = (int)((bc >> 8) & 0xFFu);
    const int bcb = (int)((bc >> 16) & 0xFFu);
    const BYTE* cover = mask.cover.data();
    const BYTE* border = mask.border.data();
    const size_t npix = (size_t)w * h;
    for (size_t i = 0; i < npix; ++i) {
      const BYTE cv = cover[i];
      DWORD out;
      if (cv == 0) {
        out = 0;  // outside the panel: DWM composites the exact desktop
      } else if (cv == 255) {
        out = px[i] | 0xFF000000u;  // interior: keep the row pixels
      } else {
        // Feather band: panel colour premultiplied by the same coverage ramp,
        // so the alpha profile stays continuous through all 8 tangent points.
        const DWORD fr = (DWORD)((UINT)br * cv / 255u);
        const DWORD fg = (DWORD)((UINT)bg * cv / 255u);
        const DWORD fb = (DWORD)((UINT)bb * cv / 255u);
        out = ((DWORD)cv << 24) | (fr << 16) | (fg << 8) | fb;
      }
      const BYTE ba = border[i];
      if (ba != 0) {
        // 1px inner frame tracing the full rounded outline. Soft alpha blend
        // that preserves each pixel's own alpha, so the corner feather stays
        // continuous at the tips.
        const int orr = (int)((out >> 0) & 0xFFu);
        const int ogg = (int)((out >> 8) & 0xFFu);
        const int obb = (int)((out >> 16) & 0xFFu);
        const int nr = (bcr * ba + orr * (255 - ba)) / 255;
        const int ng = (bcg * ba + ogg * (255 - ba)) / 255;
        const int nb = (bcb * ba + obb * (255 - ba)) / 255;
        out = (out & 0xFF000000u) | ((DWORD)nr << 16) | ((DWORD)ng << 8) |
              (DWORD)nb;
      }
      px[i] = out;
    }
  }

  POINT ptSrc = {0, 0};
  SIZE siz = {w, h};
  POINT ptDst = {wr.left - kOverlayMargin, wr.top - kOverlayMargin};
  BLENDFUNCTION bf = {AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  if (sdc != nullptr) {
    ::UpdateLayeredWindow(ov, sdc, &ptDst, &siz, mem, &ptSrc, 0, &bf,
                          ULW_ALPHA);
    ::ReleaseDC(nullptr, sdc);
  }
  return true;
}

static HMENU PanelMenuFor(HWND menuHwnd) {
  if (menuHwnd == g_anchor_hwnd) return g_anchor_hmenu;
  if (menuHwnd == g_sub_hwnd) return g_sub_hmenu;
  return nullptr;
}

static void CurtainRenderFor(HWND menuHwnd, HWND ov) {
  std::vector<CurtainRow> rows;
  HMENU menu = PanelMenuFor(menuHwnd);
  if (menu != nullptr && g_self != nullptr) g_self->CollectMenuView(menu, rows);
  // Skip the re-raster when nothing visible changed: a hover that crosses two
  // rows fires TWO DrawItems (old row deselect + new row select) back-to-back,
  // and coalescing the pair into a single render keeps the pill glued to the
  // cursor instead of lagging one frame behind it.
  RECT wr = {0, 0, 0, 0};
  ::GetWindowRect(menuHwnd, &wr);
  uint64_t key = (uint64_t)(UINT_PTR)menuHwnd * 2654435761ull;
  key ^= ((uint64_t)wr.left & 0xFFFF) << 32 |
         ((uint64_t)wr.top & 0xFFFF) << 16 |
         ((uint64_t)(wr.right - wr.left) & 0xFFFF);
  key ^= (uint64_t)(wr.bottom - wr.top) << 48;
  for (const CurtainRow& r : rows) {
    key ^= (uint64_t)r.rc.top * 31ull + (uint64_t)r.rc.bottom * 131ull +
           (uint64_t)r.rc.right * 7ull + (uint64_t)r.rc.left;
    key ^= (uint64_t)(r.selected ? 1 : 0) * 1000003ull +
           (uint64_t)(r.popup ? 2 : 0) * 999979ull +
           (uint64_t)(r.checked ? 4 : 0) * 70001ull +
           (uint64_t)(r.separator ? 8 : 0) * 50021ull +
           (uint64_t)(r.disabled ? 16 : 0) * 3001ull;
    if (!r.label.empty()) {
      uint64_t lk = 0;
      for (wchar_t ch : r.label) lk = lk * 1099511628211ull + (uint64_t)ch;
      key ^= lk;
    }
  }
  static HWND g_last_ov = nullptr;
  static uint64_t g_last_key = 0;
  if (ov == g_last_ov && key == g_last_key) return;  // nothing visible changed
  g_last_ov = ov;
  g_last_key = key;
  OverlayRender(ov, menuHwnd, rows);
}

static HWND OverlayCreate(HWND menuHwnd) {
  EnsureOverlayClass();
  RECT wr = {0, 0, 0, 0};
  if (!::GetWindowRect(menuHwnd, &wr)) return nullptr;
  HWND ov = ::CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE |
          WS_EX_TOPMOST,
      kOverlayClass, L"", WS_POPUP, wr.left - kOverlayMargin,
      wr.top - kOverlayMargin, 4, 4, nullptr, nullptr,
      ::GetModuleHandleW(nullptr), nullptr);
  if (ov == nullptr) return nullptr;
  CurtainRenderFor(menuHwnd, ov);
  ::ShowWindow(ov, SW_SHOWNOACTIVATE);
  // The overlay must always ride ABOVE the native sheet in z-order (menus sit
  // above WS_EX_TOPMOST while tracking), so re-assert topmost after showing.
  ::SetWindowPos(ov, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  ::SetPropW(menuHwnd, kOverlayProp, (HANDLE)ov);
  return ov;
}

// Keep the curtain glued to its sheet: with no curtain yet, create one from
// the sheet's current rect; otherwise re-raster + reposition (menus move and
// rarely resize, so re-rendering unconditionally is cheap here).
static void OverlaySync(HWND menuHwnd) {
  if (menuHwnd != g_anchor_hwnd && menuHwnd != g_sub_hwnd) return;
  HWND ov = (HWND)::GetPropW(menuHwnd, kOverlayProp);
  if (ov == nullptr) {
    OverlayCreate(menuHwnd);
  } else {
    CurtainRenderFor(menuHwnd, ov);
  }
}

static void OverlayDestroy(HWND menuHwnd) {
  HWND ov = (HWND)::GetPropW(menuHwnd, kOverlayProp);
  if (ov != nullptr) {
    ::DestroyWindow(ov);
    ::RemovePropW(menuHwnd, kOverlayProp);
  }
}

// Swallow the menu window's non-client area. The menu manager sizes the
// window as rows + 6px frame; WM_WINDOWPOSCHANGING canonicalizes the size to
// rows + 16/+10 (once per menu window, idempotent against read-back) and
// WM_NCCALCSIZE claims 8px top/bottom as padding, plus ZERO left/right - the
// client spans the whole window so the hover pill can reach the sheet's
// rounded right edge (a wider NC band on the right would leave a flat strip
// between the pill and the corner, which reads as a square right side).
// WM_NCPAINT fills the ring with the menu background, keeping the panel flat
// and borderless (v2rayN-like).
// The menu manager has been observed stripping WS_EX_LAYERED off #32768
// windows at show time, which resurfaces the raw native sheet under the
// curtain (arrow, native dots, no pill). Re-assert layering + alpha=1 on
// every move/paint so the sheet can never become visible.
static void EnsureSheetInvisible(HWND hwnd) {
  LONG_PTR ex = ::GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
  if ((ex & WS_EX_LAYERED) == 0) {
    ex |= WS_EX_LAYERED;
    ::SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex);
    ::SetLayeredWindowAttributes(hwnd, 0, 1, LWA_ALPHA);
  }
}

LRESULT CALLBACK MenuFrameSubProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam) {
  if (message == WM_WINDOWPOSCHANGING) {
    EnsureSheetInvisible(hwnd);
    WINDOWPOS* wp = reinterpret_cast<WINDOWPOS*>(lparam);
    if (wp == nullptr) return CallWindowProcW(g_menu_base_proc, hwnd, message,
                                              wparam, lparam);
    bool sizing = (wp->flags & SWP_NOSIZE) == 0;
    bool is_anchor = (g_anchor_hwnd == hwnd);
    // The first menu window of a popup run is the one TrackPopupMenu anchored
    // (submenus are created and placed by the menu system itself).
    if (sizing && g_anchor_hwnd == nullptr) {
      g_anchor_hwnd = hwnd;
      is_anchor = true;
    }
    if (is_anchor && sizing) {
      if (g_pad_hwnd != hwnd) {
        g_pad_hwnd = hwnd;
        g_pad_cy = wp->cy + 10;
      }
      // Pin both dimensions: the system sizes the window from its own chrome
      // (which can exceed g_pad_cx), pushing the panel's right edge past the
      // tray icon. Forcing the width here makes the right edge land exactly on
      // the anchor point we gave to TrackPopupMenu.
      wp->cy = g_pad_cy;
      wp->cx = g_pad_cx;
    } else if (g_anchor_hwnd != nullptr && hwnd != g_anchor_hwnd) {
      // Submenu sheet: own height, no width pin (the manager sizes it to the
      // longest row, so the pill always reaches the sheet's rounded right
      // edge), and its right edge parked 6px onto the main panel's right so
      // the sheets read as one surface. The system's first size pass sets the
      // sheet, but its FINAL placement arrives as a NOSIZE MOVE pass - the
      // right-open placement must apply to moves too, or the sheet lands on
      // top of (or right of) the panel instead of seaming against it.
      if (sizing) {
        if (g_sub_hwnd != hwnd) {
          g_sub_hwnd = hwnd;
          g_sub_cy = wp->cy + 10;
        }
        wp->cy = g_sub_cy;
        // Fixed compact width: the natural sheet (202) reads too wide for a
        // 3-item server list, the old 88% pin (170) clipped the pill. 172 is
        // the slim-but-fitting middle for the widest row.
        wp->cx = g_sub_cx;
      }
      RECT ar;
      if ((wp->flags & SWP_NOMOVE) == 0 &&
          ::GetWindowRect(g_anchor_hwnd, &ar)) {
        // Work area of the monitor the submenu itself sits on (per-window, so
        // a second screen right of the panel does not inherit the anchor's
        // primary-monitor limits).
        RECT wa = {0, 0, 0, 0};
        HMONITOR mon = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
        if (mon != nullptr) {
          MONITORINFO mi = {0};
          mi.cbSize = sizeof(mi);
          if (::GetMonitorInfoW(mon, &mi)) wa = mi.rcWork;
        }
        // Submenu opens flush against the main panel's right edge (0px
        // gap): the two sheets touch without overlapping, reading as a
        // single stepped surface.
        int sx = ar.right;
        // Use the LARGER of the pinned width and the pass's own width for
        // the overflow test: on the NOSIZE move pass wp->cx may carry the
        // natural sheet width (202) while the pinned one is the compact
        // g_sub_cx, so testing only g_sub_cx could say "fits" when the sheet
        // really crosses the right border.
        const int sub_w = (wp->cx > g_sub_cx) ? wp->cx : g_sub_cx;
        if (wa.right > wa.left) {
          // Default: open to the RIGHT of the main panel. When the sheet
          // would cross the work-area's right edge, flip it to sit flush on
          // the main panel's LEFT side instead.
          if (sx + sub_w > wa.right - 8) sx = ar.left - sub_w;
          // Hard clamp: no pass (sizing or move, any width) may leave the
          // panel crossing the screen's right edge, which read as the submenu
          // colliding with the desktop's right border.
          if (sx + sub_w > wa.right - 8) sx = wa.right - 8 - sub_w;
          if (sx < wa.left) sx = wa.left;
        } else if (g_work_right > 0) {
          if (sx + sub_w > g_work_right - 8) sx = ar.left - sub_w;
          if (sx + sub_w > g_work_right - 8) sx = g_work_right - 8 - sub_w;
          if (sx < g_work_left) sx = g_work_left;
        }
        wp->x = sx;
      }
    }
    if ((wp->flags & SWP_NOMOVE) == 0 && is_anchor && g_anchor_valid) {
      // The system creates the popup at (0,0) before it sizes/positions it;
      // any paint during that origin state is the "hollow black box" flash at
      // the screen's top-left. Pin BOTH axes to the cursor anchor so the first
      // visible frame is already sitting exactly where the user right-clicked.
      //
      // g_anchor_left is the panel's RIGHT edge (see the TPM_RIGHTALIGN note
      // in ShowContextMenuNow): subtract the pinned width to recover the
      // top-left the system actually needs. When the panel had to flip to the
      // right of the cursor (no room on the left), g_anchor_stick_left is set
      // and g_anchor_left already IS the left edge.
      wp->x = g_anchor_stick_left ? g_anchor_left
                                  : g_anchor_left - g_pad_cx;
      wp->y = g_anchor_top;
    }
  } else if (message == WM_WINDOWPOSCHANGED) {
    // DWM re-reads the border/corner visuals when a window is shown or
    // repositioned (menus go through several show/move passes). Re-assert the
    // "no border, no own rounding" attributes here so none of the passes
    // reintroduces the dark corner arch baked in by the compositor.
    DWORD none = 0xFFFFFFFE;
    DwmSetWindowAttribute(hwnd, 34 /* DWMWA_BORDER_COLOR */, &none,
                          sizeof(none));
    DWORD pref = 1;  // DWMWCP_DONOTROUND
    DwmSetWindowAttribute(hwnd, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */,
                          &pref, sizeof(pref));
    // Same for the show animation (see HCBT_CREATEWND above): no morph/fade,
    // so the first visible frame is already the finished rounded sheet.
    DWORD td = 1;  // DWMWA_TRANSITIONS_FORCEDISABLED
    DwmSetWindowAttribute(hwnd, 3, &td, sizeof(td));
    // The CHANGED message arrives AFTER the size/pos change has actually been
    // applied, so GetWindowRect returns the window's TRUE final geometry. The
    // menu manager can end up resizing the sheet a pixel or two beyond what the
    // CHANGING pass proposed; clipping a region at the proposed (smaller) size
    // then leaves a thin transparent strip at the bottom/right - which reads as
    // "panel not flush with the taskbar" and cuts the hover pill's rounded
    // right corner square. Round against reality here (change-only against the
    // cache, so a settled sheet does not repaint on every message).
    RECT wr = {0, 0, 0, 0};
    ::GetWindowRect(hwnd, &wr);
    int w = wr.right - wr.left;
    int h = wr.bottom - wr.top;
    bool is_anchor_w = (g_anchor_hwnd == hwnd);
    bool is_sub_w = (g_sub_hwnd == hwnd);
    // Cache the sheet's CLIENT-area width. NCCALCSIZE insets 5px from the
    // left (right inset is 0 - the row stretches to the window edge so
    // the pill reaches the round corner). Subtract that here so the
    // DrawItem pill right matches the visible right, with no overhang
    // that gets clipped by the round corner into a colored stub.
    int sheet_client_w = w;  // NCCALCSIZE inset is vertical only (top=8);
                            // left/right are 0 so the pill can reach
                            // the panel edge.
    if (is_anchor_w || is_sub_w) {
      if (g_rgn_last_hwnd != hwnd || g_rgn_last_cx != w || g_rgn_last_cy != h) {
        g_rgn_last_hwnd = hwnd;
        g_rgn_last_cx = w;
        g_rgn_last_cy = h;
        ApplyRoundedRegion(hwnd, w, h);
        // Cache the actual client-area width for this sheet so DrawItem
        // (which only sees an HMENU, not the HWND) can clamp the row to
        // the visible right edge. Without this, the pill extends to
        // g_pad_cx and gets clipped by the round corner.
        if (is_anchor_w) g_sheet_cl = sheet_client_w;
        if (is_sub_w) g_sub_sheet_cl = sheet_client_w;
      }
      // The curtain must follow every move/resize, and must exist before
      // the sheet's first visible frame (call it on every CHANGED, not only
      // when the region cache invalidates). The menu system's FIRST changed
      // pass can still report the sheet at the default (0,0) origin before our
      // CHANGING pass pins it to the tray; creating the curtain there would
      // flash a frame at the screen's top-left. Only create/render once
      // the sheet sits at its final anchored rect.
      bool anchored_pos = true;
      if (is_anchor_w) {
        // g_anchor_left is the panel's RIGHT edge by default, so the expected
        // window left is (right - width). When the panel flipped to open
        // rightward, g_anchor_left already IS the left edge.
        const int expected_left =
            g_anchor_stick_left ? g_anchor_left : g_anchor_left - g_pad_cx;
        anchored_pos =
            g_anchor_valid && wr.left == expected_left && wr.top == g_anchor_top;
      } else {
        // Sub sheets transiently report (0,0) before their final placement;
        // creating the curtain there would flash a stray panel at the
        // screen's top-left during the slide-in animation.
        anchored_pos = (wr.left > 0 && wr.top > 0);
      }
      if (anchored_pos) OverlaySync(hwnd);
    }
  } else if (message == WM_PAINT) {
    EnsureSheetInvisible(hwnd);
    return CallWindowProcW(g_menu_base_proc, hwnd, message, wparam, lparam);
  } else if (message == WM_NCCALCSIZE && wparam != 0) {
    NCCALCSIZE_PARAMS* np = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
    np->rgrc[0].left += 0;
    np->rgrc[0].top += 8;
    np->rgrc[0].right -= 0;
    np->rgrc[0].bottom -= 8;
    return 0;
  } else if (message == WM_NCPAINT) {
    RECT wr;
    ::GetWindowRect(hwnd, &wr);
    HDC hdc = ::GetWindowDC(hwnd);
    if (hdc != nullptr) {
      HBRUSH b = ::CreateSolidBrush(g_menu_is_dark ? RGB(0x23, 0x23, 0x27)
                                                   : RGB(0xFF, 0xFF, 0xFF));
      RECT full = {0, 0, wr.right - wr.left, wr.bottom - wr.top};
      ::FillRect(hdc, &full, b);
      ::DeleteObject(b);
      ::ReleaseDC(hwnd, hdc);
    }
    return 0;
  } else if (message == WM_DESTROY) {
    OverlayDestroy(hwnd);
    return CallWindowProcW(g_menu_base_proc, hwnd, message, wparam, lparam);
  }
  return CallWindowProcW(g_menu_base_proc, hwnd, message, wparam, lparam);
}

// The submenu sheet is the second #32768 of a popup run (the anchor already
// exists). Lex the anchor's popup rows so the sub curtain has real rows from
// its very first frame instead of filling in one DrawItem late.
static HMENU FindPopupSubmenu() {
  if (g_anchor_hmenu == nullptr) return nullptr;
  HMENU first = nullptr;
  UINT_PTR sel_code = 0;
  auto sit = g_sel_key.find(g_anchor_hmenu);
  if (sit != g_sel_key.end()) sel_code = sit->second;
  const int cnt = ::GetMenuItemCount(g_anchor_hmenu);
  for (int i = 0; i < cnt; ++i) {
    MENUITEMINFO mii = {sizeof(mii)};
    mii.fMask = MIIM_SUBMENU | MIIM_DATA;
    if (!::GetMenuItemInfo(g_anchor_hmenu, i, TRUE, &mii)) continue;
    if (mii.hSubMenu == nullptr) continue;
    if (first == nullptr) first = mii.hSubMenu;
    if (sel_code != 0 && reinterpret_cast<UINT_PTR>(mii.hSubMenu) == sel_code)
      return mii.hSubMenu;
  }
  return first;
}

LRESULT CALLBACK MenuFrameCbtProc(int code, WPARAM wparam, LPARAM lparam) {
  if (code == HCBT_CREATEWND) {
    HWND hwnd = reinterpret_cast<HWND>(wparam);
    wchar_t cls[64] = {0};
    GetClassNameW(hwnd, cls, 64);
    if (lstrcmpW(cls, L"#32768") == 0) {
      DWORD none = 0xFFFFFFFE;
      DwmSetWindowAttribute(hwnd, 34 /* DWMWA_BORDER_COLOR */, &none,
                            sizeof(none));
      // Make DWM stop drawing its OWN rounded-corner border on this window.
      // The sheet is clipped by SetWindowRgn to a radius-22 corner, but Win11
      // DWM still rounds the raw window rect with a smaller radius (~8-16px)
      // and draws a dark 1px border arch inside the rect. With the region that
      // arch lands OUTSIDE the visible sheet (in the transparent corner),
      // reading as a black arc floating just beyond the panel. Declaring the
      // corner "don't round" kills that extra arch.
      DWORD pref = 1;  // DWMWCP_DONOTROUND
      DwmSetWindowAttribute(hwnd, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */,
                            &pref, sizeof(pref));
      // The soft dark halo AROUND the panel is a DWM drop shadow that hugs the
      // SetWindowRgn boundary (invisible on the old square corners, arching
      // over the desktop once the corners round). Layering is not an option
      // for #32768 (menu rendering breaks). The documented way to make DWM
      // leave a regioned window alone is to declare the non-client rendering
      // policy DISABLED - DWM then draws no shadow and we own the whole frame.
      DWORD ncrp = 1;  // DWMNCRP_DISABLED
      DwmSetWindowAttribute(hwnd, 2 /* DWMWA_NCRENDERING_POLICY */, &ncrp,
                            sizeof(ncrp));
      // Belt-and-suspenders: drop any class-level flyout shadow so no soft
      // dark halo hugs the rounded corners on top of the desktop.
      LONG_PTR cls_style = ::GetClassLongPtrW(hwnd, GCL_STYLE);
      if ((cls_style & CS_DROPSHADOW) != 0) {
        ::SetClassLongPtrW(hwnd, GCL_STYLE, cls_style & ~CS_DROPSHADOW);
      }
      // Disable the DWM flyout morph/fade animation. The first animation
      // frames show the raw pre-region window as a hollow black box (shadow
      // ring + empty fill) morphing toward the regioned sheet; killing the
      // transition makes the finished rounded panel appear in one frame.
      DWORD td = 1;  // DWMWA_TRANSITIONS_FORCEDISABLED
      DwmSetWindowAttribute(hwnd, 3, &td, sizeof(td));
      // The native sheet is now only a BEHAVIOR proxy: it keeps hover/click/
      // keyboard/submenu tracking and keeps sending WM_MEASUREITEM /
      // WM_DRAWITEM to the owner, but the self-drawn curtain panel renders the
      // visible UI. Compositing it at alpha=1 (LWA_ALPHA) hides the raw sheet
      // AND kills its DWM shadow (layered windows get none) and its dark
      // material - DWM never even draws a black frame at (0,0). A layered
      // window is still fully hit-testable, so input and tracking are intact.
      LONG_PTR ex = ::GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
      ex |= WS_EX_LAYERED;
      ::SetWindowLongPtrW(hwnd, GWL_EXSTYLE, ex);
      ::SetLayeredWindowAttributes(hwnd, 0, 1, LWA_ALPHA);
      // Second #32768 of the run = the submenu sheet: learn its HMENU up
      // front so the sub curtain is drawn from the first frame.
      if (g_anchor_hwnd != nullptr && hwnd != g_anchor_hwnd) {
        g_sub_hmenu = FindPopupSubmenu();
      }
      g_menu_base_proc = reinterpret_cast<WNDPROC>(
          SetWindowLongPtrW(hwnd, GWLP_WNDPROC,
                            reinterpret_cast<LONG_PTR>(MenuFrameSubProc)));
    }
  }
  return CallNextHookEx(g_menu_cbt_hook, code, wparam, lparam);
}

// Width follows the longest label so the menu hugs its content: centered text
// stays clear of the check column (left) and the chevron (right). Submenus
// (server names) get their own tighter width instead of inheriting the main
// menu's.
int TrayManagerPlugin::ComputeMenuWidth() {
  HDC dc = ::GetDC(NULL);
  HFONT font = ::CreateFontW(
      -13, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
      CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH,
      L"Microsoft YaHei UI");
  HGDIOBJ old = font != nullptr ? ::SelectObject(dc, font) : nullptr;
  int main_max = 0, sub_max = 0;
  for (const auto& kv : item_labels_) {
    const std::wstring& s = kv.second;
    SIZE sz = {0, 0};
    if (!::GetTextExtentPoint32W(dc, s.c_str(), (int)s.size(), &sz)) continue;
    if (submenu_item_ids_.count(kv.first)) {
      if (sz.cx > sub_max) sub_max = sz.cx;
    } else if (sz.cx > main_max) {
      main_max = sz.cx;
    }
  }
  if (old != nullptr) ::SelectObject(dc, old);
  if (font != nullptr) ::DeleteObject(font);
  ::ReleaseDC(NULL, dc);
  // Check column left, chevron + breathing room right. Submenus (server
  // names) use the same formula as the main panel here - we want the
  // text + dot to fit comfortably, and g_sub_cx in PopUpContextMenu
  // becomes a no-op when the manager refuses to shrink further, so
  // packing as much in as possible here avoids text truncation.
  int w = main_max + 64;
  if (w < 148) w = 148;
  if (w > 280) w = 280;
  menu_item_width_ = w;
  w = sub_max + 64;
  if (w < 120) w = 120;
  if (w > 240) w = 240;
  submenu_item_width_ = w;
  return menu_item_width_;
}

std::optional<LRESULT> TrayManagerPlugin::HandleMeasureItem(LPARAM lparam) {
  LPMEASUREITEMSTRUCT mi = reinterpret_cast<LPMEASUREITEMSTRUCT>(lparam);
  if (mi->CtlType != ODT_MENU) return std::nullopt;
  // Must return TRUE: FALSE means "unhandled" and owner-draw items get no
  // height, collapsing the whole menu into an invisible sliver (that is why the
  // tray right-click showed nothing earlier). MEASUREITEMSTRUCT carries no menu
  // handle (only itemID), so separators are told apart via separator_ids_;
  // normal rows are 26px tall and dividers 16px, matching the PopupMenu look.
  mi->itemWidth = submenu_item_ids_.count(mi->itemID) ? submenu_item_width_
                                                      : menu_item_width_;
  mi->itemHeight = separator_ids_.count(mi->itemID) ? 18 : 30;
  return TRUE;
}

std::optional<LRESULT> TrayManagerPlugin::HandleDrawItem(LPARAM lparam) {
  LPDRAWITEMSTRUCT dis = reinterpret_cast<LPDRAWITEMSTRUCT>(lparam);
  if (dis->CtlType != ODT_MENU) return std::nullopt;
  HMENU menu = reinterpret_cast<HMENU>(dis->hwndItem);
  bool is_separator = false, is_popup = false;
  const wchar_t* text = nullptr;
  ResolveMenuItem(menu, dis->itemID, &is_separator, &is_popup, &text);
  // MF_POPUP rows: the system may drop the requested wID, so identify them by
  // the submenu handle carried in the owner-draw data instead.
  if (dis->itemData != 0) {
    auto it = popup_ids_.find(static_cast<UINT_PTR>(dis->itemData));
    if (it != popup_ids_.end()) {
      is_popup = true;
      auto lit = item_labels_.find(it->second);
      if (lit != item_labels_.end()) text = lit->second.c_str();
      // Cache this row's rect on its OWN hwnd (the system redraws the
      // submenu arrow for it; we cover it in WM_PAINT). The hwndItem IS the
      // sheet window for owner-draw menu items.
  }
  }
  // ---- Curtain mirror: keep the self-drawn panel in step with the native
  // sheet's selection/state. Hover moves repaint the newly-hot row (selected)
  // and the previously-hot one (unselected), so this runs on every tick.
  {
    const bool sel_now = (dis->itemState & ODS_SELECTED) != 0;
    const UINT_PTR sel_key = is_popup
                                 ? static_cast<UINT_PTR>(dis->itemData)
                                 : static_cast<UINT_PTR>(dis->itemID);
    if (sel_now)
      g_sel_key[menu] = sel_key;
    else if (g_sel_key.count(menu) && g_sel_key[menu] == sel_key)
      g_sel_key.erase(menu);
    if (menu != g_anchor_hmenu) g_sub_hmenu = menu;  // learn the submenu HMENU
    const int cnt = ::GetMenuItemCount(menu);
    if (cnt > 0 && g_row_rects[menu].size() != static_cast<size_t>(cnt)) {
      g_row_rects[menu].assign(cnt, RECT{0, 0, 0, 0});
    }
    if (cnt > 0) {
      // Lane index = which measured row sits at this rc.top (mixed heights).
      int yy = 0;
      for (int j = 0; j < cnt; ++j) {
        MENUITEMINFO mii = {sizeof(mii)};
        mii.fMask = MIIM_TYPE;
        if (!::GetMenuItemInfo(menu, j, TRUE, &mii)) break;
        const int hrow = (mii.fType & MFT_SEPARATOR) ? 18 : 30;
        if (yy == dis->rcItem.top) {
          g_row_rects[menu][static_cast<size_t>(j)] = dis->rcItem;
          break;
        }
        yy += hrow;
      }
    }
  }

  const bool dark = IsDarkTheme();
  const COLORREF c_bg = BlendFor(dark, RGB(0xFF, 0xFF, 0xFF), RGB(0x23, 0x23, 0x27));
  const COLORREF c_hover = RGB(0x46, 0x9A, 0xF6);  // selection pill: #469AF6 (light + dark)
  const COLORREF c_text = BlendFor(dark, RGB(0x1C, 0x1C, 0x1E), RGB(0xF5, 0xF5, 0xF7));
  const COLORREF c_disabled = BlendFor(dark, RGB(0xB2, 0xB2, 0xB6), RGB(0x8E, 0x8E, 0x93));

  RECT rc = dis->rcItem;
  // The menu manager lays rows out to the text-template width, which is a few
  // The hover pill is drawn in the CLIENT DC, which is clipped at the client
  // rect. The NCALCSIZE override above zeroes the horizontal insets so the
  // client spans the whole window; stretching the row to the ACTUAL client
  // width therefore carries the pill all the way to the sheet's rounded right
  // edge - without that, a flat NC band sat between the pill and the corner
  // and the highlight read square on the right. Left/right NC band is gone,
  // so the visible row edges ARE the sheet edges. sheet_cl is the cached
  // client width of THIS sheet (anchor vs. submenu), captured at
  // WINDOWPOSCHANGED - we can't GetClientRect here, dis->hwndItem is HMENU.
  int sheet_cl = (g_anchor_hmenu != nullptr && menu == g_anchor_hmenu)
                     ? g_sheet_cl : g_sub_sheet_cl;
  RECT row = rc;
  // Use the sheet's actual rendered client width as both floor AND ceiling
  // for the row, so the pill always extends to the panel edge (panel's
  // round corner does the trailing curve). sheet_cl can be 0 on the very
  // first DrawItem of a popup run (cache populated in WINDOWPOSCHANGED
  // which may run after the first paint); in that case fall back to the
  // raw rcItem.right, which is close enough for the first frame.
  if (sheet_cl > 0) {
    row.left = 0;
    row.right = sheet_cl;
  }
  HDC hdc = dis->hDC;
  bool selected = (dis->itemState & ODS_SELECTED) != 0;
  bool disabled = (dis->itemState & ODS_GRAYED) != 0;
  bool checked = (dis->itemState & ODS_CHECKED) != 0;

  // Clear the complete rendered row width, not only rcItem. The hover pill is
  // wider than rcItem, so clearing rc alone leaves blue pixels at the right
  // edge after the pointer moves away. Brushes are cached: this handler runs
  // twice per hover tick, so creating them per call was pure churn.
  EnsureBrushes(dark, c_bg);
  ::FillRect(hdc, &row, g_br_body);

  if (is_separator) {
    // Center the divider on the sheet's OWN center (pinned width, which now
    // equals the client width), with equal blank on both sides. Anchoring it
    // to the row rect is fine only when the row spans the client symmetrically;
    // this form guarantees the line reads centered no matter how the row lands.
    int sheet_w = g_pad_cx;  // separators live in the anchor sheet only
    int content_w = sheet_w;
    int sheet_center = rc.left + content_w / 2;
    int half = (content_w - 2 * 16) / 2;
    if (half < 0) half = 0;
    RECT lr = rc;
    lr.left = sheet_center - half;
    lr.right = sheet_center + half;
    // Center within the row: (rc.bottom - rc.top) / 2 alone is the row's
    // height half, which painted every divider at the very top of the menu.
    lr.top = rc.top + (rc.bottom - rc.top) / 2;
    lr.bottom = lr.top + 1;
    ::FillRect(hdc, &lr, g_br_sep);
    return 1L;
  }

  HFONT use_font = PanelFont(false);
  ::SetBkMode(hdc, TRANSPARENT);
  // Selection pill is the bright blue #469AF6, so text on it must be white
  // for legibility (disabled grey reads fine; the default dark/light text
  // colors would be invisible on the pill).
  COLORREF fg_color = disabled ? c_disabled
                                : (selected ? RGB(0xFF, 0xFF, 0xFF) : c_text);
  ::SetTextColor(hdc, fg_color);
  // CJK characters are already well-spaced; +1px extra reads as
  // visible gaps between letters. Skip it.
  HGDIOBJ old_font = ::SelectObject(hdc, use_font);

  // Measure first: the text_x computation needs the actual rendered
  // label width. GetTextExtentPoint32W returns the FONT advance
  // width (which is reliably close to the visual width for the
  // YaHei UI 13px font we use here - CJK glyphs render close to
  // their advance, Latin glyphs do too at 13px).
  int text_w = 0;
  if (text != nullptr) {
    SIZE tsz = {0, 0};
    ::GetTextExtentPoint32W(hdc, text, (int)wcslen(text), &tsz);
    text_w = tsz.cx;
  }
// State-dot column (right-aligns the dot at rc.left + 36). The leading dot
  // was too close to the left sheet edge; moving the mark column right keeps
  // the dot off the border while the label stays centered.
  const int kMarkColumnRight = 36;
  // All rows share one center axis: the popup (submenu) row must center
  // within the exact same full row width as every other row. Clamping it to
  // menu_item_width_ made it sit left of the common center whenever the real
  // Center the label in the SHEET (not in rcItem, which can be
  // narrower than the sheet on sub menus). sheet_cl is the cached
  // client width; fall back to rcItem when the cache is empty. We
  // measure with GetTextExtentPoint32W which returns the font's advance
  // width (close to visual for YaHei UI 13px), and size text_rc to
  // the same width so the right edge is tight to the visual glyphs.
  int center_w = sheet_cl > 0 ? sheet_cl : (rc.right - rc.left);
  // Plan B: center dot column + gap + label as one block.
  const int kMarkGap = 6;
  // Soft centering offset: 4px right of plain center.
  int text_x = 0 + ((center_w - text_w) / 2) +
                   ((kMarkColumnRight + kMarkGap) / 4);
  if (text_x < kMarkColumnRight + kMarkGap) text_x = kMarkColumnRight + kMarkGap;

  // Rounded hover highlight: keep a visible 6px margin on both sides.
  // The same geometry is used by the GDI+ and GDI paths so the fallback does
  // not unexpectedly produce a wider pill.
  if (selected && !disabled) {
    if (g_gdiplus_ready) {
      using namespace Gdiplus;
      Graphics g(hdc);
      g.SetSmoothingMode(SmoothingModeAntiAlias);
      int x0 = row.left + 6, y0 = row.top, x1 = row.right - 6, y1 = row.bottom;
      const REAL r = 10.0f;
      g.SetClip(Rect(x0, y0, x1 - x0, y1 - y0), CombineModeIntersect);
      GraphicsPath path;
      path.AddArc(static_cast<REAL>(x0),     static_cast<REAL>(y0),  r, r, 180, 90);
      path.AddArc(static_cast<REAL>(x1 - r), static_cast<REAL>(y0),  r, r, 270, 90);
      path.AddArc(static_cast<REAL>(x1 - r), static_cast<REAL>(y1 - r), r, r, 0, 90);
      path.AddArc(static_cast<REAL>(x0),     static_cast<REAL>(y1 - r), r, r, 90, 90);
      path.CloseFigure();
      const COLORREF cr = c_hover;
      SolidBrush br(Color(255,
                         static_cast<BYTE>(cr & 0xFF),
                         static_cast<BYTE>((cr >> 8) & 0xFF),
                         static_cast<BYTE>((cr >> 16) & 0xFF)));
      g.FillPath(&br, &path);
    } else {
      RECT hr = row;
      hr.left += 6;
      hr.right -= 6;
      HGDIOBJ old_brush = ::SelectObject(hdc, g_br_hover);
      HGDIOBJ old_pen = ::SelectObject(hdc, (HPEN)::GetStockObject(NULL_PEN));
      ::RoundRect(hdc, hr.left, hr.top, hr.right, hr.bottom, 10, 10);
      ::SelectObject(hdc, old_pen);
      ::SelectObject(hdc, old_brush);
    }
  }

  // text_rc spans exactly the label's visual width (text_w = advance
  // width from GetTextExtentPoint32W) and is centered in the sheet.
  // Setting text_rc.right = text_rc.left + text_w keeps the right
  // edge tight to the visual glyphs rather than stretching it to the
  // panel edge, so the right-most pixel of the text sits where the
  // advance says it does - not flush against the panel border.
  RECT text_rc = row;
  text_rc.left = text_x;

  if (checked || is_popup) {
    // V2rayN-style solid dot (U+25CF, ClearType-smooth). Submenu rows
    // also carry the leading dot - matches the reference layout where
    // submenu lines look identical to other marked items.
    RECT dot_rc = row;
    dot_rc.left = row.left + kMarkColumnRight - 14;
    dot_rc.right = row.left + kMarkColumnRight;
    ::DrawTextW(hdc, L"\x25CF", 1, &dot_rc,
                DT_SINGLELINE | DT_VCENTER | DT_RIGHT | DT_NOPREFIX);
  }

  if (is_popup) {
    // No chevron: the leading dot is the only mark for submenu rows.
  }

  if (text != nullptr) {
    ::DrawTextW(hdc, text, -1, &text_rc,
                DT_SINGLELINE | DT_VCENTER | DT_NOPREFIX | DT_WORD_ELLIPSIS);
  }

  // DrawItem completes and the menu manager will then paint the system
  // submenu arrow at this row's right edge. We don't have a hook after the
  // arrow is painted, so we instead RE-RECT the menu window right after our
  // own paint: clip the row's right strip to transparent (via the LAYERED
  // region's hole) and let the panel's rounded region show through. This
  // needs the popup row's rect cached so we can punch a matching hole.
  // The cover-arrow strip mechanism was removed: it raced the pill
  // rectangle and produced residual blue bands. Submenu rows now
  // rely on the leading dot as their only mark.

  ::SelectObject(hdc, old_font);
  // Re-render ONLY the sheet this DrawItem belongs to; the other sheet's rows
  // did not change, and re-rendering it on every hover tick wasted time.
  if (g_self != nullptr) {
    HWND sheet = (menu == g_anchor_hmenu) ? g_anchor_hwnd : g_sub_hwnd;
    g_self->RefreshCurtains(sheet);
  }
  return 1L;
}

bool TrayManagerPlugin::CollectMenuView(HMENU menu,
                                        std::vector<CurtainRow>& out) {
  out.clear();
  if (menu == nullptr) return false;
  const int cnt = ::GetMenuItemCount(menu);
  if (cnt <= 0) return false;
  out.resize(static_cast<size_t>(cnt));
  auto& captures = g_row_rects[menu];
  const bool have_captures = captures.size() == static_cast<size_t>(cnt);
  UINT_PTR sel_code = 0;
  auto sit = g_sel_key.find(menu);
  if (sit != g_sel_key.end()) sel_code = sit->second;
  int fallback_y = 0;
  for (int i = 0; i < cnt; ++i) {
    MENUITEMINFO mii = {sizeof(mii)};
    mii.fMask = MIIM_TYPE | MIIM_STATE | MIIM_SUBMENU | MIIM_DATA | MIIM_ID;
    if (!::GetMenuItemInfo(menu, i, TRUE, &mii)) continue;
    CurtainRow& row = out[static_cast<size_t>(i)];
    row.separator = (mii.fType & MFT_SEPARATOR) != 0;
    const int rh = row.separator ? 18 : 30;
    if (have_captures && captures[static_cast<size_t>(i)].bottom >
                         captures[static_cast<size_t>(i)].top) {
      row.rc = captures[static_cast<size_t>(i)];
    } else {
      // Capture fills one row per DrawItem; a not-yet-measured row keeps its
      // placeholder rect so the panel renders fully in the first frame
      // instead of popping rows in one-by-one.
      RECT rc = {0, fallback_y, 0, fallback_y + rh};
      row.rc = rc;
    }
    fallback_y += rh;
    row.popup = (mii.hSubMenu != nullptr);
    row.checked = (mii.fState & MFS_CHECKED) != 0;
    row.disabled = (mii.fState & (MFS_DISABLED | MFS_GRAYED)) != 0;
    if (row.popup) {
      auto pit = popup_ids_.find(reinterpret_cast<UINT_PTR>(mii.hSubMenu));
      if (pit != popup_ids_.end()) {
        auto lit = item_labels_.find(pit->second);
        if (lit != item_labels_.end()) row.label = lit->second;
      }
      if (sel_code != 0 &&
          sel_code == reinterpret_cast<UINT_PTR>(mii.hSubMenu))
        row.selected = true;
    } else {
      auto lit = item_labels_.find(static_cast<UINT_PTR>(mii.wID));
      if (lit != item_labels_.end()) row.label = lit->second;
      if (sel_code != 0 && sel_code == static_cast<UINT_PTR>(mii.wID))
        row.selected = true;
    }
  }
  return true;
}

void TrayManagerPlugin::RefreshCurtains(HWND sheet) {
  if (sheet == nullptr) return;
  HWND ov = (HWND)::GetPropW(sheet, kOverlayProp);
  if (ov != nullptr) CurtainRenderFor(sheet, ov);
}

void TrayManagerPlugin::Destroy(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  Shell_NotifyIcon(NIM_DELETE, &nid);
  DestroyIcon(nid.hIcon);
  tray_icon_setted = false;

  result->Success(flutter::EncodableValue(true));
}

void TrayManagerPlugin::SetIcon(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const flutter::EncodableMap& args =
      std::get<flutter::EncodableMap>(*method_call.arguments());

  std::string iconPath =
      std::get<std::string>(args.at(flutter::EncodableValue("iconPath")));

  std::wstring_convert<std::codecvt_utf8_utf16<wchar_t>> converter;

  HICON hIcon = static_cast<HICON>(
      LoadImage(nullptr, (LPCWSTR)(converter.from_bytes(iconPath).c_str()),
                IMAGE_ICON, GetSystemMetrics(SM_CXSMICON),
                GetSystemMetrics(SM_CYSMICON), LR_LOADFROMFILE));

  if (tray_icon_setted) {
    nid.hIcon = hIcon;
    Shell_NotifyIcon(NIM_MODIFY, &nid);
  } else {
    nid.cbSize = sizeof(NOTIFYICONDATA);
    nid.hWnd = GetMainWindow();
    nid.uCallbackMessage = WM_MYMESSAGE;
    nid.hIcon = hIcon;
    nid.uFlags = NIF_MESSAGE | NIF_ICON;
    Shell_NotifyIcon(NIM_ADD, &nid);
    hMenu = CreatePopupMenu();
  }

  niif.cbSize = sizeof(NOTIFYICONIDENTIFIER);
  niif.hWnd = nid.hWnd;
  niif.uID = nid.uID;
  niif.guidItem = GUID_NULL;

  tray_icon_setted = true;

  result->Success(flutter::EncodableValue(true));
}

void TrayManagerPlugin::SetToolTip(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const flutter::EncodableMap& args =
      std::get<flutter::EncodableMap>(*method_call.arguments());

  std::string toolTip =
      std::get<std::string>(args.at(flutter::EncodableValue("toolTip")));

  std::wstring_convert<std::codecvt_utf8_utf16<wchar_t>> converter;
  nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  StringCchCopy(nid.szTip, _countof(nid.szTip),
                converter.from_bytes(toolTip).c_str());
  Shell_NotifyIcon(NIM_MODIFY, &nid);

  result->Success(flutter::EncodableValue(true));
}

void TrayManagerPlugin::SetContextMenu(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const flutter::EncodableMap& args =
      std::get<flutter::EncodableMap>(*method_call.arguments());

  // Build the label/separator maps into temporaries first, then swap them in
  // as a unit. Clearing the live maps up front was the cause of intermittent
  // blank menus: when a rebuild arrived while a menu was open, its pending
  // WM_DRAWITEM found no labels and drew empty background rows. The swap keeps
  // every draw call seeing a complete, consistent map set.
  std::unordered_map<UINT_PTR, std::wstring> new_labels;
  std::unordered_set<UINT_PTR> new_separators;
  std::unordered_set<UINT_PTR> new_submenu_items;
  std::unordered_map<UINT_PTR, UINT_PTR> new_popup_ids;
  hMenu = CreatePopupMenu();
  _CreateMenu(hMenu, std::get<flutter::EncodableMap>(
                         args.at(flutter::EncodableValue("menu"))),
              false, new_labels, new_separators, new_submenu_items,
              new_popup_ids);
  item_labels_.swap(new_labels);
  separator_ids_.swap(new_separators);
  submenu_item_ids_.swap(new_submenu_items);
  popup_ids_.swap(new_popup_ids);

  result->Success(flutter::EncodableValue(true));
}

void TrayManagerPlugin::ShowContextMenuNow() {
  // Re-entrancy guard: a second right-click can arrive before
  // TrackPopupMenu has returned (it blocks while the menu is up). Running two
  // popups concurrently would clobber the shared hook/overlay/global state and
  // crash the app. If a popup is already tracking, just drop the duplicate
  // (the current menu is already visible and modal).
  static bool g_popup_active = false;
  if (g_popup_active) return;
  g_popup_active = true;

  HWND hWnd = GetMainWindow();

  // The menu opens AT THE MOUSE: its top-left corner is the cursor position.
  // Anchoring it to the tray button instead (the previous behaviour) made the
  // panel jump to a fixed spot near the taskbar whenever the user clicked the
  // icon, which is what read as "the menu does not follow the mouse".
  POINT cursorPos;
  ::GetCursorPos(&cursorPos);
  double x = (double)cursorPos.x;
  double y = (double)cursorPos.y;

  // Work area (taskbar excluded) of the monitor the CURSOR is on. Do NOT use
  // std::min/std::max below: windows.h min/max macros conflict.
  RECT work = {0, 0, 0, 0};
  bool have_work = false;
  {
    MONITORINFO mi = {sizeof(MONITORINFO)};
    HMONITOR mon = ::MonitorFromPoint(cursorPos, MONITOR_DEFAULTTONEAREST);
    if (mon != nullptr && ::GetMonitorInfoW(mon, &mi)) {
      work = mi.rcWork;
      have_work = true;
    }
  }
  if (!have_work) {
    have_work = ::SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
  }

  // Theme-matching background for the menu window (submenus included); in
  // dark mode also let DWM drop its border. See MenuFrameCbtProc above.
  const bool dark = IsDarkTheme();
  g_menu_is_dark = dark;
  menu_item_width_ = ComputeMenuWidth();
  HBRUSH back = ::CreateSolidBrush(
      BlendFor(dark, RGB(0xFF, 0xFF, 0xFF), RGB(0x23, 0x23, 0x27)));
  g_menu_bg = BlendFor(dark, RGB(0xFF, 0xFF, 0xFF), RGB(0x23, 0x23, 0x27));
  MENUINFO mi = {sizeof(MENUINFO)};
  mi.fMask = MIM_BACKGROUND | MIM_APPLYTOSUBMENUS;
  mi.hbrBack = back;
  ::SetMenuInfo(hMenu, &mi);

  g_pad_hwnd = nullptr;
  g_anchor_hwnd = nullptr;
  g_anchor_hmenu = hMenu;
  g_sub_hwnd = nullptr;
  g_sub_hmenu = nullptr;
  g_sel_key.clear();
  g_row_rects.clear();
  g_rgn_last_hwnd = nullptr;
  g_rgn_last_cx = 0;
  g_rgn_last_cy = 0;
  g_sheet_cl = 0;
  g_sub_sheet_cl = 0;
  // Canonical visible width: 5px NC padding each side + a little extra so the
  // right edge of the last item is never flush against the sheet, which made
  // the panel read slightly narrow with cramped right room.
  g_pad_cx = menu_item_width_ + 16;
  // Submenu sheet: fixed compact width, aligned with the actual submenu
  // label width (ComputeMenuWidth -> submenu_item_width_, just recalculated
  // above).
  g_sub_cx = submenu_item_width_;

  // Exact panel height, known BEFORE the window exists: owner-draw rows are
  // 30px and dividers 18px (see HandleMeasureItem) and MenuFrameSubProc adds
  // 10px of NC padding. Having the real size up front is what lets us clamp
  // the popup inside the work area instead of letting it hang off the edge.
  {
    int menu_h = 0;
    const int cnt = ::GetMenuItemCount(hMenu);
    for (int i = 0; i < cnt; ++i) {
      MENUITEMINFO mii = {sizeof(MENUITEMINFO)};
      mii.fMask = MIIM_ID;
      if (!::GetMenuItemInfoW(hMenu, i, TRUE, &mii)) continue;
      menu_h += separator_ids_.count(mii.wID) ? 18 : 30;
    }
    g_pad_cy = menu_h + 10;
  }

  // Default placement: the panel's RIGHT edge sits on the cursor and it opens
  // LEFTWARD, matching the Windows tray convention (the tray is in the screen's
  // bottom-right corner, so a rightward-opening panel would run off-screen).
  // `x` is therefore treated as a RIGHT edge from here on. If the panel would
  // cross the work area's left edge there is no room on that side, so it flips
  // and opens rightward from the cursor instead (see the flip test below).
  //
  // Clamp into the work area, keeping an 8px breathing margin. TrackPopupMenu
  // cannot do this for us: the window subclass pins the position on every move
  // pass, which would override the system's own screen-edge adjustment.
  bool stick_left = false;
  if (have_work) {
    const double maxTop = (double)work.bottom - 8.0 - (double)g_pad_cy;
    // Right-aligned: shifting the panel out past the work-area left edge means
    // there is no room to the left of the cursor, so flip to right-opening.
    if (x - (double)g_pad_cx < (double)work.left + 8.0) {
      stick_left = true;
      // Right-opening: the panel's LEFT edge is the cursor; clamp so it does
      // not cross the work area's right edge either (narrow/tall monitors).
      if (x + (double)g_pad_cx > (double)work.right - 8.0) {
        x = (double)work.right - 8.0 - (double)g_pad_cx;
      }
      if (x < (double)work.left + 8.0) x = (double)work.left + 8.0;
    } else {
      // Clamp the RIGHT edge so the panel stays inside the work area.
      if (x > (double)work.right - 8.0) x = (double)work.right - 8.0;
    }
    if (y > maxTop) y = maxTop;
    if (y < (double)work.top + 8.0) y = (double)work.top + 8.0;
  }

  g_anchor_left = static_cast<int>(x);
  g_anchor_top = static_cast<int>(y);
  g_anchor_stick_left = stick_left;
  g_anchor_valid = true;
  g_work_left = have_work ? (int)work.left : 0;
  g_work_right = have_work ? (int)work.right : 0;

  g_menu_cbt_hook = SetWindowsHookEx(WH_CBT, MenuFrameCbtProc, nullptr,
                                     GetCurrentThreadId());
  SetForegroundWindow(hWnd);
  // TPM_TOPALIGN (vertical, unchanged): the panel's TOP edge sits on the
  // cursor and it opens downward.
  //
  // Horizontal: TPM_RIGHTALIGN by default, so the point handed to
  // TrackPopupMenu is the panel's RIGHT edge and the sheet grows LEFTWARD —
  // the Windows tray convention. When the flip test above found no room on the
  // left, TPM_LEFTALIGN is used instead so the sheet grows rightward from the
  // cursor.
  //
  // Note this does NOT affect submenus: those are placed by the subclass in
  // WM_WINDOWPOSCHANGING (flush against the main panel's right edge via
  // g_anchor_hwnd's rect), so they keep opening rightward regardless of which
  // alignment the root panel used.
  //
  // TPM_NOANIMATION (0x4000): the system's grow/fade popup animation shows the
  // sheet starting tiny/half-open and expanding to the pinned size, which reads
  // as a "panel expanding jump". Disabling it makes the first visible frame
  // already the final compact panel.
  const UINT align = TPM_TOPALIGN | (stick_left ? TPM_LEFTALIGN : TPM_RIGHTALIGN);
  TrackPopupMenu(hMenu, align | 0x4000,
                 static_cast<int>(x), static_cast<int>(y), 0, hWnd, NULL);
  UnhookWindowsHookEx(g_menu_cbt_hook);
  g_menu_cbt_hook = nullptr;
  g_anchor_valid = false;
  g_popup_active = false;
  ::DeleteObject(back);
}

void TrayManagerPlugin::PopUpContextMenu(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  ShowContextMenuNow();
  result->Success(flutter::EncodableValue(true));
}

void TrayManagerPlugin::GetBounds(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const flutter::EncodableMap& args =
      std::get<flutter::EncodableMap>(*method_call.arguments());

  if (!tray_icon_setted) {
    result->Success();
    return;
  }

  double devicePixelRatio =
      std::get<double>(args.at(flutter::EncodableValue("devicePixelRatio")));

  RECT rect;
  Shell_NotifyIconGetRect(&niif, &rect);
  flutter::EncodableMap resultMap = flutter::EncodableMap();

  double x = rect.left / devicePixelRatio * 1.0f;
  double y = rect.top / devicePixelRatio * 1.0f;
  double width = (rect.right - rect.left) / devicePixelRatio * 1.0f;
  double height = (rect.bottom - rect.top) / devicePixelRatio * 1.0f;

  resultMap[flutter::EncodableValue("x")] = flutter::EncodableValue(x);
  resultMap[flutter::EncodableValue("y")] = flutter::EncodableValue(y);
  resultMap[flutter::EncodableValue("width")] = flutter::EncodableValue(width);
  resultMap[flutter::EncodableValue("height")] =
      flutter::EncodableValue(height);

  result->Success(flutter::EncodableValue(resultMap));
}

void TrayManagerPlugin::SetDockIconVisible(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  bool visible = true;
  const auto* args = method_call.arguments();
  if (args != nullptr && std::holds_alternative<flutter::EncodableMap>(*args)) {
    const auto& map = std::get<flutter::EncodableMap>(*args);
    if (auto* b = std::get_if<bool>(ValueOrNull(map, "visible"))) {
      visible = *b;
    }
  }

  // ITaskbarList::AddTab/DeleteTab is the only reliable way to show/hide the
  // taskbar button on demand. Owner tricks (GWLP_HWNDPARENT) silently fail:
  // the taskbar only suppresses an owned window while its owner is itself
  // taskbar-visible, which an always-hidden anchor never is.
  //
  // NOTE: WS_EX_TOOLWINDOW is NOT an option here. Flipping it on the main
  // window suppresses the taskbar button but ALSO strips the caption's
  // minimize/maximize buttons (only Close remains), which is a visible
  // regression on the main page.
  HWND hwnd = GetMainWindow();
  ::CoInitialize(nullptr);
  ITaskbarList* taskbar = nullptr;
  HRESULT hr = ::CoCreateInstance(CLSID_TaskbarList, nullptr,
                                  CLSCTX_INPROC_SERVER, IID_ITaskbarList,
                                  reinterpret_cast<void**>(&taskbar));
  if (SUCCEEDED(hr) && taskbar != nullptr) {
    taskbar->HrInit();
    if (visible) {
      taskbar->AddTab(hwnd);
    } else {
      taskbar->DeleteTab(hwnd);
    }
    taskbar->Release();
  }
  ::CoUninitialize();
  result->Success(flutter::EncodableValue(true));
}

void TrayManagerPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name().compare("destroy") == 0) {
    Destroy(method_call, std::move(result));
  } else if (method_call.method_name().compare("setIcon") == 0) {
    SetIcon(method_call, std::move(result));
  } else if (method_call.method_name().compare("setToolTip") == 0) {
    SetToolTip(method_call, std::move(result));
  } else if (method_call.method_name().compare("setContextMenu") == 0) {
    SetContextMenu(method_call, std::move(result));
  } else if (method_call.method_name().compare("popUpContextMenu") == 0) {
    PopUpContextMenu(method_call, std::move(result));
  } else if (method_call.method_name().compare("getBounds") == 0) {
    GetBounds(method_call, std::move(result));
  } else if (method_call.method_name().compare("setDockIconVisible") == 0) {
    SetDockIconVisible(method_call, std::move(result));
  } else {
    result->NotImplemented();
  }
}

}  // namespace

void TrayManagerPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  TrayManagerPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}

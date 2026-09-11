#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <strsafe.h>
#include <propkey.h>
#include <propsys.h>

#include <string>

#include "flutter_window.h"
#include "utils.h"

namespace {

// AppUserModelID used for taskbar grouping. The taskbar button is associated
// with a Start Menu shortcut carrying the same ID, so its tooltip shows
// "EchOS" (and the cloud icon) even though the window title/caption text is
// kept empty.
constexpr const wchar_t kAppUserModelId[] = L"dev.echos.EchOS";

// Creates (if missing) a Start Menu shortcut for the running exe and stamps
// it with the AppUserModelID. Explorer resolves the taskbar icon and hover
// name from this shortcut instead of from the (empty) window title.
void RegisterAppShortcut() {
  wchar_t exe_path[MAX_PATH] = {};
  if (::GetModuleFileNameW(nullptr, exe_path, MAX_PATH) == 0) {
    return;
  }

  wchar_t start_menu[MAX_PATH] = {};
  if (FAILED(::SHGetFolderPathW(nullptr, CSIDL_PROGRAMS, nullptr,
                                SHGFP_TYPE_CURRENT, start_menu))) {
    return;
  }
  std::wstring lnk_path = std::wstring(start_menu) + L"\\EchOS.lnk";
  if (::GetFileAttributesW(lnk_path.c_str()) != INVALID_FILE_ATTRIBUTES) {
    return;
  }

  IShellLinkW* link = nullptr;
  if (FAILED(::CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&link)))) {
    return;
  }

  link->SetPath(exe_path);
  std::wstring exe_dir(exe_path);
  const size_t slash = exe_dir.find_last_of(L"\\/");
  if (slash != std::wstring::npos) {
    exe_dir.resize(slash);
  }
  link->SetWorkingDirectory(exe_dir.c_str());
  link->SetIconLocation(exe_path, 0);
  link->SetDescription(L"EchOS");

  IPropertyStore* store = nullptr;
  if (SUCCEEDED(link->QueryInterface(IID_PPV_ARGS(&store)))) {
    PROPVARIANT pv;
    ::PropVariantInit(&pv);
    pv.vt = VT_LPWSTR;
    const size_t char_count = wcslen(kAppUserModelId) + 1;
    pv.pwszVal = static_cast<LPWSTR>(
        ::CoTaskMemAlloc(char_count * sizeof(wchar_t)));
    if (pv.pwszVal != nullptr) {
      ::StringCchCopyW(pv.pwszVal, char_count, kAppUserModelId);
      store->SetValue(PKEY_AppUserModel_ID, pv);
      store->Commit();
    }
    ::PropVariantClear(&pv);
    store->Release();
  }

  IPersistFile* file = nullptr;
  if (SUCCEEDED(link->QueryInterface(IID_PPV_ARGS(&file)))) {
    file->Save(lnk_path.c_str(), TRUE);
    file->Release();
  }
  link->Release();
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

// Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // Bind the taskbar identity to the Start Menu shortcut (native support for
  // a taskbar name independent of the window caption text). Must be paired
  // with the shortcut above, otherwise Explorer shows a bare button.
  ::SetCurrentProcessExplicitAppUserModelID(kAppUserModelId);
  RegisterAppShortcut();

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"echos", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}

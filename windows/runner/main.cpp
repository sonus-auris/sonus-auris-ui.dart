#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <cwchar>
#include <string>

#include "app_links/app_links_plugin_c_api.h"
#include "flutter_window.h"
#include "utils.h"

namespace {

// Flutter's unpackaged Windows runner has no installer manifest to claim a URL
// protocol. Register the scheme for the current user on normal app startup;
// no administrator access is required and packaged installers may overwrite
// the same association with their declared protocol handler.
void RegisterUrlProtocol(const wchar_t* scheme, const wchar_t* description) {
  wchar_t executable[MAX_PATH];
  const DWORD length = ::GetModuleFileNameW(nullptr, executable, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    return;
  }

  const std::wstring root = std::wstring(L"Software\\Classes\\") + scheme;
  HKEY protocol_key = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, root.c_str(), 0, nullptr, 0,
                        KEY_SET_VALUE, nullptr, &protocol_key,
                        nullptr) != ERROR_SUCCESS) {
    return;
  }
  ::RegSetValueExW(
      protocol_key, nullptr, 0, REG_SZ,
      reinterpret_cast<const BYTE*>(description),
      static_cast<DWORD>((std::wcslen(description) + 1) * sizeof(wchar_t)));
  const wchar_t empty[] = L"";
  ::RegSetValueExW(protocol_key, L"URL Protocol", 0, REG_SZ,
                   reinterpret_cast<const BYTE*>(empty), sizeof(empty));
  ::RegCloseKey(protocol_key);

  const std::wstring command_path = root + L"\\shell\\open\\command";
  HKEY command_key = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, command_path.c_str(), 0, nullptr, 0,
                        KEY_SET_VALUE, nullptr, &command_key,
                        nullptr) != ERROR_SUCCESS) {
    return;
  }
  const std::wstring command =
      std::wstring(L"\"") + executable + L"\" \"%1\"";
  ::RegSetValueExW(
      command_key, nullptr, 0, REG_SZ,
      reinterpret_cast<const BYTE*>(command.c_str()),
      static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  ::RegCloseKey(command_key);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  RegisterUrlProtocol(L"sonusauris", L"URL:Sonus Auris authentication");

  // app_links forwards protocol activation to an already-running recorder.
  // Without this, clicking a magic link while the background recorder is
  // active starts a second process and strands the PKCE verifier in the first.
  if (SendAppLinkToInstance()) {
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Sonus Auris", origin, size)) {
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

#include "flutter_window.h"

#include <dwrite.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <wrl/client.h>

#include <algorithm>
#include <optional>
#include <vector>

#include "desktop_multi_window/desktop_multi_window_plugin.h"
#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

std::vector<std::string> GetSystemFontFamilies() {
  Microsoft::WRL::ComPtr<IDWriteFactory> factory;
  if (FAILED(DWriteCreateFactory(
          DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
          reinterpret_cast<IUnknown**>(factory.GetAddressOf())))) {
    return {};
  }

  Microsoft::WRL::ComPtr<IDWriteFontCollection> collection;
  if (FAILED(factory->GetSystemFontCollection(&collection, FALSE))) {
    return {};
  }

  std::vector<std::string> families;
  for (UINT32 index = 0; index < collection->GetFontFamilyCount(); ++index) {
    Microsoft::WRL::ComPtr<IDWriteFontFamily> family;
    Microsoft::WRL::ComPtr<IDWriteLocalizedStrings> names;
    if (FAILED(collection->GetFontFamily(index, &family)) ||
        FAILED(family->GetFamilyNames(&names))) {
      continue;
    }

    UINT32 name_index = 0;
    BOOL exists = FALSE;
    names->FindLocaleName(L"zh-cn", &name_index, &exists);
    if (!exists) {
      names->FindLocaleName(L"en-us", &name_index, &exists);
    }
    if (!exists) {
      name_index = 0;
    }

    UINT32 length = 0;
    if (FAILED(names->GetStringLength(name_index, &length))) {
      continue;
    }
    std::wstring name(length + 1, L'\0');
    if (FAILED(names->GetString(name_index, name.data(), length + 1))) {
      continue;
    }
    name.resize(length);
    families.push_back(Utf8FromUtf16(name.c_str()));
  }
  std::sort(families.begin(), families.end());
  families.erase(std::unique(families.begin(), families.end()), families.end());
  return families;
}

void RegisterSystemFontsChannel(flutter::FlutterEngine* engine) {
  static std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel;
  channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), "com.feiniu.music/system_fonts",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "getFamilies") {
          result->NotImplemented();
          return;
        }
        flutter::EncodableList values;
        for (const auto& family : GetSystemFontFamilies()) {
          values.emplace_back(family);
        }
        result->Success(flutter::EncodableValue(values));
      });
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  RegisterSystemFontsChannel(flutter_controller_->engine());
  DesktopMultiWindowSetWindowCreatedCallback([](void* controller) {
    auto* flutter_view_controller =
        reinterpret_cast<flutter::FlutterViewController*>(controller);
    RegisterPlugins(flutter_view_controller->engine());
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

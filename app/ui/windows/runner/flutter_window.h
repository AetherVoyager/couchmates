#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#include "win32_window.h"

class FlutterWindow : public Win32Window {
 public:
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam, LPARAM const lparam) noexcept override;

 private:
  flutter::DartProject project_;

  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> window_channel_;

  // Closing the window first lets Dart tell the Hub this device is leaving
  // (couchmates/lifecycle "closing"), so friends see it offline at once.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> lifecycle_channel_;
  bool close_pending_ = false;
  bool close_confirmed_ = false;
  void FinishClose();

  // Fullscreen state tracking for monitor-aware native fullscreen.
  // Maximize state lives inside `placement_before_fullscreen_.showCmd`.
  bool is_fullscreen_ = false;
  WINDOWPLACEMENT placement_before_fullscreen_{};
  LONG_PTR style_before_fullscreen_ = 0;
  LONG_PTR ex_style_before_fullscreen_ = 0;

  void RegisterWindowChannel();
  void SetNativeFullScreen(bool fullscreen);
  void NotifyFullScreenChanged();
};

#endif  // RUNNER_FLUTTER_WINDOW_H_

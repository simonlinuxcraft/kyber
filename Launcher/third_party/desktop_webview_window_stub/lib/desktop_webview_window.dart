// Linux no-op stub for desktop_webview_window.
//
// Keeps the public API surface that flutter_web_auth_2/src/webview.dart imports
// (WebviewWindow, Webview, CreateConfiguration) so the project compiles, but
// performs no native work and links no webkit. On Linux the in-app webview path
// is never taken (patreon_service uses useWebview:false; the EA login uses the
// external system browser), so the stubbed-out methods are never reached.
library desktop_webview_window;

import 'dart:async';

import 'src/create_configuration.dart';
import 'src/webview.dart';

export 'src/create_configuration.dart';
export 'src/webview.dart';

class WebviewWindow {
  /// Always false on this Linux stub: there is no bundled webview runtime.
  static Future<bool> isWebviewAvailable() async => false;

  static Future<Webview> create({CreateConfiguration? configuration}) {
    throw UnsupportedError(
      'desktop_webview_window is stubbed out on Linux (no bundled webkit2gtk).',
    );
  }

  static Future<void> clearAll({
    String userDataFolderWindows = 'webview_window_WebView2',
  }) async {}
}

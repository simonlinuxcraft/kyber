// No-op Linux stub for desktop_webview_window. Lets `flutter build linux`
// succeed and link no webkit. Any runtime call from Dart is a no-op; the Linux
// code paths that would use a webview never run (useWebview:false / external
// browser login).

#include "include/desktop_webview_window/desktop_webview_window_plugin.h"

#include <flutter_linux/flutter_linux.h>

struct _WebviewWindowPlugin {
  GObject parent_instance;
};

G_DEFINE_TYPE(WebviewWindowPlugin, webview_window_plugin, G_TYPE_OBJECT)

static void webview_window_plugin_class_init(WebviewWindowPluginClass* klass) {}

static void webview_window_plugin_init(WebviewWindowPlugin* self) {}

void desktop_webview_window_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  (void)registrar;
}

// Stub implementation of flutter_inappwebview_linux for Ubuntu 24.04+.
// The upstream plugin requires WPE WebKit, which is not packaged for
// Ubuntu 24.04. This stub allows `flutter build linux` to succeed.
// Any runtime call into the plugin from Dart will be a no-op or surface
// as an unimplemented method-channel error.

#include "include/flutter_inappwebview_linux/flutter_inappwebview_linux_plugin.h"

#include <flutter_linux/flutter_linux.h>

struct _FlutterInappwebviewLinuxPlugin {
  GObject parent_instance;
};

G_DEFINE_TYPE(FlutterInappwebviewLinuxPlugin,
              flutter_inappwebview_linux_plugin,
              G_TYPE_OBJECT)

static void flutter_inappwebview_linux_plugin_class_init(
    FlutterInappwebviewLinuxPluginClass* klass) {}

static void flutter_inappwebview_linux_plugin_init(
    FlutterInappwebviewLinuxPlugin* self) {}

void flutter_inappwebview_linux_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  (void)registrar;
}

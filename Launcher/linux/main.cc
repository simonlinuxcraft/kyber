#include "my_application.h"

#include <glib.h>

int main(int argc, char** argv) {
  // Pin g_get_prgname() so the WM_CLASS instance name is independent of
  // argv[0] (the AppImage runtime renames the binary to AppRun.wrapped,
  // which would otherwise leak into the X11 WM_CLASS and break taskbar
  // icon matching against StartupWMClass=kyber-linux in the .desktop file).
  g_set_prgname("kyber-linux");
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}

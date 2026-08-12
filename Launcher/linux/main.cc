#include "my_application.h"

#include <glib.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char** argv) {
  // Pin g_get_prgname() so the WM_CLASS instance name is independent of
  // argv[0] (the AppImage runtime renames the binary to AppRun.wrapped,
  // which would otherwise leak into the X11 WM_CLASS and break taskbar
  // icon matching against StartupWMClass=kyber-linux in the .desktop file).
  g_set_prgname("kyber-linux");
  g_autoptr(MyApplication) app = my_application_new();
  int status = g_application_run(G_APPLICATION(app), argc, argv);

  // KYBER-LINUX-PORT-MOD 2026-08-12: leave without running the atexit handlers.
  // On NVIDIA, libEGL_nvidia segfaults inside its own exit handler after main
  // has already returned 0 (backtrace: __run_exit_handlers -> libEGL_nvidia ->
  // libnvidia-eglcore), so every normal quit ended as signal 11 and left a
  // crashpad minidump in the working directory. Everything of ours is done by
  // this point; only the flush is still owed.
  fflush(nullptr);
  _exit(status);
}

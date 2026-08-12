#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

// Compile default for the renderer. Stays on the engine default (Impeller since
// fa137457bad, June 2026): it is faster than Skia on a dedicated GPU and slower
// on a weak iGPU, so there is no default that suits everyone. Affected users
// switch with KYBER_RENDERER=skia.
#define KYBER_DEFAULT_SKIA FALSE

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Locate the bundled Kyber PNG icon by probing well-known paths relative
// to the running executable. Returns a heap-allocated absolute path, or
// NULL if no icon was found. Caller must g_free() the result.
static gchar* locate_bundled_icon() {
  // Candidate paths, tried in order. First match wins.
  // 1. Honor $APPDIR (set by AppImage AppRun) → AppDir root.
  // 2. Two levels up from the executable (bundle layout: usr/bin/<exe>,
  //    icon at AppDir root).
  // 3. Next to the executable (dev/.deb layout).
  const gchar* appdir_env = g_getenv("APPDIR");
  gchar* exe = g_file_read_link("/proc/self/exe", NULL);
  gchar* exe_dir = exe != NULL ? g_path_get_dirname(exe) : NULL;
  gchar* up_one = exe_dir != NULL ? g_path_get_dirname(exe_dir) : NULL;
  gchar* up_two = up_one != NULL ? g_path_get_dirname(up_one) : NULL;

  const gchar* candidates_dirs[] = {
      appdir_env,
      up_two,
      exe_dir,
      NULL,
  };
  const gchar* names[] = {"kyber-linux.png", "kyber-icon.png", NULL};

  gchar* found = NULL;
  for (int i = 0; candidates_dirs[i] != NULL && found == NULL; ++i) {
    for (int j = 0; names[j] != NULL && found == NULL; ++j) {
      gchar* p = g_build_filename(candidates_dirs[i], names[j], NULL);
      if (g_file_test(p, G_FILE_TEST_IS_REGULAR)) {
        found = p;
      } else {
        g_free(p);
      }
    }
  }
  g_free(exe);
  g_free(exe_dir);
  g_free(up_one);
  g_free(up_two);
  return found;
}

// Whether to force the Skia renderer instead of the engine default. Impeller's
// GLES backend is heavier on weak iGPUs, so this stays switchable at runtime.
// Precedence: KYBER_RENDERER env, then ~/.config/kyber-linuxport/renderer,
// then the compile default. Recognised value is "skia"; anything else means
// Impeller.
static gboolean use_skia_renderer() {
  const gchar* env = g_getenv("KYBER_RENDERER");
  if (env != NULL && *env != '\0') {
    return g_ascii_strcasecmp(env, "skia") == 0;
  }

  g_autofree gchar* pref = g_build_filename(
      g_get_user_config_dir(), "kyber-linuxport", "renderer", NULL);
  g_autofree gchar* contents = NULL;
  if (g_file_get_contents(pref, &contents, NULL, NULL)) {
    return g_ascii_strcasecmp(g_strstrip(contents), "skia") == 0;
  }

  return KYBER_DEFAULT_SKIA;
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  // Set the X11 WM_CLASS res_class to "kyber-linux" so window managers can
  // associate the window with kyber-linux.desktop via StartupWMClass, which
  // is what makes the proper Kyber icon show in the taskbar.
  gdk_set_program_class("kyber-linux");

  // Pre-set the GTK default icon from a bundled PNG. Without this, GTK
  // falls back to looking up the prgname in the active icon theme on first
  // window-realize and then to "image-missing", which can crash the process
  // on systems whose user theme uses SVG fallbacks but lacks an SVG pixbuf
  // loader on the GdkPixbuf module path. Loading from an absolute file path
  // bypasses the icon theme entirely.
  {
    gchar* icon_path = locate_bundled_icon();
    if (icon_path != NULL) {
      GError* err = NULL;
      if (!gtk_window_set_default_icon_from_file(icon_path, &err)) {
        g_warning("Failed to set default window icon from %s: %s",
                  icon_path, err != NULL ? err->message : "unknown");
        g_clear_error(&err);
      }
      g_free(icon_path);
    }
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Kyber (Linux Port)");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Kyber (Linux Port)");
  }

  gtk_window_set_default_size(window, 1280, 720);
  gtk_widget_realize(GTK_WIDGET(window));

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  gboolean skia = use_skia_renderer();
  if (skia) {
    fl_dart_project_set_enable_impeller(project, FALSE);
  }
  g_message("Renderer: %s", skia ? "skia" : "impeller");
  fl_dart_project_set_dart_entrypoint_arguments(project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application, gchar*** arguments, int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
     g_warning("Failed to register: %s", error->message);
     *exit_status = 1;
     return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  //MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  //MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line = my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID,
                                     "flags", G_APPLICATION_NON_UNIQUE,
                                     nullptr));
}

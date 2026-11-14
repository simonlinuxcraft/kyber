// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 simonlinuxcraft

import 'dart:io';

/// The environment for host programs started from the launcher. Inside the
/// AppImage it carries LD_LIBRARY_PATH, GTK_* and an XDG_DATA_DIRS that point
/// into the bundle, which makes xdg-open on KDE or SteamOS pick Discover
/// instead of the browser and lets host tools load bundled libraries.
Map<String, String> hostEnvironment() {
  final env = Map<String, String>.from(Platform.environment);
  final appdir = env['APPDIR'] ?? '';
  final orig = env['KYBER_ORIG_XDG_DATA_DIRS'];
  final base = (orig != null && orig.isNotEmpty)
      ? orig
      : (env['XDG_DATA_DIRS'] ?? '');
  final dirs = <String>[
    for (final d in base.split(':'))
      if (d.isNotEmpty && (appdir.isEmpty || !d.startsWith(appdir))) d,
  ];
  final home = env['HOME'];
  if (home != null && home.isNotEmpty) {
    dirs.add('$home/.local/share/flatpak/exports/share');
  }
  dirs.addAll(const [
    '/var/lib/flatpak/exports/share',
    '/usr/local/share',
    '/usr/share',
  ]);
  final seen = <String>{};
  env['XDG_DATA_DIRS'] = dirs.where(seen.add).join(':');
  for (final k in const [
    'GTK_PATH',
    'GDK_PIXBUF_MODULE_FILE',
    'GTK_IM_MODULE_FILE',
    'GI_TYPELIB_PATH',
    'GSETTINGS_SCHEMA_DIR',
    'GTK_EXE_PREFIX',
    'GTK_DATA_PREFIX',
    'GTK_THEME',
    'GDK_BACKEND',
    'LD_LIBRARY_PATH',
  ]) {
    env.remove(k);
  }
  return env;
}

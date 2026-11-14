// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 simonlinuxcraft

import 'dart:io';

import 'package:kyber_launcher/features/settings/screens/settings_list.dart';
import 'package:kyber_launcher/gen/rust/api/maxima.dart';

String protonLabel() {
  final active = getActiveProton();
  final origin = switch (active.origin) {
    'custom' => 'custom path',
    'detected' => 'found on this system',
    'managed' => 'managed by Kyber',
    'download' => 'downloads on next launch',
    _ => active.origin,
  };
  return '${active.tag} ($origin)';
}

// Same rule as maxima_dir(): XDG_DATA_HOME wins whenever it is set.
String get _dataHome =>
    Platform.environment['XDG_DATA_HOME'] ??
    '${Platform.environment['HOME']}/.local/share';

/// What a bug report needs to know about this machine, in display order.
Map<String, String> linuxStatus() {
  final env = Platform.environment;
  final maxima = '$_dataHome/maxima';
  final session = [
    env['XDG_CURRENT_DESKTOP'],
    env['XDG_SESSION_TYPE'],
    if (env['GDK_BACKEND'] case final b?) 'launcher on $b',
  ].whereType<String>().where((s) => s.isNotEmpty).join(', ');
  final umuReady =
      File('$maxima/wine/umu/umu-run').existsSync() &&
      Directory('$_dataHome/umu/steamrt3').existsSync();
  return {
    'Launcher': '$kLinuxPortVersion, ${_channel()}',
    'System': osRelease('PRETTY_NAME') ?? 'unknown',
    'Session': session.isEmpty ? 'unknown' : session,
    'Proton': protonLabel(),
    'Wine prefix': _prefixKind('$maxima/wine/prefix'),
    'umu runtime': umuReady ? 'installed' : 'downloads on first launch',
    'GameMode': _onPath('gamemoderun') ? 'installed' : 'not installed',
  };
}

String _channel() {
  if (Platform.environment['APPIMAGE'] != null) return 'AppImage';
  if (Platform.resolvedExecutable.startsWith('/opt/')) return 'package';
  return 'tar.gz';
}

/// A field of /etc/os-release, falling back to /usr/lib/os-release.
String? osRelease(String key) {
  for (final path in ['/etc/os-release', '/usr/lib/os-release']) {
    try {
      for (final line in File(path).readAsLinesSync()) {
        if (line.startsWith('$key=')) {
          return line.substring(key.length + 1).replaceAll('"', '');
        }
      }
      return null;
    } on FileSystemException {
      continue;
    } on FormatException {
      return null; // not UTF-8
    }
  }
  return null;
}

String _prefixKind(String path) {
  final link = Link(path);
  if (link.existsSync()) {
    return link.targetSync().contains('/compatdata/')
        ? 'Steam (Battlefront II)'
        : 'Kyber standalone';
  }
  return Directory(path).existsSync() ? 'Kyber standalone' : 'not set up yet';
}

bool _onPath(String name) => (Platform.environment['PATH'] ?? '')
    .split(':')
    .any((dir) => dir.isNotEmpty && File('$dir/$name').existsSync());

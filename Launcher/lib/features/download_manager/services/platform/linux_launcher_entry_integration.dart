// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 simonlinuxcraft

import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:kyber_launcher/features/download_manager/services/platform/download_platform_integration.dart';

/// Download progress on the dock icon through the Unity LauncherEntry signal,
/// which dash-to-dock, dash-to-panel and KDE Plasma show. GNOME's own dash
/// ignores it.
class LinuxLauncherEntryIntegration implements DownloadPlatformIntegration {
  const LinuxLauncherEntryIntegration();

  static DBusClient? _bus;
  static int _lastPercent = -1;

  @override
  Future<void> updateProgress(double progress) async {
    if (progress < 0 || progress > 1) return;
    // Progress arrives far more often than a dock icon can show a change.
    final percent = (progress * 100).toInt();
    if (percent == _lastPercent) return;
    _lastPercent = percent;
    await _send({
      'progress': DBusDouble(progress),
      'progress-visible': const DBusBoolean(true),
    });
  }

  // LauncherEntry has no indeterminate state.
  @override
  Future<void> setIndeterminate() async {}

  @override
  Future<void> clear() async {
    _lastPercent = -1;
    await _send({'progress-visible': const DBusBoolean(false)});
  }

  Future<void> _send(Map<String, DBusValue> properties) async {
    final id = _desktopId();
    if (id == null) return;
    try {
      _bus ??= DBusClient.session();
      await _bus!.emitSignal(
        path: DBusObjectPath('/io/github/simonlinuxcraft/kyber'),
        interface: 'com.canonical.Unity.LauncherEntry',
        name: 'Update',
        values: [
          DBusString('application://$id'),
          DBusDict.stringVariant(properties),
        ],
      );
      // No session bus or a broken one; the dock is only a nicety.
      // ignore: avoid_catches_without_on_clauses
    } catch (_) {}
  }

  static const _menuEntries = {
    'kyber-linuxport.desktop',
    'kyber-linuxport-bin.desktop',
    'kyber-linux.desktop',
  };

  // The menu entry the dock knows the window by. GIO names it when the entry
  // started the launcher; a terminal or the nxm handler can also set it.
  static String? _desktopId() {
    final launched = Platform.environment['GIO_LAUNCHED_DESKTOP_FILE'];
    final name = launched?.split('/').last;
    if (_menuEntries.contains(name)) return name;
    if (Platform.environment['APPIMAGE'] != null) {
      return 'kyber-linuxport.desktop';
    }
    final exe = Platform.resolvedExecutable;
    if (exe.startsWith('/opt/kyber-linuxport-bin/')) {
      return 'kyber-linuxport-bin.desktop';
    }
    if (exe.startsWith('/opt/kyber/')) return 'kyber-linux.desktop';
    return null;
  }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 simonlinuxcraft

import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:kyber_launcher/core/services/appimage_update_service.dart';
import 'package:kyber_launcher/core/services/linux_status.dart';
import 'package:kyber_launcher/core/services/notification_service.dart';
import 'package:kyber_launcher/core/utils/host_environment.dart';
import 'package:kyber_launcher/gen/fonts.gen.dart';
import 'package:kyber_launcher/shared/ui/buttons/button.dart';
import 'package:kyber_launcher/shared/ui/dialog/kyber_dialog.dart';
import 'package:logging/logging.dart';

Future<void>? _running;

/// The menu entry question and the one-time notes for the Steam Deck and for
/// Arch, once per start. Runs before the first EA login, because the menu
/// entry also registers the qrc:// handler the login returns through.
Future<void> linuxFirstStart(BuildContext context) => _running ??= () async {
  final home = Platform.environment['HOME'];
  if (home == null) return;
  // The AppRun hooks that used to show these with zenity kept their markers
  // here, so a note seen before stays seen.
  final stateDir = '$home/.local/share/kyber-linuxport';
  try {
    await _offerMenuEntry(context, stateDir);
    if (context.mounted) await _steamDeckNote(context, stateDir);
    if (context.mounted) await _archPackagesNote(context, stateDir);
    // A broken marker or os-release must not keep the user from logging in.
    // ignore: avoid_catches_without_on_clauses
  } catch (e, s) {
    Logger('linux_first_start').warning('First start notes failed', e, s);
  }
}();

Future<void> _offerMenuEntry(BuildContext context, String stateDir) async {
  final env = Platform.environment;
  final appImage = env['APPIMAGE'];
  final appDir = env['APPDIR'];
  if (appImage == null || appDir == null) return;
  if (AppImageUpdateService.isPackagedContext) return;
  // APPIMAGE and APPDIR can be inherited from another AppImage, a terminal
  // for example, when the tar.gz is started from it.
  final hook = '$appDir/apprun-hooks/kyber-self-install.sh';
  if (!Platform.resolvedExecutable.startsWith(appDir)) return;
  if (!File(hook).existsSync()) return;
  if (File('$stateDir/.installed-version').existsSync()) return;
  // Same id as the hook: size and mtime of the AppImage.
  final stat = File(appImage).statSync();
  final id = '${stat.size}-${stat.modified.millisecondsSinceEpoch ~/ 1000}';
  final declined = File('$stateDir/.declined-version');
  if (declined.existsSync() && declined.readAsStringSync().trim() == id) {
    return;
  }

  final add = await _ask(
    context,
    'Add Kyber to your applications?',
    'Copies the AppImage to ~/Applications and adds Kyber to the application '
        'menu, together with the handler the EA login returns through. '
        'Without it the login needs the paste field.',
    yes: 'Add',
    no: 'Not now',
  );
  // Closed with Esc or a click outside: ask again next start.
  if (add == null) return;
  final result = await Process.run(
    'bash',
    ['-c', r'source "$1"', '_', hook],
    environment: {
      ...hostEnvironment(),
      'KYBER_SELF_INSTALL': add ? 'yes' : 'no',
    },
    includeParentEnvironment: false,
  );
  if (!add) return;
  if (result.exitCode == 0 &&
      File('$stateDir/.installed-version').existsSync()) {
    NotificationService.success(message: 'Kyber is in your applications now');
  } else {
    NotificationService.error(
      message: 'Could not add Kyber to your applications',
    );
  }
}

Future<void> _steamDeckNote(BuildContext context, String stateDir) async {
  final env = Platform.environment;
  final deck =
      env['SteamDeck'] == '1' ||
      (env['SteamOS'] ?? '').isNotEmpty ||
      osRelease('ID') == 'steamos';
  if (!deck) return;
  final marker = File('$stateDir/.steamdeck-hint-shown');
  if (marker.existsSync()) return;
  await _ask(
    context,
    'Steam Deck',
    'Use Desktop Mode for the launcher.\n\n'
        'The EA sign-in opens in your browser. On the Steam Deck that is '
        'usually a Flatpak app, which does not hand the login back to the '
        'launcher, so it can look stuck. Then sign in, copy the link or code '
        'the browser tried to open and paste it into the field under '
        '"Browser did not return to the launcher?" on the login screen.',
  );
  marker
    ..createSync(recursive: true)
    ..writeAsStringSync('');
}

// winegstreamer needs bad, ugly and libav for the Origin login splash;
// vulkan-tools brings vulkaninfo for bug reports.
Future<void> _archPackagesNote(BuildContext context, String stateDir) async {
  final id = osRelease('ID');
  final like = ' ${osRelease('ID_LIKE') ?? ''} ';
  if (id == 'steamos') return; // read-only root, pacman is no option there
  if (id != 'arch' && !like.contains(' arch ')) return;
  const packages = [
    'gst-plugins-bad',
    'gst-plugins-ugly',
    'gst-libav',
    'vulkan-tools',
  ];
  final missing = <String>[];
  for (final pkg in packages) {
    try {
      // 1 means not installed; anything else is pacman itself failing.
      final r = await Process.run('pacman', ['-Qq', pkg]);
      if (r.exitCode == 1) missing.add(pkg);
    } on ProcessException {
      return;
    }
  }
  if (missing.isEmpty) return;
  // The marker holds the set last shown, so a changed set is shown again.
  final set = missing.join(' ');
  final marker = File('$stateDir/.cachyos-hint-shown');
  if (marker.existsSync() && marker.readAsStringSync().trim() == set) return;
  if (!context.mounted) return;
  await _ask(
    context,
    'Optional packages missing',
    'Kyber works without them, but Battlefront II may show a static logo '
        'instead of the Origin login splash, and vulkan-tools is only needed '
        'for vulkaninfo in bug reports. To install them, run:\n\n'
        'sudo pacman -S --needed $set',
  );
  marker
    ..createSync(recursive: true)
    ..writeAsStringSync(set);
}

/// True or false for the two buttons, null when the dialog was dismissed.
Future<bool?> _ask(
  BuildContext context,
  String title,
  String text, {
  String yes = 'OK',
  String? no,
}) {
  return showKyberDialog<bool>(
    context: context,
    builder: (context) => KyberContentDialog(
      constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
      title: Text(title.toUpperCase()),
      content: SingleChildScrollView(
        child: Text(
          text,
          style: const TextStyle(
            fontFamily: FontFamily.battlefrontUI,
            fontSize: 17,
          ),
        ),
      ),
      actions: [
        KyberButton(
          text: yes,
          onPressed: () => Navigator.of(context).pop(true),
        ),
        if (no != null)
          KyberButton(
            text: no,
            onPressed: () => Navigator.of(context).pop(false),
          ),
      ],
    ),
  );
}

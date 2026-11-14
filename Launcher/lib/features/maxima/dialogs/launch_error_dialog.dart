// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 simonlinuxcraft

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:kyber_launcher/core/routing/app_router.dart';
import 'package:kyber_launcher/features/maxima/dialogs/custom_proton_path_dialog.dart';
import 'package:kyber_launcher/gen/fonts.gen.dart';
import 'package:kyber_launcher/shared/ui/buttons/button.dart';
import 'package:kyber_launcher/shared/ui/dialog/kyber_dialog.dart';

/// Launch errors on Linux are mostly about Proton or the Wine prefix, and
/// their instructions are too long for a toast.
class LaunchErrorDialog extends StatelessWidget {
  factory LaunchErrorDialog(String error) {
    final message = error.split('Stack backtrace:').first.trim();
    if (message.contains('custom proton path')) {
      // The Rust text says "no wine64 found", which is wrong for builds that
      // ship only `wine`. Usually the folder is gone.
      final path = RegExp('`"(.*)"`').firstMatch(message)?.group(1) ?? '';
      return LaunchErrorDialog._(
        'Proton build not found',
        'The Proton build selected in Settings > Mods / Proton / Wayland > '
            'Proton Build is missing or incomplete:\n\n$path\n\n'
            'Pick another build or reset it to the default.',
        message,
        proton: true,
      );
    }
    if (message.contains('No Steam Proton prefix')) {
      return LaunchErrorDialog._('No Proton prefix found', message, message);
    }
    if (message.startsWith('setup_wine_registry')) {
      return LaunchErrorDialog._(
        'Game did not start',
        "Wine did not start in the game's prefix, so Kyber could not write "
            'the registry entries Battlefront II needs. Try again. If it keeps '
            'failing, export the logs under Settings > Logs & Activity.',
        message,
      );
    }
    return LaunchErrorDialog._(
      'Game did not start',
      message,
      message,
      proton: message.startsWith('No Proton build found'),
    );
  }

  const LaunchErrorDialog._(
    this.title,
    this.text,
    this.error, {
    this.proton = false,
  });

  final String title;
  final String text;
  final String error;
  final bool proton;

  @override
  Widget build(BuildContext context) {
    return KyberContentDialog(
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
        if (proton)
          KyberButton(
            text: 'Change Proton build',
            onPressed: () {
              Navigator.of(context).pop();
              showKyberDialog(
                context: navigatorKey.currentContext!,
                builder: (_) => const CustomProtonPathDialog(),
              );
            },
          ),
        KyberButton(
          text: 'Copy error',
          onPressed: () => Clipboard.setData(ClipboardData(text: error)),
        ),
        KyberButton(
          text: 'Close',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

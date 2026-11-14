// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 simonlinuxcraft

import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:kyber_launcher/core/config/colors.dart';
import 'package:kyber_launcher/core/services/app_settings.dart';
import 'package:kyber_launcher/features/settings/screens/settings_list.dart';
import 'package:kyber_launcher/main.dart';
import 'package:kyber_launcher/shared/ui/buttons/button.dart';
import 'package:kyber_launcher/shared/ui/dialog/kyber_dialog.dart';

/// Shows this build's CHANGELOG section once after an update. A fresh
/// install has nothing to compare against and only records the version.
Future<void> showWhatsNew(BuildContext context) async {
  if (box.get('linuxPortVersion') == kLinuxPortVersion) return;
  final updated = Preferences.general.currentVersion != null;
  await box.put('linuxPortVersion', kLinuxPortVersion);
  final section = _changelogSection(kLinuxPortVersion);
  if (!updated || section == null || !context.mounted) return;
  await showKyberDialog(
    context: context,
    builder: (_) => WhatsNewDialog(section),
  );
}

// AppImage, tar.gz and the bin package keep the docs next to the binary, the
// AUR package under /usr/share.
List<String>? _changelogSection(String version) {
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  for (final path in [
    '$exeDir/../share/doc/kyber-linux/CHANGELOG.md',
    '/usr/share/doc/kyber-linux/CHANGELOG.md',
  ]) {
    final file = File(path);
    if (!file.existsSync()) continue;
    final lines = file.readAsLinesSync();
    final start = lines.indexWhere((l) => l.startsWith('## [$version]'));
    if (start < 0) return null;
    final end = lines.indexWhere((l) => l.startsWith('## ['), start + 1);
    return lines.sublist(start + 1, end < 0 ? lines.length : end);
  }
  return null;
}

class WhatsNewDialog extends StatelessWidget {
  const WhatsNewDialog(this.lines, {super.key});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    // The file wraps bullets at 76 columns, joined back into one line each.
    final blocks = <String>[];
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      if (line.startsWith('  ') && blocks.isNotEmpty) {
        blocks.last = '${blocks.last} ${line.trim()}';
      } else {
        blocks.add(line.trim());
      }
    }
    final typography = FluentTheme.of(context).typography;
    return KyberContentDialog(
      constraints: const BoxConstraints(maxWidth: 640, maxHeight: 640),
      title: Text("What's new in $kLinuxPortVersion".toUpperCase()),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final block in blocks.map((b) => b.replaceAll('`', '')))
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: block.startsWith('### ')
                    ? Text(
                        block.substring(4).toUpperCase(),
                        style: typography.bodyStrong?.copyWith(
                          color: kInactiveColor,
                        ),
                      )
                    : Text(
                        block,
                        style: typography.body,
                      ),
              ),
          ],
        ),
      ),
      actions: [
        KyberButton(
          text: 'Close',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

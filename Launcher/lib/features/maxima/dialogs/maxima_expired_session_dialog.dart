import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:kyber_launcher/core/core.dart';
import 'package:kyber_launcher/shared/ui/ui.dart';

class MaximaExpiredSessionDialog extends StatefulWidget {
  const MaximaExpiredSessionDialog({super.key});

  @override
  State<MaximaExpiredSessionDialog> createState() =>
      _MaximaExpiredSessionDialogState();
}

class _MaximaExpiredSessionDialogState
    extends State<MaximaExpiredSessionDialog> {
  @override
  Widget build(BuildContext context) {
    return KyberContentDialog(
      title: const Text('Game not owned'),
      constraints: const BoxConstraints(maxWidth: 650, maxHeight: 400),
      content: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Your EA session has expired, to continue, please log in again after exiting the launcher.',
            style: TextStyle(
              color: kWhiteColor,
              fontSize: 15,
            ),
          ),
        ],
      ),
      actions: [
        KyberButton(
          text: 'Exit Launcher',
          onPressed: () async {
            // MAXIMA-LINUX-PORT-MOD: original used a hardcoded %APPDATA% path
            // which on Linux resolves to "null\..."; File.delete() then threw
            // (no such file) and the restart below never ran. Use the
            // platform-correct path with an existence check, like logout().
            final home = Platform.environment['HOME'] ?? '';
            final appdata = Platform.environment['APPDATA'] ?? '';
            final authPath = Platform.isLinux
                ? '$home/.local/share/maxima/auth.toml'
                : Platform.isMacOS
                ? '$home/Library/Application Support/maxima/auth.toml'
                : '$appdata\\ArmchairDevelopers\\Maxima\\data\\auth.toml';
            final authFile = File(authPath);
            if (authFile.existsSync()) {
              authFile.deleteSync();
            }

            final executable = Platform.resolvedExecutable;
            final args = <String>['--restart'];
            final workingDirectory = Directory.current.path;

            try {
              await Process.start(
                executable,
                args,
                workingDirectory: workingDirectory,
              );
            } catch (_) {
              // Restart can fail if the binary moved or lost its exec bit.
              // Still exit so the user is not trapped in the dialog; they
              // can relaunch manually.
            }
            exit(0);
          },
        ),
      ],
    );
  }
}

import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:kyber_launcher/core/config/colors.dart';
import 'package:kyber_launcher/core/services/notification_service.dart';
import 'package:kyber_launcher/gen/fonts.gen.dart';
import 'package:kyber_launcher/shared/ui/buttons/button.dart';
import 'package:kyber_launcher/shared/ui/dialog/kyber_dialog.dart';

/// A hosted BF2 listen server connects to itself by name. On Debian/Ubuntu and
/// other Calamares-installed distros the machine hostname resolves to 127.0.1.1
/// instead of 127.0.0.1, the reply comes back from a mismatched source, the
/// local link never establishes ("The server did not reply."), and the game
/// crashes shortly after the map starts loading. The real fix lives in the
/// runtime-downloaded module; until then we warn the host and hand over the
/// /etc/hosts one-liner.
class HostLoopbackWarning {
  /// Returns true if hosting should go ahead: the hostname is fine, the check
  /// could not run, or the user chose to host anyway. Returns false only when
  /// the user cancels after being warned. No-op (true) off Linux.
  static Future<bool> confirm(BuildContext context) async {
    if (!Platform.isLinux) return true;

    final badIp = await _badLoopback();
    if (badIp == null) return true;

    // The game is launched with a hostname of its own, which makes the wrong
    // loopback address irrelevant. Only kernels that forbid unprivileged user
    // namespaces still need the manual fix, so only they get warned.
    if (await _canIsolateHostname()) return true;
    if (!context.mounted) return true;

    final result = await showKyberDialog<bool>(
      context: context,
      builder: (_) => _HostLoopbackWarningDialog(badIp: badIp),
    );
    return result == true;
  }

  /// Whether the game can be given its own hostname, which is what removes the
  /// need for the manual fix. Mirrors what the launch path itself attempts;
  /// anything unexpected counts as "cannot", so the user still gets told.
  static Future<bool> _canIsolateHostname() async {
    try {
      final probe = await Process.run('unshare', ['--user', '--uts', 'true']);
      return probe.exitCode == 0;
    } on Object catch (_) {
      return false;
    }
  }

  /// The loopback address the hostname resolves to when it is not 127.0.0.1
  /// (e.g. 127.0.1.1 on Debian, 127.0.0.2 on openSUSE), or null when it is fine
  /// or cannot be resolved. Uses the OS resolver, the same one BF2 hits.
  static Future<String?> _badLoopback() async {
    try {
      final addresses = await InternetAddress.lookup(Platform.localHostname);
      for (final address in addresses) {
        if (address.type == InternetAddressType.IPv4 &&
            address.address.startsWith('127.') &&
            address.address != '127.0.0.1') {
          return address.address;
        }
      }
    } catch (_) {
      // Never block hosting on a failed pre-flight.
    }
    return null;
  }
}

class _HostLoopbackWarningDialog extends StatelessWidget {
  const _HostLoopbackWarningDialog({required this.badIp});

  final String badIp;

  String get _fixCommand =>
      "sudo sed -i.bak 's/^${badIp.replaceAll('.', r'\.')}/127.0.0.1/' /etc/hosts";

  @override
  Widget build(BuildContext context) {
    return KyberContentDialog(
      title: const Text('HOSTING WILL FAIL'),
      constraints: const BoxConstraints(maxWidth: 600, maxHeight: 460),
      content: DefaultTextStyle(
        style: const TextStyle(
          color: kWhiteColor,
          fontFamily: FontFamily.battlefrontUI,
          fontSize: 16,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Your hostname resolves to $badIp instead of 127.0.0.1. A hosted '
              'server connects to itself, and with this address the connection '
              'never establishes, so the game crashes shortly after the map '
              'starts loading. Joining other servers is not affected.',
            ),
            const SizedBox(height: 12),
            const Text(
              'This is normally handled by giving the game a hostname of its '
              'own, but that needs user namespaces, which this system does not '
              'allow. So it has to be fixed by hand once.',
            ),
            const SizedBox(height: 20),
            const Text('Run this once in a terminal, then host again:'),
            const SizedBox(height: 12),
            SelectableText(
              _fixCommand,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 14,
                color: kWhiteColor,
              ),
            ),
          ],
        ),
      ),
      actions: [
        KyberButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: _fixCommand));
            NotificationService.showNotification(message: 'Command copied');
          },
          text: 'COPY COMMAND',
        ),
        KyberButton(
          onPressed: () => Navigator.of(context).pop(false),
          text: 'CANCEL',
        ),
        KyberButton(
          onPressed: () => Navigator.of(context).pop(true),
          text: 'HOST ANYWAY',
        ),
      ],
    );
  }
}

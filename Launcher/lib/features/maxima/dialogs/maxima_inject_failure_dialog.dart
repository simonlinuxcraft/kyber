import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:kyber/kyber.dart';
import 'package:kyber_collection/kyber_collection.dart';
import 'package:kyber_launcher/core/config/colors.dart';
import 'package:kyber_launcher/core/routing/app_router.dart';
import 'package:kyber_launcher/core/services/notification_service.dart';
import 'package:kyber_launcher/features/maxima/helper/maxima_helper.dart';
import 'package:kyber_launcher/gen/fonts.gen.dart';
import 'package:kyber_launcher/shared/ui/buttons/button.dart';
import 'package:kyber_launcher/shared/ui/dialog/kyber_dialog.dart';
import 'package:logging/logging.dart';

class MaximaInjectFailureDialog extends StatefulWidget {
  const MaximaInjectFailureDialog({
    super.key,
    this.initializeRequest,
    this.gameDataPath,
    this.mods,
    required this.errorMessage,
  });

  final InitializeRequest? initializeRequest;
  final String? gameDataPath;
  final List<FrostyMod>? mods;
  final String errorMessage;

  @override
  State<MaximaInjectFailureDialog> createState() =>
      _MaximaInjectFailureDialogState();
}

class _MaximaInjectFailureDialogState extends State<MaximaInjectFailureDialog> {
  static final _logger = Logger('inject_failure_dialog');

  bool _busy = false;
  String? _statusLine;

  Future<void> _retryFfi() async {
    setState(() {
      _busy = true;
      _statusLine = 'Trying again...';
    });

    try {
      await MaximaHelper.startGame(
        initializeRequest: widget.initializeRequest,
        gameDataPath: widget.gameDataPath,
        mods: widget.mods,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      _logger.warning('Retry FFI launch failed', e);
      if (!mounted) return;
      final msg = e is AnyhowException ? e.message : e.toString();
      setState(() {
        _busy = false;
        _statusLine = 'Retry failed: $msg';
      });
    }
  }

  Future<void> _launchViaCli() async {
    if (widget.initializeRequest == null) {
      NotificationService.error(
        message:
            'No launch context here - close this dialog, restart the launcher, and try again.',
      );
      return;
    }

    setState(() {
      _busy = true;
      _statusLine = 'Starting kyber_cli...';
    });

    try {
      await MaximaHelper.startGameViaCli(
        initializeRequest: widget.initializeRequest!,
        gamePath: widget.gameDataPath,
        mods: widget.mods,
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      _logger.warning('CLI launch failed', e);
      if (!mounted) return;
      final msg = e is AnyhowException ? e.message : e.toString();
      setState(() {
        _busy = false;
        _statusLine = 'CLI launch failed: $msg';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final typography = FluentTheme.of(context).typography;
    return KyberContentDialog(
      title: const Text('KYBER INJECT FAILED'),
      constraints: const BoxConstraints(maxWidth: 620, maxHeight: 460),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'BF2 started, but Kyber couldn\'t inject. The game has been '
            'stopped so you can try again from a clean state.',
            style: typography.body?.copyWith(color: kWhiteColor),
          ),
          const SizedBox(height: 10),
          Text(
            'Usually it\'s one of these:',
            style: typography.body?.copyWith(color: kWhiteColor),
          ),
          const SizedBox(height: 4),
          Text(
            '  - wine-helper can\'t talk to BF2\'s wineserver\n'
            '  - Wine prefix is half-broken or stale\n'
            '  - vivoxsdk.dll missing from the Wine search path',
            style: typography.body?.copyWith(color: kWhiteColor),
          ),
          const SizedBox(height: 12),
          Text(
            'Hit Retry to try the same path again, or use CLI Launch '
            'to run BF2 through a separate kyber_cli subprocess.',
            style: typography.body?.copyWith(color: kWhiteColor),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(4),
            ),
            width: double.infinity,
            child: SelectableText(
              widget.errorMessage,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: Color(0xFFBBBBBB),
              ),
            ),
          ),
          if (_statusLine != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                if (_busy)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: ProgressRing(strokeWidth: 2),
                  ),
                if (_busy) const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _statusLine!,
                    style: TextStyle(
                      fontFamily: FontFamily.battlefrontUI,
                      fontSize: 14,
                      color: _busy
                          ? kWhiteColor
                          : const Color(0xFFFFB347),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        KyberButton(
          text: 'Close',
          onPressed: _busy
              ? null
              : () {
                  if (Navigator.of(context).canPop()) {
                    Navigator.of(context).pop();
                  }
                },
        ),
        KyberButton(
          text: 'Retry FFI',
          onPressed: _busy ? null : _retryFfi,
        ),
        KyberButton(
          text: 'Use CLI Launch',
          onPressed: _busy ? null : _launchViaCli,
        ),
      ],
    );
  }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 simonlinuxcraft
//
// Classic update dialog for the AppImage launcher container: shows the
// available version, downloads it with a progress bar, then asks the user
// to restart. Only reached when AppImageUpdateService.checkForUpdate()
// found a newer image, so the dialog assumes an eligible AppImage context.

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:kyber_launcher/core/config/colors.dart';
import 'package:kyber_launcher/core/services/appimage_update_service.dart';
import 'package:kyber_launcher/features/settings/dialogs/chromium_download_dialog.dart';
import 'package:kyber_launcher/injection_container.dart';
import 'package:kyber_launcher/shared/ui/buttons/button.dart';
import 'package:kyber_launcher/shared/ui/dialog/kyber_dialog.dart';

enum _Phase { offer, downloading, ready, error }

class AppImageUpdateDialog extends StatefulWidget {
  const AppImageUpdateDialog({required this.manifest, super.key});

  final AppImageUpdateManifest manifest;

  @override
  State<AppImageUpdateDialog> createState() => _AppImageUpdateDialogState();
}

class _AppImageUpdateDialogState extends State<AppImageUpdateDialog> {
  final AppImageUpdateService _service = sl.get<AppImageUpdateService>();
  final CancelToken _cancelToken = CancelToken();

  _Phase _phase = _Phase.offer;
  int _received = 0;
  int _total = 0;
  String? _stagedPath;
  String _error = '';

  @override
  void dispose() {
    // Covers every dismiss path (Later button, barrier tap, ESC): cancel an
    // in-flight download (its own catch removes the partial tmp) and remove a
    // finished-but-not-applied staged image so we never orphan ~180MB.
    if (!_cancelToken.isCancelled) {
      _cancelToken.cancel('dialog dismissed');
    }
    final staged = _stagedPath;
    if (staged != null) {
      unawaited(_service.discardStaged(staged));
    }
    super.dispose();
  }

  Future<void> _startDownload() async {
    setState(() => _phase = _Phase.downloading);
    try {
      final staged = await _service.downloadUpdate(
        widget.manifest,
        cancelToken: _cancelToken,
        onProgress: (received, total) => setState(() {
          _received = received;
          _total = total;
        }),
      );
      if (!mounted) return;
      setState(() {
        _stagedPath = staged;
        _phase = _Phase.ready;
      });
    } on Object catch (e) {
      // User cancelled (Cancel button / dismiss): no error UI, dispose cleans up.
      if (_cancelToken.isCancelled || !mounted) return;
      setState(() {
        _error = e.toString();
        _phase = _Phase.error;
      });
    }
  }

  Future<void> _restart() async {
    final staged = _stagedPath;
    if (staged == null) return;
    try {
      // Never returns on success (process exits and re-execs).
      await _service.applyAndRestart(staged);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _phase = _Phase.error;
      });
    }
  }

  void _dismiss() {
    // dispose() does the staged-file cleanup and download cancel for every
    // dismiss path, so this just closes the dialog.
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final percent =
        _total == 0 ? 0.0 : (_received / _total).clamp(0.0, 1.0) * 100;
    return KyberContentDialog(
      title: const Text('LAUNCHER UPDATE'),
      constraints: const BoxConstraints(maxWidth: 600, maxHeight: 360),
      actions: _actions(),
      content: SizedBox(
        width: 600,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            switch (_phase) {
              _Phase.offer => Text(
                  'A new launcher version is available: '
                  '${_service.currentVersion} -> '
                  '${widget.manifest.version}.\n\n'
                  'Only the launcher app updates here. Mods, the Kyber module '
                  'and live events keep coming from Kyber.',
                  style: const TextStyle(fontSize: 15),
                ),
              _Phase.downloading => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Downloading update... (${percent.toStringAsFixed(0)}%)',
                      style: const TextStyle(fontSize: 16),
                    ),
                    const SizedBox(height: 12),
                    ProgressBar(value: percent),
                    const SizedBox(height: 6),
                    Text(
                      '${formatBytes(_received, 1)}/${formatBytes(_total, 1)}',
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 12, color: kWhiteColor),
                    ),
                  ],
                ),
              _Phase.ready => Text(
                  'Update ${widget.manifest.version} downloaded. Restart the '
                  'launcher now to apply it?',
                  style: const TextStyle(fontSize: 15),
                ),
              _Phase.error => Text(
                  'Update failed: $_error\n\nYou can keep using the current '
                  'version and try again later.',
                  style: const TextStyle(fontSize: 14),
                ),
            },
          ],
        ),
      ),
    );
  }

  List<Widget> _actions() {
    switch (_phase) {
      case _Phase.offer:
        return [
          KyberButton(onPressed: _dismiss, text: 'Later'),
          KyberButton(onPressed: _startDownload, text: 'Update'),
        ];
      case _Phase.downloading:
        return [
          KyberButton(onPressed: _dismiss, text: 'Cancel'),
        ];
      case _Phase.ready:
        return [
          KyberButton(onPressed: _dismiss, text: 'Later'),
          KyberButton(onPressed: _restart, text: 'Restart now'),
        ];
      case _Phase.error:
        return [
          KyberButton(onPressed: _dismiss, text: 'Close'),
        ];
    }
  }
}

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:kyber_launcher/core/config/colors.dart';
import 'package:kyber_launcher/gen/rust/api/maxima.dart';
import 'package:kyber_launcher/shared/ui/buttons/button.dart';
import 'package:kyber_launcher/shared/ui/dialog/kyber_dialog.dart';
import 'package:kyber_launcher/shared/ui/elements/kyber_input.dart';

// Manual override for the Proton install used by BF2. Reached from the
// Mod Configuration settings page. Only relevant on Linux; on Windows the
// FFI returns an error and the dialog is hidden by the settings page.
//
// The path is stored in a sidecar file at ~/.local/share/maxima/custom_proton_path
// (written by Rust via set_custom_proton_path). Maxima reads it on every wine
// call, so a change takes effect at the next game launch without needing a
// launcher restart.
class CustomProtonPathDialog extends StatefulWidget {
  const CustomProtonPathDialog({super.key});

  @override
  State<CustomProtonPathDialog> createState() => _CustomProtonPathDialogState();
}

class _CustomProtonPathDialogState extends State<CustomProtonPathDialog> {
  late TextEditingController controller;
  ProtonValidation? validation;
  List<ProtonCandidate>? scanResults;
  bool scanning = false;

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: getCustomProtonPath() ?? '');
    _revalidate();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _revalidate() {
    final text = controller.text.trim();
    if (text.isEmpty) {
      setState(() => validation = null);
      return;
    }
    setState(() => validation = validateProtonPath(path: text));
  }

  Future<void> _scan() async {
    setState(() => scanning = true);
    try {
      final results = await scanKnownProtonLocations();
      setState(() => scanResults = results);
    } finally {
      setState(() => scanning = false);
    }
  }

  bool get _isWow64Layout =>
      validation?.layout.toLowerCase().contains('wow64') ?? false;

  Widget _buildStatusIcon() {
    if (validation == null) {
      return const SizedBox(width: 18);
    }
    if (validation!.valid) {
      if (_isWow64Layout) {
        return Tooltip(
          message:
              'Wine 10 WoW64 single-binary layout detected (only `wine`, no '
              'separate `wine64`). Builds like Proton-EM Latest, proton-cachyos '
              '11+ and GE-Proton 11+ use this layout. Confirmed working in '
              "testing - often with smoother frame times than the default. "
              'Newer Wine + DXVK can also introduce game-side quirks not '
              'present on the older default; revert via "Reset to default" '
              'if the game misbehaves.',
          child: Icon(FluentIcons.info, color: Colors.warningPrimaryColor),
        );
      }
      if (validation!.inHome) {
        return const Icon(FluentIcons.check_mark, color: Colors.successPrimaryColor);
      }
      return Tooltip(
        message:
            'Path is outside your home directory. May not be reachable inside '
            "BF2's pressure-vessel sandbox on some distros.",
        child: Icon(FluentIcons.warning, color: Colors.warningPrimaryColor),
      );
    }
    return Tooltip(
      message: validation!.error ?? 'Invalid proton layout',
      child: Icon(FluentIcons.error_badge, color: Colors.errorPrimaryColor),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLinux = Platform.isLinux;
    return KyberContentDialog(
      constraints: const BoxConstraints(maxWidth: 760, maxHeight: 780),
      title: Text('Custom Proton Path (Experimental)'.toUpperCase()),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!isLinux)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Custom Proton is only available on Linux builds.',
                style: FluentTheme.of(context)
                    .typography
                    .body
                    ?.copyWith(color: kWhiteColor),
                textAlign: TextAlign.center,
              ),
            )
          else ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.warningPrimaryColor.withOpacity(0.12),
                border: Border.all(
                  color: Colors.warningPrimaryColor.withOpacity(0.5),
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    FluentIcons.warning,
                    color: Colors.warningPrimaryColor,
                    size: 16,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Advanced. The custom Proton replaces only the Wine '
                      "binaries; BF2's save games and EA App login state stay "
                      'shared with the default Steam-managed prefix, so '
                      'switching back and forth does not require a new EA '
                      'login. A newer Proton build (Proton-EM Latest, '
                      'GE-Proton Latest, proton-cachyos) can give noticeably '
                      'smoother frame times than the auto-managed default. '
                      'The default remains the only tested-stable path; pick '
                      'a custom build only if you want to trade tested '
                      'stability for newer Wine + DXVK and accept that not '
                      'every build will launch cleanly.',
                      style: FluentTheme.of(context)
                          .typography
                          .body
                          ?.copyWith(color: kWhiteColor),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Override the Proton build used to run Battlefront II. Leave '
              'empty to use the auto-managed GE-Proton that Maxima downloads. '
              'The path must point to a Proton directory containing wine64 '
              '(GE-Proton: files/bin/wine64, proton-cachyos: dist/bin/wine64). '
              'Takes effect at the next game launch.',
              style: FluentTheme.of(context)
                  .typography
                  .body
                  ?.copyWith(color: kWhiteColor),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: KyberInput(
                    controller: controller,
                    disabled: true,
                    placeholder: 'Default (auto-managed GE-Proton)',
                  ),
                ),
                const SizedBox(width: 12),
                _buildStatusIcon(),
                const SizedBox(width: 12),
                KyberButton(
                  text: 'Browse',
                  onPressed: () async {
                    final path = await getDirectoryPath();
                    if (path == null) return;
                    setState(() => controller.text = path);
                    _revalidate();
                  },
                ),
                const SizedBox(width: 8),
                KyberButton(
                  text: scanning ? 'Scanning...' : 'Scan',
                  onPressed: scanning ? null : _scan,
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (scanResults != null) ...[
              Text(
                scanResults!.isEmpty
                    ? 'No Proton installations found in the standard Steam '
                          'compatibility directories.'
                    : 'Found ${scanResults!.length} Proton installation(s):',
                style: FluentTheme.of(context)
                    .typography
                    .body
                    ?.copyWith(color: kWhiteColor),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 200,
                child: ListView.builder(
                  itemCount: scanResults!.length,
                  itemBuilder: (_, i) {
                    final c = scanResults![i];
                    return HoverButton(
                      onPressed: () {
                        setState(() => controller.text = c.path);
                        _revalidate();
                      },
                      builder: (_, states) => Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: states.isHovered
                              ? Colors.white.withOpacity(0.06)
                              : Colors.transparent,
                          border: Border(
                            bottom: BorderSide(
                              color: Colors.white.withOpacity(0.08),
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            if (!c.inHome)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: Icon(
                                  FluentIcons.warning,
                                  size: 14,
                                  color: Colors.warningPrimaryColor,
                                ),
                              ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    c.displayName,
                                    style: TextStyle(color: kWhiteColor),
                                  ),
                                  Text(
                                    c.path,
                                    style: TextStyle(
                                      color: kWhiteColor.withOpacity(0.6),
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (c.versionHint != null)
                              Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: Text(
                                  c.versionHint!,
                                  style: TextStyle(
                                    color: kWhiteColor.withOpacity(0.7),
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ],
      ),
      actions: [
        KyberButton(
          text: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
        if (isLinux)
          KyberButton(
            text: 'Reset to default',
            onPressed: () {
              try {
                setCustomProtonPath(path: null);
                Navigator.of(context).pop();
              } catch (e) {
                _showError(context, 'Failed to reset: $e');
              }
            },
          ),
        if (isLinux)
          KyberButton(
            text: 'Save',
            onPressed: () {
              final text = controller.text.trim();
              if (text.isNotEmpty &&
                  validation != null &&
                  !validation!.valid) {
                _showError(
                  context,
                  validation!.error ?? 'Invalid proton path',
                );
                return;
              }
              try {
                setCustomProtonPath(path: text.isEmpty ? null : text);
                Navigator.of(context).pop();
              } catch (e) {
                _showError(context, 'Failed to save: $e');
              }
            },
          ),
      ],
    );
  }

  void _showError(BuildContext context, String message) {
    displayInfoBar(
      context,
      builder: (_, close) => InfoBar(
        title: const Text('Custom Proton'),
        content: Text(message),
        severity: InfoBarSeverity.error,
        action: IconButton(
          icon: const Icon(FluentIcons.clear),
          onPressed: close,
        ),
      ),
    );
  }
}

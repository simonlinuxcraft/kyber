import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:kyber_launcher/core/core.dart';
import 'package:kyber_launcher/core/services/app_settings.dart';
import 'package:kyber_launcher/core/services/linux_status.dart';
import 'package:kyber_launcher/features/frosty/dialogs/frosty_import_dialog.dart';
import 'package:kyber_launcher/features/maxima/dialogs/custom_game_path_dialog.dart';
import 'package:kyber_launcher/features/maxima/dialogs/custom_proton_path_dialog.dart';
import 'package:kyber_launcher/features/mods/dialogs/move_directory_dialog.dart';
import 'package:kyber_launcher/features/settings/screens/settings.dart';
import 'package:kyber_launcher/main.dart';
import 'package:kyber_launcher/shared/ui/ui.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

class ModSupport extends StatefulWidget {
  const ModSupport({super.key});

  @override
  State<ModSupport> createState() => _ModSupportState();
}

class _ModSupportState extends State<ModSupport> {
  void _restartHint(BuildContext context, String text) {
    displayInfoBar(
      context,
      builder: (_, close) => InfoBar(
        title: const Text('Restart required'),
        content: Text(text),
        severity: InfoBarSeverity.info,
        action: IconButton(
          icon: const Icon(FluentIcons.clear),
          onPressed: close,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SuperListView(
      children: [
        const SettingsHeader(title: 'MODS'),
        HiveListener(
          box: box,
          keys: const [
            'enabledPreloadMods',
            'incrementalDownloadsEnabled',
            'customGamePath',
            'nativeWayland',
            'skiaRenderer',
          ],
          builder: (_) => KyberTable(
            items: [
              KyberTableItem.button(
                title: 'Change Mod Directory',
                text: 'New Directory',
                onClick: () => showKyberDialog(
                  builder: (_) => const MoveModsDirectoryDialog(),
                  context: context,
                ),
              ),
              KyberTableItem.button(
                title: 'Custom Game Path',
                text: Preferences.general.customGamePath == null
                    ? 'Set Path'
                    : 'Change',
                onClick: () => showKyberDialog(
                  builder: (_) => const CustomGamePathDialog(),
                  context: context,
                ),
              ),
              if (Platform.isLinux)
                KyberTableItem.button(
                  title: 'Proton Build',
                  text: protonLabel(),
                  onClick: () async {
                    await showKyberDialog(
                      builder: (_) => const CustomProtonPathDialog(),
                      context: context,
                    );
                    // Reread after the dialog: changing the path here does not
                    // touch Hive, so the surrounding HiveListener would keep
                    // showing the build that was active before the change.
                    if (mounted) {
                      setState(() {});
                    }
                  },
                ),
              // Only on an actual Wayland session. On X11 GDK_BACKEND=wayland
              // has no display to open and would stop the launcher starting,
              // so the toggle is not offered there.
              if (Platform.isLinux &&
                  (Platform.environment['WAYLAND_DISPLAY']?.isNotEmpty ??
                      false))
                KyberTableItem.switchButton(
                  title: 'Native Wayland (restart to apply)',
                  value: Preferences.general.nativeWayland,
                  onChange: (bool value) {
                    Preferences.general.nativeWayland = value;
                    writeWaylandBackendPref(value);
                    _restartHint(
                      context,
                      'Native Wayland takes effect after you restart Kyber.',
                    );
                  },
                ),
              // Impeller is the engine default since Flutter made it so in
              // June 2026. It is faster on dedicated GPUs and slower on weak
              // integrated or software-rendered ones, so there is no default
              // that suits every machine and the user decides by feel.
              if (Platform.isLinux)
                KyberTableItem.switchButton(
                  title:
                      'Alternative renderer for weak graphics '
                      '(restart to apply)',
                  value: Preferences.general.skiaRenderer,
                  onChange: (bool value) {
                    Preferences.general.skiaRenderer = value;
                    writeRendererPref(value);
                    _restartHint(
                      context,
                      'Turn this on if the interface stutters. It draws '
                      'the launcher a different way that is usually '
                      'smoother on integrated graphics, in virtual '
                      'machines and on older cards, and usually slower on '
                      'a dedicated graphics card. If nothing improves, '
                      'turn it back off. Restart Kyber to apply.',
                    );
                  },
                ),
              KyberTableItem.button(
                title: 'Frosty Converter',
                text: 'Convert your Packs',
                onClick: () => showKyberDialog(
                  builder: (_) => const FrostyImportDialog(),
                  context: context,
                ),
              ),
              KyberTableItem.switchButton(
                title: 'Kyber Preloaded Mods',
                value: Preferences.general.enabledPreloadMods,
                onChange: (bool value) {
                  Preferences.general.enabledPreloadMods = value;
                },
              ),
              KyberTableItem.switchButton(
                title: 'Incremental Mod Downloads',
                value: Preferences.general.incrementalDownloadsEnabled,
                onChange: (bool value) {
                  Preferences.general.incrementalDownloadsEnabled = value;
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

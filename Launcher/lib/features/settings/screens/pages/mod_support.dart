import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:kyber_launcher/core/core.dart';
import 'package:kyber_launcher/core/services/app_settings.dart';
import 'package:kyber_launcher/features/frosty/dialogs/frosty_import_dialog.dart';
import 'package:kyber_launcher/features/maxima/dialogs/custom_game_path_dialog.dart';
import 'package:kyber_launcher/features/maxima/dialogs/custom_proton_path_dialog.dart';
import 'package:kyber_launcher/features/mods/dialogs/move_directory_dialog.dart';
import 'package:kyber_launcher/features/settings/screens/settings.dart';
import 'package:kyber_launcher/gen/rust/api/maxima.dart';
import 'package:kyber_launcher/main.dart';
import 'package:kyber_launcher/shared/ui/ui.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

class ModSupport extends StatelessWidget {
  const ModSupport({super.key});

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
                  title: 'Custom Proton Path (Experimental)',
                  text: getCustomProtonPath() == null ? 'Set Path' : 'Change',
                  onClick: () => showKyberDialog(
                    builder: (_) => const CustomProtonPathDialog(),
                    context: context,
                  ),
                ),
              // Only on an actual Wayland session. On X11 GDK_BACKEND=wayland
              // has no display to open and would stop the launcher starting,
              // so the toggle is not offered there.
              if (Platform.isLinux &&
                  (Platform.environment['WAYLAND_DISPLAY']?.isNotEmpty ?? false))
                KyberTableItem.switchButton(
                  title: 'Native Wayland (Experimental, restart to apply)',
                  value: Preferences.general.nativeWayland,
                  onChange: (bool value) {
                    Preferences.general.nativeWayland = value;
                    writeWaylandBackendPref(value);
                    displayInfoBar(
                      context,
                      builder: (_, close) => InfoBar(
                        title: const Text('Restart required'),
                        content: const Text(
                          'Native Wayland takes effect after you restart Kyber.',
                        ),
                        severity: InfoBarSeverity.info,
                        action: IconButton(
                          icon: const Icon(FluentIcons.clear),
                          onPressed: close,
                        ),
                      ),
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

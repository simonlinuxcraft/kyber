import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:kyber_launcher/features/plugin_manager/plugins/bsm_plugin.dart';
import 'package:kyber_launcher/shared/ui/buttons/button.dart';
import 'package:kyber_launcher/shared/ui/dialog/kyber_dialog.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// Explains where the Better Sabers plugin has to go, and opens that folder.
///
/// Shown instead of hiding the button: someone who never installed the plugin
/// has no other way of finding out that the folder exists, which is exactly
/// where people get stuck.
class PluginMissingDialog extends StatelessWidget {
  const PluginMissingDialog({super.key});

  @override
  Widget build(BuildContext context) {
    // The button lands here for two different reasons, and saying "not
    // installed" to someone who just put the file there sends them looking
    // in the wrong place. Maxima's Wine runtime only appears once the game
    // has been started, and the plugin list is read at startup.
    final installed = File(BSMPlugin.path).existsSync();

    return KyberContentDialog(
      title: Text(
        installed
            ? 'Better Sabers cannot start yet'
            : 'Better Sabers is not installed',
      ),
      content: Text(
        installed
            ? 'The plugin is in place, but the Wine runtime Kyber installs for '
                  'the game is missing. Start the game once, then restart the '
                  'launcher.'
            : 'Put BetterSabersPlugin.dll into the Plugins folder, then use '
                  'this button again. The plugin comes from the Better Sabers '
                  'page on Nexus Mods, and the folder opens next.',
      ),
      constraints: const BoxConstraints(maxWidth: 600, maxHeight: 400),
      actions: [
        KyberButton(
          text: 'CANCEL',
          onPressed: () => Navigator.of(context).pop(),
        ),
        KyberButton(
          text: 'OPEN PLUGINS FOLDER',
          onPressed: () async {
            Navigator.of(context).pop();
            await openPluginsFolder();
          },
        ),
      ],
    );
  }

  /// Opens the folder, creating it first when it does not exist yet. A fresh
  /// install has no Plugins folder, and pointing at a folder that is not
  /// there helps nobody.
  static Future<void> openPluginsFolder() async {
    final dir = Directory(BSMPlugin.pluginsDir);
    if (!dir.existsSync()) await dir.create(recursive: true);
    await launchUrlString('file://${dir.path}');
  }
}

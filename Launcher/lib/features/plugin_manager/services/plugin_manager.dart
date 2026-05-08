import 'dart:async';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:kyber_collection/kyber_collection.dart';
import 'package:kyber_launcher/features/plugin_manager/plugins/bsm_plugin.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

class PluginManager with ChangeNotifier {
  PluginManager() {
    initialize();
  }

  final _logger = Logger('plugin_manager');

  String get pluginsPath =>
      p.join(FileHelper.getLauncherDirectory().path, 'Plugins');

  void initialize() {
    _logger.info('Initializing PluginManager');

    final pluginDirectory = Directory(pluginsPath);
    if (!pluginDirectory.existsSync()) {
      _logger.fine('Plugin directory does not exist, creating it');
      pluginDirectory.createSync();
    }

    _fileWatcher = Directory(pluginsPath).watch().listen((event) {
      _logger.info('Plugin directory changed, reloading plugins');
      loadPlugins();
    });

    loadPlugins();
  }

  BSMPlugin? bsmPlugin;
  StreamSubscription<FileSystemEvent>? _fileWatcher;

  void loadPlugins() {
    // The plugin DLL is a Win32 PE; on Linux it's executed inside the
    // Wine prefix together with the rest of the Frosty stack, the
    // launcher itself can't load it via dart:ffi. Surfacing the
    // existence of the file as "available" would mislead the UI.
    if (BSMPlugin.isUsable && File(BSMPlugin.path).existsSync()) {
      _logger.info('Loading BSMPlugin');
      bsmPlugin = BSMPlugin();
    }

    notifyListeners();
  }

  void unloadPlugins() {
    _fileWatcher?.cancel();
    bsmPlugin = null;
    notifyListeners();
  }

  @override
  void dispose() {
    unloadPlugins();
    _fileWatcher?.cancel();
    super.dispose();
  }
}

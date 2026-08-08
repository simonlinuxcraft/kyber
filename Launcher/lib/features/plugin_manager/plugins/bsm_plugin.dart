import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:kyber_collection/kyber_collection.dart';
import 'package:kyber_launcher/core/services/app_settings.dart';
import 'package:kyber_launcher/features/maxima/models/maxima_game_instance.dart';
import 'package:kyber_launcher/injection_container.dart';
import 'package:kyber_launcher/features/plugin_manager/plugins/bsm_linux_host.dart';
import 'package:path/path.dart' as p;

class BSMPlugin {
  /// File name of the plugin DLL — fixed by the Better Sabers Mod
  /// Frosty plugin and validated below.
  static const _libName = 'BetterSabersPlugin.dll';

  static String get pluginsDir =>
      p.join(FileHelper.getLauncherDirectory().path, 'Plugins');

  /// Normally the DLL sits directly in the Plugins folder. Unpacking the
  /// Nexus archive leaves it one level down instead, in a folder named after
  /// the release, so look there too rather than reporting "no plugin".
  static String get path {
    final direct = p.join(pluginsDir, _libName);
    if (File(direct).existsSync()) return direct;

    final root = Directory(pluginsDir);
    if (root.existsSync()) {
      for (final sub in root.listSync().whereType<Directory>()) {
        final nested = p.join(sub.path, _libName);
        if (File(nested).existsSync()) return nested;
      }
    }
    return direct;
  }

  /// The plugin is a Windows .NET assembly, so `dlopen` is out on Linux.
  /// There it runs as the manager application the DLL carries inside it,
  /// through the same Wine prefix as the game (see [BsmLinuxHost]).
  static bool get isUsable => !Platform.isLinux || BsmLinuxHost.wineReady;

  Future<String> generateFile(
    String modsDir,
    List<String> mods,
    String packName,
  ) async {
    if (Platform.isLinux) {
      return _generateThroughWine(modsDir, mods, packName);
    }
    return compute(
      (message) {
        final lib = DynamicLibrary.open(BSMPlugin.path);
        final run = lib
            .lookupFunction<
              Pointer<Utf8> Function(
                Pointer<Utf8>,
                Pointer<Utf8>,
                Pointer<Utf8>,
              ),
              Pointer<Utf8> Function(
                Pointer<Utf8>,
                Pointer<Utf8>,
                Pointer<Utf8>,
              )
            >('Run');

        final modsDirPointer = (message[0] as String).toNativeUtf8();
        final modsPointer = (message[1] as List<String>)
            .join('|')
            .toNativeUtf8();
        final packNamePointer = (message[2] as String).toNativeUtf8();
        final resultPointer = run(modsDirPointer, modsPointer, packNamePointer);
        final result = resultPointer.toDartString();
        calloc
          ..free(modsDirPointer)
          ..free(packNamePointer)
          ..free(modsPointer);

        lib.close();

        return result;
      },
      [modsDir, mods, packName],
    );
  }

  Future<String> _generateThroughWine(
    String modsDir,
    List<String> mods,
    String packName,
  ) async {
    // The manager shares the game's Wine prefix, so both fighting over one
    // wineserver ends badly. Guarding here covers every caller.
    if (sl.isRegistered<MaximaGameInstance>()) {
      throw const BsmHostException(
        'Close the game before opening Better Sabers.',
      );
    }

    final pack = await BsmLinuxHost.openManager(
      dllPath: path,
      modsDir: modsDir,
      mods: mods,
      packName: packName,
      gamePath: Preferences.general.customGamePath,
    );
    return pack ?? '';
  }
}

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:kyber_collection/kyber_collection.dart';
import 'package:path/path.dart' as p;

class BSMPlugin {
  /// File name of the plugin DLL — fixed by the Better Sabers Mod
  /// Frosty plugin and validated below.
  static const _libName = 'BetterSabersPlugin.dll';

  static String get path => p.join(
        FileHelper.getLauncherDirectory().path,
        'Plugins',
        _libName,
      );

  /// On Linux the plugin is a Win32 PE that runs inside the same Wine
  /// prefix as BF2; the launcher itself can't `dlopen` it. Surface a
  /// clear marker so callers (PluginManager, the FFI path below)
  /// short-circuit cleanly instead of crashing.
  static bool get isUsable => !Platform.isLinux;

  Future<String> generateFile(
    String modsDir,
    List<String> mods,
    String packName,
  ) async {
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
}

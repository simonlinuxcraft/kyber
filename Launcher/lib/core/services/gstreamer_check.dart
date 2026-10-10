// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 simonlinuxcraft

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:logging/logging.dart';

/// audioplayers on Linux aborts the whole launcher when GStreamer has no
/// playbin element (gst-plugins-base missing), so ask before creating a player.
final bool canPlayAudio = _hasPlaybin();

bool _hasPlaybin() {
  if (!Platform.isLinux) return true;

  try {
    final lib = DynamicLibrary.open('libgstreamer-1.0.so.0');
    final init = lib
        .lookupFunction<
          Int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>),
          int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>)
        >('gst_init_check');
    final find = lib
        .lookupFunction<
          Pointer<Void> Function(Pointer<Utf8>),
          Pointer<Void> Function(Pointer<Utf8>)
        >('gst_element_factory_find');
    final unref = lib
        .lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('gst_object_unref');

    if (init(nullptr, nullptr, nullptr) != 0) {
      final name = 'playbin'.toNativeUtf8();
      final factory = find(name);
      malloc.free(name);
      if (factory != nullptr) {
        unref(factory);
        return true;
      }
    }
  } on Object catch (e) {
    Logger('gstreamer').warning('GStreamer check failed: $e');
  }

  Logger('gstreamer').warning(
    'GStreamer has no playbin (gst-plugins-base), launcher sounds are off',
  );
  return false;
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 simonlinuxcraft

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

// libarchive (BSD licence) reads RAR, RAR5 and 7z. It is loaded from the host
// so the AppImage does not ship it together with its crypto dependencies.
const _libName = 'libarchive.so.13';
const int _blockSize = 1 << 20;
const _archiveOk = 0;
const _archiveEof = 1;
const _archiveWarn = -20;
const _typeMask = 0xF000;
const _typeRegular = 0x8000;
const _typeDirectory = 0x4000;

typedef _Handle = Pointer<Void>;

final class _Libarchive {
  _Libarchive(DynamicLibrary lib)
    : readNew = lib.lookupFunction<_Handle Function(), _Handle Function()>(
        'archive_read_new',
      ),
      supportFilterAll = lib
          .lookupFunction<Int Function(_Handle), int Function(_Handle)>(
            'archive_read_support_filter_all',
          ),
      supportFormatAll = lib
          .lookupFunction<Int Function(_Handle), int Function(_Handle)>(
            'archive_read_support_format_all',
          ),
      openFilename = lib
          .lookupFunction<
            Int Function(_Handle, Pointer<Utf8>, Size),
            int Function(_Handle, Pointer<Utf8>, int)
          >('archive_read_open_filename'),
      nextHeader = lib
          .lookupFunction<
            Int Function(_Handle, Pointer<_Handle>),
            int Function(_Handle, Pointer<_Handle>)
          >('archive_read_next_header'),
      pathnameUtf8 = lib
          .lookupFunction<
            Pointer<Utf8> Function(_Handle),
            Pointer<Utf8> Function(_Handle)
          >('archive_entry_pathname_utf8'),
      pathname = lib
          .lookupFunction<
            Pointer<Utf8> Function(_Handle),
            Pointer<Utf8> Function(_Handle)
          >('archive_entry_pathname'),
      filetype = lib
          .lookupFunction<Uint32 Function(_Handle), int Function(_Handle)>(
            'archive_entry_filetype',
          ),
      readData = lib
          .lookupFunction<
            IntPtr Function(_Handle, Pointer<Uint8>, Size),
            int Function(_Handle, Pointer<Uint8>, int)
          >('archive_read_data'),
      filterBytes = lib
          .lookupFunction<
            Int64 Function(_Handle, Int),
            int Function(_Handle, int)
          >('archive_filter_bytes'),
      errorString = lib
          .lookupFunction<
            Pointer<Utf8> Function(_Handle),
            Pointer<Utf8> Function(_Handle)
          >('archive_error_string'),
      readFree = lib
          .lookupFunction<Int Function(_Handle), int Function(_Handle)>(
            'archive_read_free',
          );

  final _Handle Function() readNew;
  final int Function(_Handle) supportFilterAll;
  final int Function(_Handle) supportFormatAll;
  final int Function(_Handle, Pointer<Utf8>, int) openFilename;
  final int Function(_Handle, Pointer<_Handle>) nextHeader;
  final Pointer<Utf8> Function(_Handle) pathnameUtf8;
  final Pointer<Utf8> Function(_Handle) pathname;
  final int Function(_Handle) filetype;
  final int Function(_Handle, Pointer<Uint8>, int) readData;
  final int Function(_Handle, int) filterBytes;
  final Pointer<Utf8> Function(_Handle) errorString;
  final int Function(_Handle) readFree;

  String error(_Handle a) {
    final message = errorString(a);
    return message == nullptr
        ? 'unknown libarchive error'
        : message.toDartString();
  }
}

/// Extracts a RAR or 7z archive into [outputDirectory] on Linux.
Future<void> extractWithLibarchive(
  String archivePath,
  String outputDirectory, {
  void Function(int current, int total)? onProgress,
}) async {
  final receiver = ReceivePort()
    ..listen((message) {
      if (message is List<int>) onProgress?.call(message[0], message[1]);
    });
  try {
    await _runIsolated(archivePath, outputDirectory, receiver.sendPort);
  } finally {
    receiver.close();
  }
}

Future<void> _runIsolated(String archive, String output, SendPort progress) =>
    Isolate.run(() => _extract(archive, output, progress));

void _extract(String archivePath, String outputDirectory, SendPort progress) {
  final _Libarchive lib;
  try {
    lib = _Libarchive(DynamicLibrary.open(_libName));
  } on ArgumentError {
    throw Exception(
      'libarchive was not found. Install it with your package manager '
      'to unpack RAR and 7z mods.',
    );
  }

  final total = File(archivePath).lengthSync();
  final a = lib.readNew();
  final nativePath = archivePath.toNativeUtf8();
  final entry = calloc<_Handle>();
  final buffer = calloc<Uint8>(_blockSize);
  try {
    lib
      ..supportFilterAll(a)
      ..supportFormatAll(a);
    if (lib.openFilename(a, nativePath, _blockSize) != _archiveOk) {
      throw Exception('Cannot open $archivePath: ${lib.error(a)}');
    }

    while (true) {
      final status = lib.nextHeader(a, entry);
      if (status == _archiveEof) break;
      if (status != _archiveOk && status != _archiveWarn) {
        throw Exception('Cannot read $archivePath: ${lib.error(a)}');
      }

      var name = lib.pathnameUtf8(entry.value);
      if (name == nullptr) name = lib.pathname(entry.value);
      if (name == nullptr) {
        throw Exception('Entry without a readable name in $archivePath');
      }
      final target = archiveEntryTarget(outputDirectory, name.toDartString());
      if (target == null) continue;

      final type = lib.filetype(entry.value) & _typeMask;
      if (type == _typeDirectory) {
        Directory(target).createSync(recursive: true);
        continue;
      }
      // Links and devices are never mod content.
      if (type != _typeRegular) continue;

      Directory(p.dirname(target)).createSync(recursive: true);
      final out = File(target).openSync(mode: FileMode.writeOnly);
      try {
        while (true) {
          final read = lib.readData(a, buffer, _blockSize);
          if (read == 0) break;
          if (read < 0) {
            throw Exception('Cannot extract $target: ${lib.error(a)}');
          }
          out.writeFromSync(buffer.asTypedList(read));
        }
      } finally {
        out.closeSync();
      }
      progress.send([lib.filterBytes(a, -1), total]);
    }
  } finally {
    lib.readFree(a);
    calloc
      ..free(nativePath)
      ..free(entry)
      ..free(buffer);
  }
}

/// Where an archive entry lands below [root], or null for the root itself.
/// Throws for absolute paths and paths that climb out of [root].
String? archiveEntryTarget(String root, String entryName) {
  final name = entryName.replaceAll(r'\', '/');
  final base = p.normalize(root);
  final target = p.normalize(p.join(base, name));
  if (p.isAbsolute(name) || (target != base && !p.isWithin(base, target))) {
    throw Exception('Unsafe path in archive: $entryName');
  }
  return target == base ? null : target;
}

@TestOn('linux')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kyber_launcher/core/services/libarchive_service.dart';
import 'package:path/path.dart';

/// RAR and 7z go through the host libarchive on Linux. The fixtures are 7z
/// because no free tool writes RAR; escape.7z holds a single `../evil.fbmod`.
void main() {
  late Directory out;

  setUp(() {
    out = Directory.systemTemp.createTempSync('kyber_libarchive_test');
  });

  tearDown(() {
    if (out.existsSync()) out.deleteSync(recursive: true);
  });

  test('extracts files and folders from a 7z archive', () async {
    final progress = <List<int>>[];

    await extractWithLibarchive(
      'test/fixtures/mod.7z',
      out.path,
      onProgress: (current, total) => progress.add([current, total]),
    );

    expect(
      File(join(out.path, 'Mod Folder', 'a.fbmod')).readAsStringSync(),
      'first mod\n',
    );
    expect(
      File(join(out.path, 'b.fbmod')).readAsStringSync(),
      'second mod\n',
    );
    expect(progress, isNotEmpty);
    expect(progress.last[1], File('test/fixtures/mod.7z').lengthSync());
  });

  test('refuses an entry that climbs out of the target folder', () async {
    final target = Directory(join(out.path, 'target'))..createSync();

    await expectLater(
      extractWithLibarchive('test/fixtures/escape.7z', target.path),
      throwsA(isA<Exception>()),
    );
    expect(File(join(out.path, 'evil.fbmod')).existsSync(), isFalse);
  });

  test('maps entry names below the target folder', () {
    expect(archiveEntryTarget('/m', 'a/b.fbmod'), '/m/a/b.fbmod');
    expect(archiveEntryTarget('/m', r'a\b.fbmod'), '/m/a/b.fbmod');
    expect(archiveEntryTarget('/m', './'), isNull);
    expect(() => archiveEntryTarget('/m', '/etc/passwd'), throwsException);
    expect(() => archiveEntryTarget('/m', 'a/../../x'), throwsException);
  });
}

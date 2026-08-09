import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kyber_launcher/features/mods/dialogs/delete_mods_dialog.dart';
import 'package:path/path.dart';

/// Deleting a mod removes the folder it unpacked into, but this runs inside a
/// delete path, so the case that matters most is the one where it must do
/// nothing: a mod sitting directly in the mods folder.
void main() {
  late Directory base;

  setUp(() {
    base = Directory.systemTemp.createTempSync('kyber_mods_test');
  });

  tearDown(() {
    if (base.existsSync()) base.deleteSync(recursive: true);
  });

  test('removes the download folder once the mod is gone', () {
    final folder = Directory(join(base.path, 'Some Mod-1234-1-0-1700000000'))
      ..createSync();

    pruneEmptyModFolder(base.path, 'Some Mod-1234-1-0-1700000000/mod.fbmod');

    expect(folder.existsSync(), isFalse);
  });

  test('never removes the mods folder itself', () {
    pruneEmptyModFolder(base.path, 'mod.fbmod');

    expect(base.existsSync(), isTrue);
  });

  test('keeps a folder that still holds something', () {
    final folder = Directory(join(base.path, 'Some Mod-1234-1-0-1700000000'))
      ..createSync();
    File(join(folder.path, 'readme.txt')).writeAsStringSync('keep me');

    pruneEmptyModFolder(base.path, 'Some Mod-1234-1-0-1700000000/mod.fbmod');

    expect(folder.existsSync(), isTrue);
  });

  test('stays inside the mods folder', () {
    final outside = Directory(join(base.parent.path, 'kyber_outside_test'))
      ..createSync();
    addTearDown(() {
      if (outside.existsSync()) outside.deleteSync(recursive: true);
    });

    pruneEmptyModFolder(base.path, '../kyber_outside_test/mod.fbmod');

    expect(outside.existsSync(), isTrue);
  });
}

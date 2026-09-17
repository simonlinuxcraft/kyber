import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kyber_launcher/features/download_manager/services/download_post_processor.dart';
import 'package:kyber_launcher/features/mods/services/mod_update_service.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'a mod update replaces its old download and keeps Nexus provenance',
    () async {
      final root = await Directory.systemTemp.createTemp('kyber-mod-update.');
      addTearDown(() => root.delete(recursive: true));

      final oldDir = Directory(p.join(root.path, 'old-download'));
      await oldDir.create();
      await File(p.join(oldDir.path, 'sample.fbmod')).writeAsString('old');
      final extracted = File(p.join(root.path, 'sample.fbmod'));
      await extracted.writeAsString('new');

      await DownloadPostProcessor.finishModUpdate(
        basePath: root.path,
        metadata: jsonEncode({
          'type': 'mod-update',
          'source': 'old-download',
          'modId': 14257,
          'fileId': 1234,
          'uploaded': 2000000000,
        }),
        extractedFiles: [extracted.path],
      );

      final newDir = Directory(
        p.join(root.path, 'nexus-update-14257-1234-2000000000'),
      );
      final newFile = File(p.join(newDir.path, 'sample.fbmod'));
      expect(oldDir.existsSync(), isFalse);
      expect(extracted.existsSync(), isFalse);
      expect(await newFile.readAsString(), 'new');
      final ref = ModUpdateService.referenceFor(
        p.relative(newFile.path, from: root.path),
      );
      expect(ref?.modId, 14257);
      expect(ref?.uploaded, 2000000000);
    },
  );

  test('a partial update keeps the files it did not ship', () async {
    final root = await Directory.systemTemp.createTemp('kyber-mod-partial.');
    addTearDown(() => root.delete(recursive: true));

    final oldDir = Directory(p.join(root.path, 'old-download'));
    await Directory(p.join(oldDir.path, 'textures')).create(recursive: true);
    await File(p.join(oldDir.path, 'sample.fbmod')).writeAsString('old');
    await File(
      p.join(oldDir.path, 'textures', 'skin.res'),
    ).writeAsString('art');
    final extracted = File(p.join(root.path, 'sample.fbmod'));
    await extracted.writeAsString('new');

    await DownloadPostProcessor.finishModUpdate(
      basePath: root.path,
      metadata: jsonEncode({
        'type': 'mod-update',
        'source': 'old-download',
        'modId': 14257,
        'fileId': 1234,
        'uploaded': 2000000000,
      }),
      extractedFiles: [extracted.path],
    );

    final newDir = p.join(root.path, 'nexus-update-14257-1234-2000000000');
    expect(oldDir.existsSync(), isFalse);
    expect(await File(p.join(newDir, 'sample.fbmod')).readAsString(), 'new');
    expect(
      await File(p.join(newDir, 'textures', 'skin.res')).readAsString(),
      'art',
    );
  });
}

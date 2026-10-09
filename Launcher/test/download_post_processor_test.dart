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
      expect(ref?.fileId, 1234);
    },
  );

  test('an update does not carry over a renamed mod file', () async {
    final root = await Directory.systemTemp.createTemp('kyber-mod-rename.');
    addTearDown(() => root.delete(recursive: true));

    final oldDir = Directory(p.join(root.path, 'old-download'));
    await oldDir.create();
    await File(p.join(oldDir.path, 'sample-v1.fbmod')).writeAsString('old');
    final extracted = File(p.join(root.path, 'sample-v2.fbmod'));
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
    expect(File(p.join(newDir, 'sample-v2.fbmod')).existsSync(), isTrue);
    expect(File(p.join(newDir, 'sample-v1.fbmod')).existsSync(), isFalse);
  });

  group('a Nexus download', () {
    final metadata = jsonEncode({
      'type': 'nexus',
      'modId': 14257,
      'fileId': 1234,
    });

    test('moves into a folder named after its ids', () async {
      final root = await Directory.systemTemp.createTemp('kyber-nexus.');
      addTearDown(() => root.delete(recursive: true));
      final mod = File(p.join(root.path, 'sample.fbmod'));
      final readme = File(p.join(root.path, 'readme.txt'));
      await mod.writeAsString('mod');
      await readme.writeAsString('read me');

      await DownloadPostProcessor.fileNexusDownload(
        basePath: root.path,
        metadata: metadata,
        extractedFiles: [mod.path, readme.path],
      );

      final dir = p.join(root.path, 'nexus-14257-1234');
      expect(mod.existsSync(), isFalse);
      expect(readme.existsSync(), isFalse);
      expect(await File(p.join(dir, 'sample.fbmod')).readAsString(), 'mod');
      expect(File(p.join(dir, 'readme.txt')).existsSync(), isTrue);
      final ref = ModUpdateService.referenceFor(
        'nexus-14257-1234/sample.fbmod',
      );
      expect(ref?.fileId, 1234);
    });

    test('downloaded again drops the loose copy', () async {
      final root = await Directory.systemTemp.createTemp('kyber-nexus-again.');
      addTearDown(() => root.delete(recursive: true));
      final dir = Directory(p.join(root.path, 'nexus-14257-1234'));
      await dir.create();
      await File(p.join(dir.path, 'sample.fbmod')).writeAsString('first');
      final loose = File(p.join(root.path, 'sample.fbmod'));
      await loose.writeAsString('second');

      await DownloadPostProcessor.fileNexusDownload(
        basePath: root.path,
        metadata: metadata,
        extractedFiles: [loose.path],
      );

      expect(loose.existsSync(), isFalse);
      expect(
        await File(p.join(dir.path, 'sample.fbmod')).readAsString(),
        'first',
      );
    });

    test('without a mod file stays where it is', () async {
      final root = await Directory.systemTemp.createTemp('kyber-nexus-plain.');
      addTearDown(() => root.delete(recursive: true));
      final readme = File(p.join(root.path, 'readme.txt'));
      await readme.writeAsString('read me');

      await DownloadPostProcessor.fileNexusDownload(
        basePath: root.path,
        metadata: metadata,
        extractedFiles: [readme.path],
      );

      expect(readme.existsSync(), isTrue);
      expect(
        Directory(p.join(root.path, 'nexus-14257-1234')).existsSync(),
        isFalse,
      );
    });
  });

  test('other downloads are left in place and never throw', () async {
    final root = await Directory.systemTemp.createTemp('kyber-nexus-other.');
    addTearDown(() => root.delete(recursive: true));
    final mod = File(p.join(root.path, 'sample.fbmod'));
    await mod.writeAsString('mod');

    for (final metadata in ['', 'not json', '{"1":"Server Mod"}']) {
      await DownloadPostProcessor.fileNexusDownload(
        basePath: root.path,
        metadata: metadata,
        extractedFiles: [mod.path],
      );
    }

    expect(mod.existsSync(), isTrue);
  });

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

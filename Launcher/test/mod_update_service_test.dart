import 'package:flutter_test/flutter_test.dart';
import 'package:kyber_launcher/features/mods/services/mod_update_service.dart';
import 'package:nexus_bridge/nexus_bridge.dart';

FileElement file(int id, int uploaded, {int category = 1, String? fileName}) =>
    FileElement(
      id: [id],
      uid: id,
      fileId: id,
      name: 'File $id',
      version: '$id',
      categoryId: category,
      categoryName: CategoryName.MAIN,
      isPrimary: true,
      size: 1,
      fileName: fileName ?? 'file-$id.zip',
      uploadedTimestamp: uploaded,
      uploadedTime: DateTime.fromMillisecondsSinceEpoch(
        uploaded * 1000,
        isUtc: true,
      ),
      modVersion: '$id',
      externalVirusScanUrl: null,
      description: '',
      sizeKb: 1,
      sizeInBytes: 1,
      changelogHtml: null,
      contentPreviewLink: '',
    );

FileUpdate link(int from, int to) => FileUpdate(
  oldFileId: from,
  newFileId: to,
  oldFileName: 'file-$from.zip',
  newFileName: 'file-$to.zip',
  uploadedTimestamp: 0,
  uploadedTime: DateTime.utc(2026),
);

ModUpdateReference ref(String folder) =>
    ModUpdateService.referenceFor('$folder/a.fbmod')!;

/// The update check hinges on reading the Nexus mod id and upload time back
/// out of the folder name a download left behind. Names below are real ones
/// from an installed mod folder.
void main() {
  test('reads mod id and upload time from a Nexus download folder', () {
    final ref = ModUpdateService.referenceFor(
      'Maul Shadow Lord Sabers 1.1-13865-1-1-1777560401/Sabers.fbmod',
    );
    expect(ref?.modId, 13865);
    expect(ref?.uploaded, 1777560401);
  });

  test('handles dashes and brackets in the mod name', () {
    expect(
      ModUpdateService.referenceFor(
        'Addon Pack - No Flying Geonosians-7747-1-0-1644735493/a.fbmod',
      )?.modId,
      7747,
    );
    expect(
      ModUpdateService.referenceFor(
        'Shin Hati (Dooku Replacer)-9959-1b-1698366976/a.fbmod',
      )?.modId,
      9959,
    );
    expect(
      ModUpdateService.referenceFor(
        'Clone Wars AT-TE-1028-1-4-1604016321/a.fbmod',
      )?.modId,
      1028,
    );
  });

  test('reads the current Nexus download folder format', () {
    final ref = ModUpdateService.referenceFor(
      'The Clone Wars R2D2 14257 1 2026-07-10T00-26Z 6bXLeGvIi/a.fbmod',
    );
    expect(ref?.modId, 14257);
    expect(ref?.uploaded, isNull);
    expect(ref?.uploadedMinute, DateTime.utc(2026, 7, 10, 0, 26));
  });

  test('reads the current format with a version after the token', () {
    final ref = ModUpdateService.referenceFor(
      'Knights Of Kyber 14434 2 2026-08-07T13-12Z ksAhpYOCt-2-0/a.fbmod',
    );
    expect(ref?.modId, 14434);
    expect(ref?.uploadedMinute, DateTime.utc(2026, 8, 7, 13, 12));
  });

  test('reads mod and file id from a launcher download folder', () {
    final download = ModUpdateService.referenceFor('nexus-14257-1234/a.fbmod');
    expect(download?.modId, 14257);
    expect(download?.fileId, 1234);

    final update = ModUpdateService.referenceFor(
      'nexus-update-14257-1234-2000000000/a.fbmod',
    );
    expect(update?.modId, 14257);
    expect(update?.fileId, 1234);
  });

  test('follows Nexus replacements to the newest file', () {
    final response = NexusModFile(
      files: [file(10, 1000), file(11, 1100), file(12, 1200)],
      fileUpdates: [link(10, 11), link(11, 12)],
    );

    final result = ModUpdateService.resolve(
      response,
      ref('Mod-14257-1-0-0000001000'),
    );
    expect(result.installed?.fileId, 10);
    expect(result.successor?.fileId, 12);
  });

  test('finds the installed file by its id', () {
    final response = NexusModFile(
      files: [file(10, 1000), file(11, 1000)],
      fileUpdates: [link(11, 12)],
    );

    final result = ModUpdateService.resolve(response, ref('nexus-14257-11'));
    expect(result.installed?.fileId, 11);
    expect(result.successor, isNull);
  });

  test('tells same-minute uploads apart by archive name', () {
    final minute = DateTime.utc(2026, 7, 10, 0, 26).millisecondsSinceEpoch;
    final uploaded = minute ~/ 1000;
    const folder = 'R2D2 14257 1 2026-07-10T00-26Z 6bXLeGvIi';
    final response = NexusModFile(
      files: [
        file(10, uploaded, fileName: '$folder.zip'),
        file(11, uploaded + 20, fileName: 'R2D2 Extra 14257 1 x.zip'),
      ],
      fileUpdates: [],
    );

    expect(
      ModUpdateService.resolve(response, ref(folder)).installed?.fileId,
      10,
    );
  });

  test('takes the one live file when the installed one was retired', () {
    final response = NexusModFile(
      files: [file(10, 1000, category: 4), file(11, 1100)],
      fileUpdates: [],
    );

    final result = ModUpdateService.resolve(response, ref('nexus-14257-10'));
    expect(result.successor?.fileId, 11);
  });

  test('takes the one live file when the installed one is gone', () {
    final response = NexusModFile(
      files: [file(10, 1000, category: 7), file(11, 1100)],
      fileUpdates: [],
    );

    final result = ModUpdateService.resolve(response, ref('nexus-14257-9'));
    expect(result.installed, isNull);
    expect(result.successor?.fileId, 11);
  });

  test('stays silent when several files are still live', () {
    final response = NexusModFile(
      files: [
        file(10, 1000, category: 4),
        file(11, 1100),
        file(12, 1200, category: 3),
      ],
      fileUpdates: [],
    );

    expect(
      ModUpdateService.resolve(response, ref('nexus-14257-10')).successor,
      isNull,
    );
  });

  test('a current file without replacement has no update', () {
    final response = NexusModFile(
      files: [file(10, 1000), file(11, 1100, category: 3)],
      fileUpdates: [],
    );

    final result = ModUpdateService.resolve(response, ref('nexus-14257-10'));
    expect(result.installed?.fileId, 10);
    expect(result.successor, isNull);
  });

  test('an unresolved upload minute is not taken for a gone file', () {
    final uploaded =
        DateTime.utc(2026, 7, 10, 0, 26).millisecondsSinceEpoch ~/ 1000;
    final response = NexusModFile(
      files: [file(10, uploaded, category: 4), file(11, uploaded + 20)],
      fileUpdates: [],
    );

    final result = ModUpdateService.resolve(
      response,
      ref('R2D2 14257 1 2026-07-10T00-26Z 6bXLeGvIi'),
    );
    expect(result.installed, isNull);
    expect(result.successor, isNull);
  });

  test('gives up on folders without a Nexus reference', () {
    // hand-copied
    expect(ModUpdateService.referenceFor('Clone Wars Yoda.fbmod'), isNull);
    // Frosty collection, slug plus random suffix
    expect(
      ModUpdateService.referenceFor(
        'battlefront-plus-100_final_1b-miwhmxnv/a.fbmod',
      ),
      isNull,
    );
    // the launcher's own uuid folders
    expect(
      ModUpdateService.referenceFor(
        '0c8cf839-a715-450b-8595-f9e7488f1be7/a.fbmod',
      ),
      isNull,
    );
  });
}

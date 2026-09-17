import 'package:flutter_test/flutter_test.dart';
import 'package:kyber_launcher/features/mods/services/mod_update_service.dart';
import 'package:nexus_bridge/nexus_bridge.dart';

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

  test('follows Nexus replacements to the newest file', () {
    FileElement file(int id, int uploaded) => FileElement(
      id: [id],
      uid: id,
      fileId: id,
      name: 'File $id',
      version: '$id',
      categoryId: 1,
      categoryName: CategoryName.MAIN,
      isPrimary: true,
      size: 1,
      fileName: 'file-$id.zip',
      uploadedTimestamp: uploaded,
      uploadedTime: DateTime.fromMillisecondsSinceEpoch(uploaded * 1000),
      modVersion: '$id',
      externalVirusScanUrl: null,
      description: '',
      sizeKb: 1,
      sizeInBytes: 1,
      changelogHtml: null,
      contentPreviewLink: '',
    );

    final response = NexusModFile(
      files: [file(10, 1000), file(11, 1100), file(12, 1200)],
      fileUpdates: [
        FileUpdate(
          oldFileId: 10,
          newFileId: 11,
          oldFileName: 'file-10.zip',
          newFileName: 'file-11.zip',
          uploadedTimestamp: 1100,
          uploadedTime: DateTime.fromMillisecondsSinceEpoch(1100000),
        ),
        FileUpdate(
          oldFileId: 11,
          newFileId: 12,
          oldFileName: 'file-11.zip',
          newFileName: 'file-12.zip',
          uploadedTimestamp: 1200,
          uploadedTime: DateTime.fromMillisecondsSinceEpoch(1200000),
        ),
      ],
    );

    expect(ModUpdateService.successorOf(response, 1000)?.fileId, 12);
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

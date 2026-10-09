import 'package:flutter_test/flutter_test.dart';
import 'package:kyber_launcher/features/download_manager/services/download_orchestrator.dart';

/// Nexus downloads need their mod and file id passed on, or the update check
/// cannot find them later. Everything else keeps its metadata empty.
void main() {
  const mod = 'https://www.nexusmods.com/starwarsbattlefront22017/mods/14257';
  const ids = {'type': 'nexus', 'modId': 14257, 'fileId': 1234};

  test('reads the ids from a mod browser link', () {
    expect(
      DownloadOrchestrator.nexusMetadataFor('$mod?tab=files&file_id=1234'),
      ids,
    );
  });

  test('reads the ids from an nxm link', () {
    expect(
      DownloadOrchestrator.nexusMetadataFor(
        'nxm://starwarsbattlefront22017/mods/14257/files/1234'
        '?key=abc&expires=1790000000&user_id=1',
      ),
      ids,
    );
  });

  test('reads the ids from a collection import link', () {
    // collection_import_dialog appends the file id to the stored mod link
    expect(
      DownloadOrchestrator.nexusMetadataFor('$mod?tab=files&file_id=1234'),
      ids,
    );
    expect(
      DownloadOrchestrator.nexusMetadataFor('$mod?file_id=1234&nmm=1'),
      ids,
    );
  });

  test('leaves direct and foreign links alone', () {
    const other = 'https://www.nexusmods.com/skyrimspecialedition/mods/14257';
    for (final link in [
      'https://cdn.kyber.gg/mods/sample.zip',
      mod,
      '$other?tab=files&file_id=1234',
      '$mod?tab=files&file_id=12345678901',
    ]) {
      expect(DownloadOrchestrator.nexusMetadataFor(link), isNull, reason: link);
    }
  });
}

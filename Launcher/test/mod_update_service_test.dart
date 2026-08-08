import 'package:flutter_test/flutter_test.dart';
import 'package:kyber_launcher/features/mods/services/mod_update_service.dart';

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

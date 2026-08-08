import 'dart:io';

import 'package:kyber_launcher/features/mods/services/mod_service.dart';
import 'package:kyber_launcher/gen/rust/api/archive.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

/// Imports the tar archives written by "EXPORT COLLECTION TAR".
///
/// Such an archive holds the collection definition (`.kbcollection`) next to
/// every mod file it refers to, so unlike a bare definition it can be
/// imported without hunting the mods down on Nexus one by one.
class CollectionArchiveService {
  CollectionArchiveService._();

  static final _logger = Logger('collection_archive');

  /// Unpacks [archivePath] and moves the mod files into the mods folder.
  /// Returns the extracted collection definition, ready to be handed to the
  /// import screen.
  ///
  /// Existing mod files are left untouched: an archive should never quietly
  /// replace a mod the user already has.
  static Future<CollectionImportResult> import(String archivePath) async {
    final staging = await Directory.systemTemp.createTemp('kyber_collection');

    try {
      await extract(filePath: archivePath, targetDir: staging.path);

      final unpacked = staging
          .listSync(recursive: true)
          .whereType<File>()
          .toList();

      final definition = unpacked
          .where((f) => f.path.endsWith('.kbcollection'))
          .firstOrNull;
      if (definition == null) {
        throw const CollectionArchiveException(
          'This archive holds no collection. Export it again from the '
          'collection you want to share.',
        );
      }

      final modsDir = ModService.getBasePath();
      final added = <String>[];
      final skipped = <String>[];

      for (final file in unpacked) {
        if (identical(file, definition) || file.path == definition.path) {
          continue;
        }
        final name = p.basename(file.path);
        final target = File(p.join(modsDir, name));
        if (target.existsSync()) {
          skipped.add(name);
          continue;
        }
        await file.copy(target.path);
        added.add(name);
      }

      // The definition outlives the staging directory, the import screen
      // reads it after this call returns.
      final keptDefinition = File(
        p.join(modsDir, p.basename(definition.path)),
      );
      await definition.copy(keptDefinition.path);

      _logger.info(
        'Imported ${p.basename(archivePath)}: '
        '${added.length} mods added, ${skipped.length} already present',
      );

      return CollectionImportResult(
        definitionPath: keptDefinition.path,
        added: added,
        skipped: skipped,
      );
    } finally {
      if (staging.existsSync()) {
        await staging.delete(recursive: true);
      }
    }
  }

  /// Removes the definition file again once the import screen is done with
  /// it, so it does not linger among the mods.
  static Future<void> discardDefinition(String definitionPath) async {
    final file = File(definitionPath);
    if (file.existsSync()) await file.delete();
  }
}

class CollectionImportResult {
  const CollectionImportResult({
    required this.definitionPath,
    required this.added,
    required this.skipped,
  });

  final String definitionPath;
  final List<String> added;
  final List<String> skipped;
}

class CollectionArchiveException implements Exception {
  const CollectionArchiveException(this.message);
  final String message;

  @override
  String toString() => message;
}

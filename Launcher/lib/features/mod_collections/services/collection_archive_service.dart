import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:kyber_launcher/features/mods/services/mod_service.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

/// Brings shared collections back in, in either of the two shapes they are
/// passed around in.
///
/// A bare `.kbcollection` is just the definition, the way most collections
/// are handed out; the mods it lists have to be present already. The tar
/// written by "EXPORT COLLECTION TAR" carries the definition together with
/// every mod file, so it needs no downloads at all.
class CollectionArchiveService {
  CollectionArchiveService._();

  static final _logger = Logger('collection_archive');

  static const definitionExtension = '.kbcollection';

  /// Unpacks [archivePath] and moves the mod files into the mods folder.
  /// Returns the collection definition, ready to be handed to the import
  /// screen.
  ///
  /// Existing mod files are left untouched: an archive should never quietly
  /// replace a mod the user already has.
  static Future<CollectionImportResult> import(String archivePath) async {
    // A definition on its own needs no unpacking, it is already the file the
    // import screen wants.
    if (archivePath.endsWith(definitionExtension)) {
      _logger.info('Importing collection definition ${p.basename(archivePath)}');
      return CollectionImportResult(
        definitionPath: archivePath,
        added: const [],
        skipped: const [],
        keepsDefinition: true,
      );
    }

    final staging = await Directory.systemTemp.createTemp('kyber_collection');

    try {
      // Reads the archive off disk rather than into memory: a collection
      // export runs into the gigabytes. Handles tar and zip alike.
      await extractFileToDisk(archivePath, staging.path);

      final unpacked = staging
          .listSync(recursive: true)
          .whereType<File>()
          .toList();

      final definition = unpacked
          .where((f) => f.path.endsWith(definitionExtension))
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

      // Mods already on disk, by file name and by size, so a copy that only
      // differs in its folder is recognised as the same file instead of
      // being added a second time.
      // Name and size belong to the same file. Kept in separate sets, a name
      // matching one mod and a size matching another counted as a hit, and the
      // import skipped a file it should have copied.
      final installed = <String>{};
      for (final entry in Directory(modsDir).listSync(recursive: true)) {
        if (entry is! File || !entry.path.endsWith('.fbmod')) continue;
        installed.add(
          '${p.basename(entry.path).toLowerCase()}:${entry.lengthSync()}',
        );
      }

      for (final file in unpacked) {
        if (identical(file, definition) || file.path == definition.path) {
          continue;
        }
        final name = p.basename(file.path);
        final target = File(p.join(modsDir, name));

        final alreadyThere =
            target.existsSync() ||
            installed.contains('${name.toLowerCase()}:${file.lengthSync()}');
        if (alreadyThere) {
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

  /// Removes the copy the import left in the mods folder once the import
  /// screen is done with it. A definition the user picked themselves stays
  /// where it is.
  static Future<void> cleanUp(CollectionImportResult result) async {
    if (result.keepsDefinition) return;
    final file = File(result.definitionPath);
    if (file.existsSync()) await file.delete();
  }
}

class CollectionImportResult {
  const CollectionImportResult({
    required this.definitionPath,
    required this.added,
    required this.skipped,
    this.keepsDefinition = false,
  });

  final String definitionPath;
  final List<String> added;
  final List<String> skipped;

  /// True when the file belongs to the user and must not be deleted, which
  /// is the case for a definition they picked directly.
  final bool keepsDefinition;
}

class CollectionArchiveException implements Exception {
  const CollectionArchiveException(this.message);
  final String message;

  @override
  String toString() => message;
}

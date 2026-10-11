import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:kyber_launcher/core/services/notification_service.dart';
import 'package:kyber_launcher/features/download_manager/services/archive_extractor.dart';
import 'package:kyber_launcher/features/download_manager/services/platform/download_platform_integration.dart';
import 'package:kyber_launcher/features/mods/services/mod_update_service.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

class DownloadPostProcessor {
  DownloadPostProcessor({
    DownloadPlatformIntegration? platformIntegration,
  }) : _platformIntegration = platformIntegration;

  final DownloadPlatformIntegration? _platformIntegration;
  static final Logger _logger = Logger('download_post_processor');

  Future<void> processCompletedDownload(
    TaskStatusUpdate update, {
    ProgressCallback? onProgress,
  }) async {
    if (update.status != TaskStatus.complete) {
      return;
    }

    try {
      _logger.info('Processing completed download: ${update.task.filename}');

      await _platformIntegration?.setIndeterminate();

      final extractor = ArchiveExtractor(basePath: update.task.directory);

      if (!extractor.isArchive(update.task.filename)) {
        _logger.info('File is not an archive, skipping extraction');
        return;
      }

      _logger.info('Extracting archive: ${update.task.filename}');
      final result = await extractor.extract(
        update.task.filename,
        onProgress: onProgress,
      );

      if (!result.success) {
        _logger.warning('Extraction failed: ${result.error}');
        return;
      }

      try {
        await finishModUpdate(
          basePath: update.task.directory,
          metadata: update.task.metaData,
          extractedFiles: result.extractedFiles,
        );
      } on Object catch (e, s) {
        // Silence here would look like a finished update that did nothing.
        _logger.severe('Mod update could not be installed', e, s);
        NotificationService.showNotification(
          message: e is FileSystemException
              ? 'Mod update not installed: ${e.message}'
              : 'Mod update not installed, see the log for details',
          severity: InfoBarSeverity.error,
        );
      }
      await fileNexusDownload(
        basePath: update.task.directory,
        metadata: update.task.metaData,
        extractedFiles: result.extractedFiles,
        archive: update.task.filename,
      );
      _logger.info('Extraction successful');
    } catch (e, s) {
      _logger.severe('Failed to process completed download', e, s);
    } finally {
      await _platformIntegration?.clear();
    }
  }

  @visibleForTesting
  static Future<void> finishModUpdate({
    required String basePath,
    required String metadata,
    required List<String> extractedFiles,
  }) async {
    if (metadata.isEmpty) return;

    final Object? decoded;
    try {
      decoded = jsonDecode(metadata);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic> || decoded['type'] != 'mod-update') {
      return;
    }

    final source = decoded['source'];
    final modId = decoded['modId'];
    final fileId = decoded['fileId'];
    final uploaded = decoded['uploaded'];
    if (source is! String ||
        p.basename(source) != source ||
        modId is! int ||
        fileId is! int ||
        uploaded is! int) {
      throw const FormatException('Invalid mod update metadata');
    }

    final base = p.normalize(p.absolute(basePath));
    final oldPath = p.normalize(p.join(base, source));
    if (!p.isWithin(base, oldPath) ||
        FileSystemEntity.typeSync(oldPath) == FileSystemEntityType.notFound) {
      throw const FileSystemException('Installed mod update source not found');
    }

    final files = extractedFiles
        .map(File.new)
        .where((file) => file.existsSync())
        .toList();
    if (!files.any((file) => p.extension(file.path) == '.fbmod')) {
      throw const FileSystemException('Downloaded update contains no mod file');
    }

    final newDir = Directory(
      p.join(base, 'nexus-update-$modId-$fileId-$uploaded'),
    );
    if (newDir.existsSync()) {
      throw const FileSystemException('Downloaded mod update already exists');
    }

    await newDir.create();
    try {
      for (final file in files) {
        await file.rename(p.join(newDir.path, p.basename(file.path)));
      }
    } on Object {
      if (newDir.existsSync()) await newDir.delete(recursive: true);
      rethrow;
    }

    // Past this point the new version is in place. Removing the old install
    // must not take it down with it, so no rollback below.
    if (FileSystemEntity.typeSync(oldPath) == FileSystemEntityType.directory) {
      final old = Directory(oldPath);
      // An update often ships only what changed. Carry over the rest instead
      // of deleting textures and patches the new archive did not include.
      // Old mod files stay behind: a renamed one would install both versions.
      for (final kept in old.listSync(recursive: true).whereType<File>()) {
        if (p.extension(kept.path) == '.fbmod') continue;
        final target = p.join(
          newDir.path,
          p.relative(kept.path, from: oldPath),
        );
        if (File(target).existsSync()) continue;
        await Directory(p.dirname(target)).create(recursive: true);
        await kept.rename(target);
      }
      await old.delete(recursive: true);
    } else {
      await File(oldPath).delete();
    }
  }

  /// Moves a Nexus download into `nexus-<modId>-<fileId>`, or into a folder
  /// named after the Nexus archive when only that is known (server, party and
  /// dropped downloads). The update check reads the ids back from there. Never
  /// throws: a mod left in the root still works, the update check just cannot
  /// see it.
  static Future<void> fileNexusDownload({
    required String basePath,
    required String metadata,
    required List<String> extractedFiles,
    String? archive,
  }) async {
    try {
      final Object? decoded;
      try {
        decoded = metadata.isEmpty ? null : jsonDecode(metadata);
      } on FormatException {
        return;
      }
      final String folder;
      if (decoded is Map<String, dynamic> && decoded['type'] == 'nexus') {
        final modId = decoded['modId'];
        final fileId = decoded['fileId'];
        if (modId is! int || fileId is! int) return;
        folder = 'nexus-$modId-$fileId';
      } else if (decoded is Map<String, dynamic> &&
          decoded['type'] == 'mod-update') {
        return;
      } else {
        final name = archive == null ? '' : p.basenameWithoutExtension(archive);
        if (ModUpdateService.referenceFor(name) == null) return;
        folder = name;
      }

      final files = extractedFiles
          .map(File.new)
          .where((file) => file.existsSync())
          .toList();
      if (!files.any((file) => p.extension(file.path) == '.fbmod')) return;

      final dir = Directory(p.join(basePath, folder));
      await dir.create();
      for (final file in files) {
        final target = p.join(dir.path, p.basename(file.path));
        if (File(target).existsSync()) {
          await file.delete();
        } else {
          await file.rename(target);
        }
      }
    } on Object catch (e, s) {
      _logger.warning('Nexus download left in the mods folder root', e, s);
    }
  }
}

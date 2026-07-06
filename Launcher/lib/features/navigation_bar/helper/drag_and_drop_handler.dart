import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:kyber_collection/kyber_collection.dart';
import 'package:kyber_launcher/core/routing/app_router.dart';
import 'package:kyber_launcher/core/services/notification_service.dart';
import 'package:kyber_launcher/features/download_manager/models/download_link_type.dart';
import 'package:kyber_launcher/features/download_manager/models/download_request.dart';
import 'package:kyber_launcher/features/download_manager/services/archive_extractor.dart';
import 'package:kyber_launcher/features/download_manager/services/download_orchestrator.dart';
import 'package:kyber_launcher/features/mod_browser/dialogs/collection_import_dialog.dart';
import 'package:kyber_launcher/features/mods/services/mod_service.dart';
import 'package:kyber_launcher/injection_container.dart';
import 'package:kyber_launcher/shared/ui/dialog/kyber_dialog.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

class DragAndDropHandler {
  static const int _largeFileSizeBytes = 1024 * 1024 * 1024;

  static const frostyFileFormat = CustomValueFormat(
    applicationId: 'application/octet-stream;extension=fbmod',
  );
  static const kyberCollectionFileFormat = CustomValueFormat(
    applicationId: 'application/octet-stream;extension=kbcollection',
  );
  static const frostyCollectionFormat = CustomValueFormat(
    applicationId: 'application/octet-stream;extension=fbcolletion',
  );

  static List<DataFormat> get supportedFormats => [
    if (Platform.isMacOS) Formats.fileUri,
    Formats.uri,
    Formats.zip,
    Formats.rar,
    Formats.dll,
    Formats.sevenZip,
    frostyFileFormat,
    frostyCollectionFormat,
    kyberCollectionFileFormat,
  ];

  static Future<void> handleDragAndDrop(List<DropItem> items) async {
    for (final item in items) {
      if (item.canProvide(Formats.uri) || item.canProvide(Formats.fileUri)) {
        _handleURI(item);
      } else if (item.canProvide(frostyFileFormat) ||
          item.canProvide(frostyCollectionFormat)) {
        _readFilePath(item).then(_copyFile);
      } else if (item.canProvide(kyberCollectionFileFormat)) {
        unawaited(
          _readFilePath(item).then((file) async {
            final collection = await ModCollection.readCollection(file);
            await showKyberDialog(
              context: navigatorKey.currentContext!,
              builder: (_) => CollectionImportDialog(collection: collection),
            );
          }),
        );
      } else if (item.canProvide(Formats.fileUri)) {
        _readFilePath(item).then(_installZip);
      }
    }
  }

  static Future<void> _installZip(File file) async {
    if (file.statSync().size > _largeFileSizeBytes) {
      NotificationService.info(
        message: 'Extracting large file, this may take a while',
      );
    }

    final extractor = ArchiveExtractor(basePath: ModService.getBasePath());
    await extractor.extract(file.path, deleteSource: false);

    final fileName = path.basename(file.path);
    Logger.root.info('Installed mod: $fileName');
    NotificationService.showNotification(
      message: 'Installed $fileName',
      severity: InfoBarSeverity.success,
    );
  }

  static Future<File> _readFilePath(DropItem item) async {
    final completer = Completer<String>();
    item.dataReader!.getValue(
      Formats.fileUri,
      (value) => completer.complete(value?.toFilePath()),
    );
    return File(await completer.future);
  }

  static Future<void> _copyFile(File file) async {
    final fileName = path.basename(file.path);
    final targetPath = path.join(ModService.getBasePath(), fileName);
    await Isolate.run(() => file.copy(targetPath));
    NotificationService.success(
      message: 'Successfully copied $fileName',
    );
  }

  static void _handleURI(DropItem reader) {
    reader.dataReader!.getValue(
      reader.canProvide(Formats.uri) ? Formats.uri : Formats.fileUri,
      (value) async {
        Uri? uri;
        if (value is NamedUri) {
          uri = value.uri;
        } else if (value is Uri) {
          uri = value;
        }

        if (uri == null) {
          return;
        }

        final isPath = uri.scheme == 'file' || Platform.isMacOS;

        if (isPath &&
            File(Uri.decodeFull(uri.toFilePath())).existsSync() &&
            uri.toFilePath().endsWith('.kbcollection')) {
          final collection = await ModCollection.readCollection(
            File(uri.toFilePath()),
          );
          await showKyberDialog(
            context: navigatorKey.currentContext!,
            builder: (_) => CollectionImportDialog(collection: collection),
          );
          return;
        } else if (isPath && File(Uri.decodeFull(uri.toFilePath())).existsSync()) {
          final file = File(Uri.decodeFull(uri.toFilePath()));
          if (file.path.endsWith('fbmod') ||
              file.path.endsWith('fbcollection')) {
            return _copyFile(file);
          }

          NotificationService.info(
            message: 'Installing zip, this may take a while',
          );

          return _installZip(file);
        }

        if (uri.host == 'www.nexusmods.com' &&
            uri.pathSegments.length == 3 &&
            uri.pathSegments[0] == 'starwarsbattlefront22017' &&
            uri.pathSegments[1] == 'mods') {
          final modId = uri.pathSegments[2];
          router.go('/mods/mod_browser/$modId');
        } else {
          late Response<Object> headRequest;
          try {
            headRequest = await Dio().head<Object>(uri.toString());
          } catch (e) {
            NotificationService.showNotification(
              message: 'Failed to download file',
              severity: InfoBarSeverity.error,
            );
            Logger.root.severe('Failed to download file', e);
            return;
          }

          const allowedTypes = [
            'application/zip',
            'application/octet-stream',
            'application/x-zip-compressed',
          ];
          final contentType = headRequest.headers.value('content-type');
          if (!allowedTypes.contains(contentType)) {
            NotificationService.showNotification(
              message: 'Invalid file type',
              severity: InfoBarSeverity.error,
            );
            return;
          }

          NotificationService.showNotification(
            message: 'Trying to download file',
            severity: InfoBarSeverity.info,
          );
          final contentDisposition = headRequest.headers.value(
            'content-disposition',
          );
          var filename = uri.pathSegments.last;
          if (contentDisposition != null) {
            final match = RegExp(
              'filename="(.+)"',
            ).firstMatch(contentDisposition);
            if (match != null) {
              filename = match.group(1)!;
            }
          }

          if (contentType == 'application/octet-stream') {
            if (!filename.endsWith('.fbmod') &&
                !filename.endsWith('.fbcollection')) {
              NotificationService.showNotification(
                message: 'Unsupported file type: ${path.extension(filename)}',
                severity: InfoBarSeverity.error,
              );
              return;
            }
          }

          final request = DownloadRequest(
            displayName: uri.pathSegments.last,
            link: uri.toString(),
            linkType: DownloadLinkType.direct,
            size: int.parse(headRequest.headers.value('content-length') ?? '0'),
          );
          final enqueued =
              await sl.get<DownloadOrchestrator>().enqueueDownload(request);
          if (enqueued) {
            NotificationService.showNotification(
              message: 'Queued download for $filename',
              severity: InfoBarSeverity.info,
            );
          }
          return;
        }
      },
    );
  }
}

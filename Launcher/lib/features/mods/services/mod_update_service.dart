import 'package:collection/collection.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:kyber_collection/kyber_collection.dart';
import 'package:kyber_launcher/features/nexusmods/services/nexusmods_service.dart';
import 'package:kyber_launcher/injection_container.dart';
import 'package:logging/logging.dart';
import 'package:nexus_bridge/nexus_bridge.dart';
import 'package:path/path.dart' as p;

/// Tells you which installed mods have a newer file on Nexus.
///
/// Nothing records which Nexus mod an installed file came from, but the
/// folder a Nexus download lands in carries both pieces:
///
///     Maul Shadow Lord Sabers 1.1-13865-1-1-1777560401
///                             ^^^^^ mod id  ^^^^^^^^^^ upload time
///
/// Downloads through the launcher land in `nexus-<modId>-<fileId>`.
/// Mods that were copied in by hand, and Frosty collections (their folder is
/// slugified with a random suffix), have no id and are skipped.
class ModUpdateService with ChangeNotifier {
  static const _game = 'starwarsbattlefront22017';

  /// Old version, removed, archived.
  static const _retiredCategories = {4, 6, 7};

  static final _launcherFolderPattern = RegExp(
    r'^nexus-(?:update-)?(\d{1,9})-(\d{1,9})(?:-(\d{10}))?$',
  );

  /// Trailing part of a Nexus download folder: mod id, then version parts,
  /// then the upload timestamp.
  static final _folderPattern = RegExp(
    r'-(\d{2,7})-[\w.]+(?:-[\w.]+)*-(\d{10})$',
  );
  static final _modernFolderPattern = RegExp(
    r' (\d{2,7}) [^ ]+ (\d{4}-\d{2}-\d{2}T\d{2}-\d{2}Z) [A-Za-z0-9]+'
    r'(?:-[\w.]+)*$',
  );

  final _logger = Logger('mod_update_service');

  /// Mod filename to the newest file found on Nexus.
  final Map<String, ModUpdate> _updates = {};

  bool _checking = false;
  bool get isChecking => _checking;

  DateTime? _lastCheck;
  DateTime? get lastCheck => _lastCheck;

  int _failed = 0;
  int _checked = 0;

  /// How many mods could not be checked in the last run. Zero results plus
  /// failures is not the same as "everything is current".
  int get failedCount => _failed;
  int get checkedCount => _checked;

  /// Files of one folder share one [ModUpdate], so this counts folders.
  int get count => _updates.values.toSet().length;
  ModUpdate? updateFor(String filename) => _updates[filename];
  bool hasUpdate(String filename) => _updates.containsKey(filename);

  /// Asks Nexus about every identifiable download, caching shared mod pages.
  /// Nexus allows 2500 requests a day, so this belongs on a button rather
  /// than on every rebuild of the mod list.
  Future<void> check(List<FrostyMod> mods) async {
    if (_checking) return;
    _checking = true;
    _updates.clear();
    notifyListeners();

    _failed = 0;
    final groups = <ModUpdateReference, List<FrostyMod>>{};
    for (final mod in mods) {
      final ref = referenceFor(mod.filename);
      if (ref != null) groups.putIfAbsent(ref, () => []).add(mod);
    }
    _checked = groups.length;
    final responses = <int, NexusModFile>{};
    final failedModIds = <int>{};

    try {
      // The shared client answers from a cache up to four hours old, which
      // hides exactly the upload this check is looking for.
      final client = sl.get<NexusModsService>().nexusBridge.uncachedApiClient;
      for (final entry in groups.entries) {
        final ref = entry.key;
        if (failedModIds.contains(ref.modId)) {
          _failed++;
          continue;
        }
        try {
          final response =
              responses[ref.modId] ??
              await client.getModFiles(_game, ref.modId);
          responses[ref.modId] = response;
          final (:installed, :successor) = resolve(response, ref);
          if (installed == null && successor == null) {
            _failed++;
            _logger.warning(
              'Installed Nexus file could not be identified for mod '
              '${ref.modId}',
            );
            continue;
          }
          if (successor != null) {
            final update = ModUpdate(
              modId: ref.modId,
              fileId: successor.fileId,
              name: successor.name,
              version: successor.modVersion,
              uploaded: successor.uploadedTime,
              uploadedTimestamp: successor.uploadedTimestamp,
            );
            for (final mod in entry.value) {
              _updates[mod.filename] = update;
            }
          }
        } on Object catch (e) {
          _failed++;
          failedModIds.add(ref.modId);
          _logger.warning('Update check failed for mod ${ref.modId}: $e');
        }
      }
    } on Object catch (e) {
      // No Nexus session, e.g. right after logging out.
      _failed = _checked;
      _logger.warning('Update check could not start: $e');
    } finally {
      _checking = false;
      _lastCheck = DateTime.now();
      _logger.info(
        'Checked $_checked identifiable downloads, $count have updates, '
        '$_failed failed',
      );
      notifyListeners();
    }
  }

  void clear() {
    _updates.clear();
    _failed = 0;
    _checked = 0;
    _lastCheck = null;
    notifyListeners();
  }

  /// Drops updates for mods that are gone, usually because the update itself
  /// replaced them, so the badge stops counting them.
  void forgetMissing(List<FrostyMod> installed) {
    final filenames = installed.map((mod) => mod.filename).toSet();
    final before = _updates.length;
    _updates.removeWhere((filename, _) => !filenames.contains(filename));
    if (_updates.length != before) notifyListeners();
  }

  /// Finds the installed file and the newer one to offer, if any.
  ///
  /// A mod page often holds several files that have nothing to do with each
  /// other: main file, optional extras, patches. Comparing an installed file
  /// against the newest file on the page therefore reports an update for
  /// every mod whose page saw any other file uploaded later. Nexus states
  /// which file replaced which in `file_updates`, so walk that first.
  ///
  /// Some authors retire the old file without linking the new one. Then,
  /// like Vortex, take the one file still live on the page, and only if
  /// there is exactly one.
  @visibleForTesting
  static ({FileElement? installed, FileElement? successor}) resolve(
    NexusModFile response,
    ModUpdateReference reference,
  ) {
    final installed = _installedFileFor(response, reference);
    final installedId = installed?.fileId ?? reference.fileId;
    var successor = installedId == null
        ? null
        : _successorAfter(response, installedId);

    // Several files matching one upload minute is not "gone".
    final retired = installed != null
        ? _retiredCategories.contains(installed.categoryId)
        : !response.files.any((file) => _matches(file, reference));
    if (successor == null && retired) {
      successor = response.files
          .where((file) => !_retiredCategories.contains(file.categoryId))
          .singleOrNull;
    }

    return (installed: installed, successor: successor);
  }

  static bool _matches(FileElement file, ModUpdateReference reference) {
    if (reference.fileId != null) return file.fileId == reference.fileId;
    if (reference.uploaded != null) {
      return file.uploadedTimestamp == reference.uploaded;
    }
    final uploaded = file.uploadedTime.toUtc();
    final minute = reference.uploadedMinute!;
    return uploaded.year == minute.year &&
        uploaded.month == minute.month &&
        uploaded.day == minute.day &&
        uploaded.hour == minute.hour &&
        uploaded.minute == minute.minute;
  }

  static FileElement? _installedFileFor(
    NexusModFile response,
    ModUpdateReference reference,
  ) {
    final matches = response.files
        .where((file) => _matches(file, reference))
        .toList();
    if (matches.length < 2) return matches.firstOrNull;

    // Files uploaded in the same minute: the folder keeps the archive name.
    return matches
        .where(
          (file) =>
              p.basenameWithoutExtension(file.fileName) == reference.folder,
        )
        .singleOrNull;
  }

  static FileElement? _successorAfter(
    NexusModFile response,
    int installedFileId,
  ) {
    var currentId = installedFileId;
    FileElement? newest;
    final seen = <int>{currentId};

    while (true) {
      final step = response.fileUpdates
          .where((u) => u.oldFileId == currentId)
          .firstOrNull;
      if (step == null || !seen.add(step.newFileId)) break;
      currentId = step.newFileId;
      newest =
          response.files.where((f) => f.fileId == currentId).firstOrNull ??
          newest;
    }

    return newest;
  }

  @visibleForTesting
  static ModUpdateReference? referenceFor(String filename) {
    final folder = filename.replaceAll(r'\', '/').split('/').first;
    final launcher = _launcherFolderPattern.firstMatch(folder);
    if (launcher != null) {
      return (
        folder: folder,
        modId: int.parse(launcher.group(1)!),
        fileId: int.parse(launcher.group(2)!),
        uploaded: null,
        uploadedMinute: null,
      );
    }

    final match = _folderPattern.firstMatch(folder);
    if (match != null) {
      return (
        folder: folder,
        modId: int.parse(match.group(1)!),
        fileId: null,
        uploaded: int.parse(match.group(2)!),
        uploadedMinute: null,
      );
    }

    final modern = _modernFolderPattern.firstMatch(folder);
    if (modern == null) return null;
    final value = modern.group(2)!;
    return (
      folder: folder,
      modId: int.parse(modern.group(1)!),
      fileId: null,
      uploaded: null,
      uploadedMinute: DateTime.parse(
        '${value.substring(0, 13)}:${value.substring(14, 16)}:00Z',
      ),
    );
  }
}

typedef ModUpdateReference = ({
  String folder,
  int modId,
  int? fileId,
  int? uploaded,
  DateTime? uploadedMinute,
});

class ModUpdate {
  const ModUpdate({
    required this.modId,
    required this.fileId,
    required this.name,
    required this.version,
    required this.uploaded,
    required this.uploadedTimestamp,
  });

  final int modId;
  final int fileId;
  final String name;
  final String version;
  final DateTime uploaded;
  final int uploadedTimestamp;

  String get nexusUrl =>
      'https://www.nexusmods.com/starwarsbattlefront22017/mods/$modId';

  /// Shape the download pipeline expects: mod id as the last path segment,
  /// file id as a query parameter (see NexusDownloadService.getNexusDownload).
  String get downloadUrl => '$nexusUrl?file_id=$fileId';
}

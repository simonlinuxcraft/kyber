import 'package:collection/collection.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:kyber_collection/kyber_collection.dart';
import 'package:kyber_launcher/features/nexusmods/services/nexusmods_service.dart';
import 'package:kyber_launcher/injection_container.dart';
import 'package:logging/logging.dart';
import 'package:nexus_bridge/nexus_bridge.dart';

/// Tells you which installed mods have a newer file on Nexus.
///
/// Nothing records which Nexus mod an installed file came from, but the
/// folder a Nexus download lands in carries both pieces:
///
///     Maul Shadow Lord Sabers 1.1-13865-1-1-1777560401
///                             ^^^^^ mod id  ^^^^^^^^^^ upload time
///
/// Mods that were copied in by hand, and Frosty collections (their folder is
/// slugified with a random suffix), have no id and are skipped.
class ModUpdateService with ChangeNotifier {
  static const _game = 'starwarsbattlefront22017';

  /// Trailing part of a Nexus download folder: mod id, then version parts,
  /// then the upload timestamp.
  static final _folderPattern = RegExp(r'-(\d{2,7})-[\w.]+(?:-[\w.]+)*-(\d{10})$');

  final _logger = Logger('mod_update_service');

  /// Mod filename to the newest file found on Nexus.
  final Map<String, ModUpdate> _updates = {};

  bool _checking = false;
  bool get isChecking => _checking;

  DateTime? _lastCheck;
  DateTime? get lastCheck => _lastCheck;

  int _failed = 0;

  /// How many mods could not be checked in the last run. Zero results plus
  /// failures is not the same as "everything is current".
  int get failedCount => _failed;

  int get count => _updates.length;
  ModUpdate? updateFor(String filename) => _updates[filename];
  bool hasUpdate(String filename) => _updates.containsKey(filename);

  /// Asks Nexus about every mod that carries an id, one request each.
  /// Nexus allows 2500 requests a day, so this belongs on a button rather
  /// than on every rebuild of the mod list.
  Future<void> check(List<FrostyMod> mods) async {
    if (_checking) return;
    _checking = true;
    _updates.clear();
    notifyListeners();

    final client = sl.get<NexusModsService>().nexusBridge.apiClient;
    var checked = 0;
    _failed = 0;

    try {
      for (final mod in mods) {
        final ref = referenceFor(mod.filename);
        if (ref == null) continue;
        checked++;

        try {
          final response = await client.getModFiles(_game, ref.modId);
          final successor = successorOf(response, ref.uploaded);
          if (successor != null) {
            _updates[mod.filename] = ModUpdate(
              modId: ref.modId,
              fileId: successor.fileId,
              name: successor.name,
              version: successor.modVersion,
              uploaded: successor.uploadedTime,
            );
          }
        } on Object catch (e) {
          _failed++;
          _logger.warning('Update check failed for mod ${ref.modId}: $e');
        }
      }
    } finally {
      _checking = false;
      _lastCheck = DateTime.now();
      _logger.info(
        'Checked $checked mods, ${_updates.length} have updates, '
        '$_failed failed',
      );
      notifyListeners();
    }
  }

  void clear() {
    _updates.clear();
    _failed = 0;
    _lastCheck = null;
    notifyListeners();
  }

  /// Follows Nexus' own replacement chain for the installed file.
  ///
  /// A mod page often holds several files that have nothing to do with each
  /// other: main file, optional extras, patches. Comparing an installed file
  /// against the newest file on the page therefore reports an update for
  /// every mod whose page saw any other file uploaded later. Nexus states
  /// which file replaced which in `file_updates`, so walk that instead and
  /// stay silent when the installed file cannot be identified.
  @visibleForTesting
  static FileElement? successorOf(NexusModFile response, int installedUpload) {
    final installed = response.files
        .where((f) => f.uploadedTimestamp == installedUpload)
        .firstOrNull;
    if (installed == null) return null;

    var currentId = installed.fileId;
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
  static ({int modId, int uploaded})? referenceFor(String filename) {
    final folder = filename.split('/').first;
    final match = _folderPattern.firstMatch(folder);
    if (match == null) return null;
    return (
      modId: int.parse(match.group(1)!),
      uploaded: int.parse(match.group(2)!),
    );
  }
}

class ModUpdate {
  const ModUpdate({
    required this.modId,
    required this.fileId,
    required this.name,
    required this.version,
    required this.uploaded,
  });

  final int modId;
  final int fileId;
  final String name;
  final String version;
  final DateTime uploaded;

  String get nexusUrl =>
      'https://www.nexusmods.com/starwarsbattlefront22017/mods/$modId';

  /// Shape the download pipeline expects: mod id as the last path segment,
  /// file id as a query parameter (see NexusDownloadService.getNexusDownload).
  String get downloadUrl => '$nexusUrl?file_id=$fileId';
}

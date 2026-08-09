import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

/// Runs the Better Sabers Mod plugin on Linux.
///
/// The plugin DLL is a Windows .NET assembly the launcher cannot dlopen. It
/// carries a complete .NET single-file bundle though: the standalone manager
/// with its Frosty libraries. This cuts that bundle out, drops it into the
/// Wine prefix Maxima already manages and runs it through umu, which is the
/// same path the game launch takes.
class BsmLinuxHost {
  BsmLinuxHost._();

  static final _logger = Logger('bsm_linux_host');

  /// Marks the end of the embedded bundle's file table. The 8 bytes in front
  /// of it hold the bundle header offset, relative to the start of the
  /// embedded exe. Defined by the .NET single-file host format.
  static final _bundleSignature = Uint8List.fromList([
    0x8b, 0x12, 0x02, 0xb9, 0x6a, 0x61, 0x20, 0x38, //
    0x72, 0x7b, 0x93, 0x02, 0x14, 0xd7, 0xa0, 0x32,
    0x13, 0xf5, 0xb9, 0xe6, 0xef, 0xae, 0x33, 0x18,
    0xee, 0x3b, 0x2d, 0xce, 0x24, 0xb3, 0x6a, 0xae,
  ]);

  static String get _dataHome =>
      Platform.environment['XDG_DATA_HOME'] ??
      p.join(Platform.environment['HOME'] ?? '', '.local', 'share');

  static String get _maximaDir => p.join(_dataHome, 'maxima');
  static String get prefixDir => p.join(_maximaDir, 'wine', 'prefix');
  static String get _umuBin => p.join(_maximaDir, 'wine', 'umu', 'umu-run');
  static String get _protonDir => p.join(_maximaDir, 'wine', 'proton');
  static String get _eacDir => p.join(_maximaDir, 'wine', 'eac_runtime');

  static String get managerExe =>
      p.join(prefixDir, 'drive_c', 'kyber-plugins', 'BetterSabersManager.exe');

  /// Whether the pieces outside our control are in place: Maxima's Wine
  /// runtime and the .NET desktop runtime inside the prefix.
  static bool get wineReady =>
      File(_umuBin).existsSync() && Directory(_protonDir).existsSync();

  static bool get dotnetReady => Directory(
    p.join(prefixDir, 'drive_c', 'Program Files', 'dotnet', 'shared',
        'Microsoft.WindowsDesktop.App'),
  ).existsSync();

  /// The manager is a WPF application, so the prefix needs the Windows
  /// desktop runtime. Pinned on purpose: the plugin targets .NET 10 and a
  /// moving "latest" URL would change what gets installed behind our backs.
  static const _dotnetInstallerUrl =
      'https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/10.0.10/'
      'windowsdesktop-runtime-10.0.10-win-x64.exe';

  /// Downloads and installs the desktop runtime into the prefix, once.
  static Future<void> ensureDotnet() async {
    if (dotnetReady) return;
    if (!wineReady) {
      throw const BsmHostException(
        'Better Sabers needs the Wine runtime Kyber installs for the game. '
        'Start the game once, then try again.',
      );
    }

    final installer = File(
      p.join(prefixDir, 'drive_c', 'kyber-plugins', 'dotnet-desktop.exe'),
    );
    if (!installer.existsSync()) {
      _logger.info('Downloading the .NET desktop runtime for Better Sabers');
      await installer.parent.create(recursive: true);

      // Download to a scratch name and only then take the real one. A
      // connection that drops halfway would otherwise leave a truncated
      // installer behind that looks complete to the next run.
      final partial = File('${installer.path}.part');
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(_dotnetInstallerUrl));
        final response = await request.close();
        if (response.statusCode != 200) {
          throw BsmHostException(
            'Downloading the .NET runtime failed '
            '(HTTP ${response.statusCode}).',
          );
        }

        final sink = partial.openWrite();
        try {
          await response.pipe(sink);
        } finally {
          await sink.close();
        }

        final written = await partial.length();
        final expected = response.contentLength;
        if (expected > 0 && written != expected) {
          throw BsmHostException(
            'The .NET runtime download stopped early '
            '($written of $expected bytes).',
          );
        }
        await partial.rename(installer.path);
      } on Object {
        if (partial.existsSync()) await partial.delete();
        rethrow;
      } finally {
        client.close();
      }
    }

    _logger.info('Installing the .NET desktop runtime into the prefix');
    await _umu(
      'runinprefix',
      [
        r'C:\kyber-plugins\dotnet-desktop.exe',
        '/install',
        '/quiet',
        '/norestart',
      ],
      timeout: _helperTimeout,
    );

    if (!dotnetReady) {
      throw const BsmHostException(
        'The .NET desktop runtime did not install into the Wine prefix.',
      );
    }
    await installer.delete();
  }

  /// Extracts the manager out of [dllPath], unless the copy on disk is
  /// already current. Returns the path to the exe.
  static Future<String> extractManager(String dllPath) async {
    final dll = File(dllPath);
    final exe = File(managerExe);
    if (exe.existsSync() &&
        exe.statSync().modified.isAfter(dll.statSync().modified)) {
      return managerExe;
    }

    final bytes = await dll.readAsBytes();
    final sig = _indexOfSequence(bytes, _bundleSignature);
    if (sig < 0) {
      throw const BsmHostException(
        'This Better Sabers plugin does not contain a bundled manager. '
        'It is probably an older build than 2.0.',
      );
    }

    final start = _lastEmbeddedExeBefore(bytes, sig);
    if (start < 0) {
      throw const BsmHostException(
        'Could not locate the manager inside the plugin file.',
      );
    }

    // Everything from the embedded exe to the end of the DLL. The bundle
    // reader seeks by the header offset, so trailing bytes are harmless and
    // save parsing the file table.
    //
    // Written next to the target and renamed into place: a write cut short
    // would otherwise leave a broken exe that, thanks to its fresh mtime,
    // passes the "already current" check above forever.
    await exe.parent.create(recursive: true);
    final partial = File('${exe.path}.part');
    try {
      await partial.writeAsBytes(
        Uint8List.sublistView(bytes, start),
        flush: true,
      );
      await partial.rename(exe.path);
    } on Object {
      if (partial.existsSync()) await partial.delete();
      rethrow;
    }

    _logger.info(
      'Extracted Better Sabers manager (${bytes.length - start} bytes)',
    );
    return managerExe;
  }

  /// Tells the manager where the game lives, so it never has to ask the user.
  /// It reads this key when it has no config of its own yet.
  static Future<void> writeGamePath(String gamePath) async {
    final dir = FileSystemEntity.isFileSync(gamePath)
        ? p.dirname(gamePath)
        : gamePath;
    await _umu(
      'runinprefix',
      [
        'reg',
        'add',
        r'HKLM\SOFTWARE\EA Games\STAR WARS Battlefront II',
        '/v',
        'Install Dir',
        '/d',
        toWindowsPath(dir),
        '/f',
        '/reg:64',
      ],
      timeout: _helperTimeout,
    );
  }

  /// True from the first preparation step until the manager window closes.
  ///
  /// Guards more than the window itself: there are two entry points in the
  /// UI, and the setup steps before the window all write to fixed paths in
  /// the prefix. Two of them at once would download the runtime twice into
  /// the same file and unpack the manager on top of itself.
  static bool get isRunning => _running;
  static bool _running = false;

  /// Runs the whole sequence under one lock: runtime, extraction, game path,
  /// then the window. Returns the pack the manager generated, or null when
  /// the user closed it without generating.
  static Future<String?> openManager({
    required String dllPath,
    required String modsDir,
    required List<String> mods,
    required String packName,
    String? gamePath,
  }) async {
    if (_running) {
      throw const BsmHostException('Better Sabers is already open.');
    }
    _running = true;
    try {
      await ensureDotnet();
      final exePath = await extractManager(dllPath);
      if (gamePath != null && gamePath.isNotEmpty) {
        await writeGamePath(gamePath);
      }
      return await _runManager(
        exePath: exePath,
        modsDir: modsDir,
        mods: mods,
        packName: packName,
      );
    } finally {
      _running = false;
    }
  }

  static Future<String?> _runManager({
    required String exePath,
    required String modsDir,
    required List<String> mods,
    required String packName,
  }) async {
    // The manager picks its arguments out of the command line by shape, not
    // by position: the mod directory is the one containing ':' that exists,
    // the mod list is the one wrapped in brackets (parsed as a JSON array),
    // and the pack name is the last argument without '.fbmod' in it. It also
    // only accepts entries ending in .fbmod that exist relative to the mod
    // directory, so paths go in with Windows separators.
    final usable = mods.where((m) => m.endsWith('.fbmod')).where((m) {
      if (!_hasWebpScreenshot(p.join(modsDir, m))) return true;
      _logger.warning(
        'Skipping $m: its screenshot is a WebP, which Wine cannot decode. '
        'The manager would abort loading over it.',
      );
      return false;
    });

    final entries = usable.map((m) => m.replaceAll('/', r'\')).toList();

    // Freeze the timestamps now. Keeping File handles around and stat'ing
    // them again afterwards would read the state after the run, so an
    // overwritten pack of the same name would compare equal to itself.
    final before = {
      for (final f in _packsFor(packName)) f.path: f.statSync().modified,
    };

    await _umu('waitforexitandrun', [
      exePath,
      toWindowsPath(modsDir),
      jsonEncode(entries),
      packName,
    ]);

    final after = _packsFor(packName);
    if (after.isEmpty) return null;
    after.sort(
      (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
    );
    final newest = after.first;
    final previous = before[newest.path];
    final isNew =
        previous == null || previous.isBefore(newest.statSync().modified);
    return isNew ? newest.path : null;
  }

  /// `/home/x/mods` becomes `Z:\home\x\mods`, which is how the prefix sees it.
  static String toWindowsPath(String unixPath) =>
      'Z:${unixPath.replaceAll('/', r'\')}';

  /// Deletes earlier generated packs of the same name, keeping [keepPath].
  ///
  /// The manager stamps every pack it writes with a random suffix, so
  /// generating twice leaves two files that carry the same mod name and
  /// version. They pile up in the mods folder and show up twice in a
  /// collection, where only the newest one is meant to be used.
  static Future<List<String>> pruneOlderPacks({
    required String modsDir,
    required String packName,
    required String keepPath,
  }) async {
    final removed = <String>[];
    final keep = p.normalize(keepPath);

    for (final dir in [Directory(modsDir), ..._packDirectories()]) {
      if (!dir.existsSync()) continue;
      for (final entry in dir.listSync()) {
        if (entry is! File) continue;
        final name = p.basename(entry.path);
        if (!name.startsWith('$packName.') ||
            !name.endsWith('.bsm.fbmod') ||
            p.normalize(entry.path) == keep) {
          continue;
        }
        try {
          await entry.delete();
          removed.add(name);
        } on Object catch (e) {
          _logger.warning('Could not remove the old pack $name: $e');
        }
      }
    }

    if (removed.isNotEmpty) {
      _logger.info('Removed ${removed.length} older Better Sabers packs');
    }
    return removed;
  }

  /// The manager's output folders inside the prefix, one per prefix user.
  static Iterable<Directory> _packDirectories() sync* {
    final users = Directory(p.join(prefixDir, 'drive_c', 'users'));
    if (!users.existsSync()) return;
    for (final user in users.listSync().whereType<Directory>()) {
      yield Directory(
        p.join(user.path, 'AppData', 'Roaming', 'BetterSabersManager', 'Temp'),
      );
    }
  }

  /// Helper calls finish in seconds, but a stuck wineserver or umu.lock
  /// contention can hang forever. Maxima bounds its own helper calls the
  /// same way; the manager itself is exempt because the user decides when
  /// to close it.
  static const _helperTimeout = Duration(minutes: 10);

  static Future<void> _umu(
    String verb,
    List<String> args, {
    Duration? timeout,
  }) async {
    final call = Process.run(
      _umuBin,
      args,
      environment: {
        'WINEPREFIX': prefixDir,
        'GAMEID': 'umu-0',
        'PROTON_VERB': verb,
        'PROTONPATH': _protonDir,
        'STORE': 'ea',
        'PROTON_EAC_RUNTIME': _eacDir,
        'WINEDEBUG': 'fixme-all',
        'LD_PRELOAD': '',
        'LANG': 'en_US.UTF-8',
        'LC_ALL': 'en_US.UTF-8',
        // Same reason Maxima sets this on every umu call it makes: without it
        // umu revalidates its Steam Linux Runtime each time, which is what
        // stalls on slow links. User-overridable, as it is there.
        'UMU_RUNTIME_UPDATE':
            Platform.environment['UMU_RUNTIME_UPDATE'] ?? '0',
      },
    );
    final result = timeout == null
        ? await call
        : await call.timeout(
            timeout,
            onTimeout: () => throw BsmHostException(
              'Wine did not answer within ${timeout.inMinutes} minutes. '
              'A previous session may still be running.',
            ),
          );

    if (result.exitCode != 0) {
      _logger.warning('umu $verb exited ${result.exitCode}: ${result.stderr}');
    }
  }

  /// The manager writes its output under the prefix user's AppData. Proton
  /// calls that user `steamuser`, a plain Wine prefix uses the login name.
  static List<File> _packsFor(String packName) {
    final found = <File>[];
    for (final temp in _packDirectories()) {
      if (!temp.existsSync()) continue;
      found.addAll(
        temp.listSync().whereType<File>().where(
              (f) =>
                  p.basename(f.path).startsWith('$packName.') &&
                  f.path.endsWith('.bsm.fbmod'),
            ),
      );
    }
    return found;
  }

  /// Whether the mod carries a WebP screenshot.
  ///
  /// The manager builds a preview for every mod it loads, and WPF decodes
  /// images through the Windows Imaging Component. Wine's version has no WebP
  /// decoder, so such a screenshot fails with WINCODEC_ERR_COMPONENTNOTFOUND
  /// and takes the entire load down with it, not just that one mod. Leaving
  /// those out costs their sabers but keeps the manager usable.
  ///
  /// Screenshots sit in the mod header, so reading the first stretch is
  /// enough; mod files themselves run into the hundreds of megabytes.
  static bool _hasWebpScreenshot(String modPath) {
    final file = File(modPath);
    if (!file.existsSync()) return false;

    RandomAccessFile? handle;
    try {
      handle = file.openSync();
      final head = handle.readSync(2 * 1024 * 1024);
      for (var i = 0; i + 12 <= head.length; i++) {
        if (head[i] != 0x52 || // 'R'
            head[i + 1] != 0x49 || // 'I'
            head[i + 2] != 0x46 || // 'F'
            head[i + 3] != 0x46) {
          continue;
        }
        if (head[i + 8] == 0x57 && // 'W'
            head[i + 9] == 0x45 && // 'E'
            head[i + 10] == 0x42 && // 'B'
            head[i + 11] == 0x50) {
          return true;
        }
      }
      return false;
    } on Object catch (e) {
      _logger.warning('Could not inspect $modPath: $e');
      return false;
    } finally {
      handle?.closeSync();
    }
  }

  static int _indexOfSequence(Uint8List haystack, Uint8List needle) {
    final limit = haystack.length - needle.length;
    outer:
    for (var i = 0; i <= limit; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }

  /// Finds the embedded apphost: the last PE image before [limit] that is an
  /// exe rather than a DLL. Offset 0 is the plugin DLL itself.
  static int _lastEmbeddedExeBefore(Uint8List bytes, int limit) {
    for (var i = limit; i > 0; i--) {
      if (bytes[i] != 0x4d || bytes[i + 1] != 0x5a) continue; // 'MZ'
      if (i + 0x40 >= bytes.length) continue;
      final view = ByteData.sublistView(bytes, i);
      final peOffset = view.getUint32(0x3c, Endian.little);
      if (peOffset <= 0 || i + peOffset + 24 >= bytes.length) continue;
      if (view.getUint32(peOffset, Endian.little) != 0x00004550) continue; // 'PE\0\0'
      final characteristics = view.getUint16(peOffset + 22, Endian.little);
      if (characteristics & 0x2000 != 0) continue; // DLL, not the apphost
      return i;
    }
    return -1;
  }
}

class BsmHostException implements Exception {
  const BsmHostException(this.message);
  final String message;

  @override
  String toString() => message;
}

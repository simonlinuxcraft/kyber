// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 simonlinuxcraft
//
// Linux self-update service.
//
// On Windows the launcher self-updates by downloading and running
// `KyberLauncherInstaller.exe`. macOS skips self-update entirely.
// On Linux we mirror the kyber-bf2-linux reference architecture:
//
//   1. Ask the server (gRPC `Launcher/DownloadUrl`) for the latest
//      `kyber-installer-linux64` tarball URL.
//   2. Download the tarball into a per-user staging area.
//   3. Extract it into ~/.local/share/kyber/launcher/versions/<X.Y.Z>/.
//   4. Write update_pending.json with the staged version + attempt
//      counter.
//   5. The kyber-bf2 wrapper / update_apply.sh sidecar swaps the
//      `current` symlink and re-execs the new launcher on next start.
//
// The `flock` we hold via dart:io's File.lock() makes sure two
// launcher instances can't trample each other's staging dirs. The
// sidecar takes its own flock during the symlink swap.
//
// This service is invoked from the existing UpdateDialog on Linux
// instead of running a Windows installer.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:kyber/kyber.dart';
import 'package:kyber_launcher/features/kyber/services/kyber_grpc_service.dart';
import 'package:kyber_launcher/injection_container.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:rhttp/rhttp.dart';

/// Module identifier the server uses for the Linux launcher tarball.
/// Must match whatever the API publishes; Windows uses
/// `kyber-installer-win64`.
const String linuxLauncherModule = 'kyber-installer-linux64';

class LinuxUpdateInfo {
  LinuxUpdateInfo({
    required this.version,
    required this.channel,
  });

  final String version;
  final String channel;
}

class LinuxSelfUpdateService {
  static final _logger = Logger('linux_self_update');

  // ---------------------------------------------------------------------------
  // Filesystem layout (mirrors update_apply.sh + kyber-bf2 expectations).
  // ---------------------------------------------------------------------------

  static String get _home {
    final h = Platform.environment['HOME'];
    if (h == null || h.isEmpty) {
      throw StateError('\$HOME is not set; cannot self-update on Linux');
    }
    return h;
  }

  static String get _kyberDir => p.join(_home, '.local', 'share', 'kyber', 'launcher');
  static String get _versionsDir => p.join(_kyberDir, 'versions');
  static String get _stagingRoot => p.join(_kyberDir, 'staging');
  static String get pendingFile => p.join(_kyberDir, 'update_pending.json');
  static String get _lockFile => p.join(_kyberDir, '.update.lock');
  static String get currentLink => p.join(_kyberDir, 'current');

  // ---------------------------------------------------------------------------
  // Public API.
  // ---------------------------------------------------------------------------

  /// True if a previous run staged an update that hasn't been applied yet.
  /// The kyber-bf2 wrapper runs update_apply.sh on next start; here we
  /// just expose the marker so the UI can show a "restart to update"
  /// state.
  static bool hasPendingUpdate() {
    if (!Platform.isLinux) return false;
    return File(pendingFile).existsSync();
  }

  /// Reads the staged version off the pending marker, if any.
  static String? pendingVersion() {
    final f = File(pendingFile);
    if (!f.existsSync()) return null;
    try {
      final data = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      return data['version'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Drops the pending marker (e.g. user clicked "ignore" on the
  /// "restart to apply" dialog).
  static Future<void> clearPendingUpdate() async {
    final f = File(pendingFile);
    if (f.existsSync()) {
      await f.delete();
    }
    final attempts = File(p.join(_kyberDir, 'update_pending.attempts'));
    if (attempts.existsSync()) {
      await attempts.delete();
    }
  }

  /// Hand control to update_apply.sh. The sidecar applies the swap and
  /// execs the new launcher; we exit so the file descriptors on the
  /// old binary are released before the symlink flip.
  static Future<Never> applyPendingAndRestart() async {
    final sidecar = _sidecarPath();
    if (sidecar == null || !File(sidecar).existsSync()) {
      throw StateError('update_apply.sh not found in bundle');
    }
    _logger.info('Spawning update sidecar: $sidecar');
    await Process.start(
      sidecar,
      const [],
      mode: ProcessStartMode.detached,
    );
    // 50ms was too tight — Process.start returns once the fork has
    // happened, but the child still needs to install its own signal
    // handlers before we close stdin/stdout and exit. 250ms is a
    // safer envelope and still imperceptible to the user.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    exit(0);
  }

  /// Download + verify + extract the latest Linux launcher tarball.
  /// Calls [onProgress] with bytes (received, total) during download.
  ///
  /// Throws on any failure; a partial staging dir is wiped before the
  /// next attempt, the marker is only written on success.
  static Future<LinuxUpdateInfo> downloadAndStage({
    required String version,
    required String channel,
    void Function(int received, int total)? onProgress,
  }) async {
    if (!Platform.isLinux) {
      throw StateError('LinuxSelfUpdateService called on non-Linux platform');
    }

    await Directory(_kyberDir).create(recursive: true);
    await Directory(_versionsDir).create(recursive: true);
    await Directory(_stagingRoot).create(recursive: true);

    final lockFile = File(_lockFile);
    if (!lockFile.existsSync()) {
      lockFile.createSync();
    }

    // We acquire the flock twice: once briefly to claim the right to
    // self-update (and grab the download URL), then release for the
    // duration of the (possibly multi-minute) tarball download, then
    // re-acquire for the extract+marker steps. Holding the lock
    // across the download would block other launcher instances for
    // minutes, which is the wrong trade-off when the download itself
    // doesn't touch shared state.
    Future<RandomAccessFile> claim() async {
      final h = await lockFile.open(mode: FileMode.write);
      try {
        await h.lock(FileLock.blockingExclusive);
        return h;
      } catch (e) {
        await h.close();
        throw StateError(
          'Another self-update is already running (lock held): $e',
        );
      }
    }

    final downloadResp = await () async {
      final h = await claim();
      try {
        return await sl.get<KyberGRPCService>().launcherClient.downloadUrl(
              ServiceVersionDownloadUrlRequest(
                id: linuxLauncherModule,
                version: version,
                channel: channel,
              ),
            );
      } finally {
        try {
          await h.unlock();
        } catch (_) {}
        await h.close();
      }
    }();

    final url = downloadResp.url;
    _logger.info(
      'Self-update tarball URL for $linuxLauncherModule@$version '
      '($channel): $url',
    );

    // Use a stable filename inside the staging root so a crashed
    // download is overwritten cleanly on the next try.
    final tarballPath = p.join(_stagingRoot, 'launcher-$version.tar.gz');
    await _downloadTo(url, tarballPath, onProgress: onProgress);

    // Re-acquire the lock for the stage-and-mark operations.
    final lockHandle = await claim();
    try {

      // Optional SHA-256 verification: server may publish a hash in
      // ServiceVersionDownloadUrl; absent => skip and warn.
      final expectedHash = _extractFieldOrNull(downloadResp, 'sha256');
      if (expectedHash != null && expectedHash.isNotEmpty) {
        final got = await _sha256OfFile(tarballPath);
        if (got.toLowerCase() != expectedHash.toLowerCase()) {
          await File(tarballPath).delete();
          throw StateError(
            'SHA-256 mismatch on launcher tarball '
            '(expected $expectedHash, got $got)',
          );
        }
        _logger.info('Tarball SHA-256 verified.');
      } else {
        _logger.warning(
          'Server did not provide a SHA-256 for $version; skipping '
          'integrity check (Phase 1 — Phase 2 will require signed '
          'manifests).',
        );
      }

      // Atomic-ish extract: write into a temp dir, then rename. This
      // keeps a half-extracted tree from looking installed.
      final destDir = Directory(p.join(_versionsDir, version));
      final tmpDir =
          Directory(p.join(_stagingRoot, 'extract-$version-${_randomTag()}'));
      if (tmpDir.existsSync()) {
        await tmpDir.delete(recursive: true);
      }
      await tmpDir.create(recursive: true);

      _logger.info('Extracting $tarballPath to ${tmpDir.path}');
      await _extractTarGz(tarballPath, tmpDir.path);

      if (destDir.existsSync()) {
        await destDir.delete(recursive: true);
      }
      await tmpDir.rename(destDir.path);

      // The tarball is published with a top-level versioned dir
      // sometimes ("kyber_launcher-X.Y.Z/...") and sometimes flat. If
      // we don't see kyber_launcher right under destDir, hoist a
      // single-child subdir up. Best-effort.
      await _flattenSinglePathChild(destDir);

      // Sanity: the kyber_launcher binary must exist after extract.
      final binary = File(p.join(destDir.path, 'kyber_launcher'));
      if (!binary.existsSync()) {
        throw StateError(
          'Extracted tarball does not contain a kyber_launcher binary at '
          '${binary.path}; refusing to mark update as ready.',
        );
      }
      // tar's permission bits should already be honoured by archive_io,
      // but the chmod is cheap insurance.
      await Process.run('chmod', ['+x', binary.path]);

      // Write the marker last. The sidecar consumes this on next
      // start; if we die between extract and marker-write the only
      // damage is a wasted versions/<X.Y.Z>/ dir, no broken state.
      final marker = File(pendingFile);
      await marker.writeAsString(jsonEncode({
        'version': version,
        'channel': channel,
        'attempts': 0,
        'staged_at': DateTime.now().toUtc().toIso8601String(),
      }));

      // Drop the tarball; nothing to clean up later.
      await File(tarballPath).delete();

      _logger.info('Staged $version into ${destDir.path}');
      return LinuxUpdateInfo(version: version, channel: channel);
    } finally {
      try {
        await lockHandle.unlock();
      } catch (_) {}
      await lockHandle.close();
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers.
  // ---------------------------------------------------------------------------

  static String? _sidecarPath() {
    final exeDir = p.dirname(Platform.resolvedExecutable);
    final candidates = [
      p.join(exeDir, 'cli', 'bin', 'update_apply.sh'),
      p.join(exeDir, '..', 'cli', 'bin', 'update_apply.sh'),
      '/usr/share/kyber-bf2/payload/launcher/cli/bin/update_apply.sh',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  static String? _extractFieldOrNull(
    ServiceVersionDownloadUrl resp,
    String field,
  ) {
    // ServiceVersionDownloadUrl is a generated proto; we don't bind to
    // its structure tightly because the schema may grow optional
    // hash fields over time. Fall back to introspecting toJson() so a
    // missing field never crashes the update.
    try {
      final json = resp.toProto3Json() as Map<String, dynamic>?;
      final v = json?[field];
      if (v is String) return v;
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _downloadTo(
    String url,
    String destPath, {
    void Function(int, int)? onProgress,
  }) async {
    final file = File(destPath);
    if (file.existsSync()) {
      await file.delete();
    }
    await file.create(recursive: true);
    final raf = file.openSync(mode: FileMode.write);
    try {
      final stream = await Rhttp.getStream(url, onReceiveProgress: onProgress);
      await stream.body.forEach(raf.writeFromSync);
    } finally {
      raf.closeSync();
    }
  }

  static Future<String> _sha256OfFile(String path) async {
    final input = File(path).openRead();
    final digest = await sha256.bind(input).first;
    return digest.toString();
  }

  static Future<void> _extractTarGz(
    String tarballPath,
    String targetDir,
  ) async {
    final bytes = await File(tarballPath).readAsBytes();
    final gzipDecoded = GZipDecoder().decodeBytes(bytes);
    final archive = TarDecoder().decodeBytes(gzipDecoded);
    await extractArchiveToDisk(archive, targetDir);
  }

  static Future<void> _flattenSinglePathChild(Directory dir) async {
    final entries = await dir.list().toList();
    if (entries.length != 1) return;
    final only = entries.first;
    if (only is! Directory) return;
    if (File(p.join(dir.path, 'kyber_launcher')).existsSync()) return;
    final temp = Directory(
      p.join(dir.parent.path, '${p.basename(dir.path)}.flatten-tmp'),
    );
    if (temp.existsSync()) await temp.delete(recursive: true);
    await only.rename(temp.path);
    await dir.delete(recursive: true);
    await temp.rename(dir.path);
  }

  static String _randomTag() {
    final now = DateTime.now().microsecondsSinceEpoch;
    return now.toRadixString(36);
  }
}

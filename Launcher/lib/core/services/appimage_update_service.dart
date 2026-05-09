// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 simonlinuxcraft
//
// AppImage container self-update.
//
// Sits next to LinuxSelfUpdateService but operates one layer up:
//   * LinuxSelfUpdateService updates the in-app module bundle (mods,
//     maxima-bootstrap, CLI helpers) by symlink-flipping
//     ~/.local/share/kyber/launcher/current.
//   * AppImageUpdateService updates the AppImage *file itself* by
//     downloading a new image and exec'ing into it. Only runs when the
//     launcher was started from an AppImage ($APPIMAGE env is set).
//
// Endpoint is configured via KYBER_UPDATE_URL. When the env is empty
// or the launcher is not inside an AppImage the service is a no-op,
// so it's safe to call from app startup unconditionally.
//
// Manifest format (JSON):
//   {
//     "version":      "0.1.0-beta.2",
//     "download_url": "https://.../KyberLinuxPort-x86_64.AppImage",
//     "sha256":       "abc123..."
//   }

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:version/version.dart';

class AppImageUpdateManifest {
  AppImageUpdateManifest({
    required this.version,
    required this.downloadUrl,
    required this.sha256,
  });

  factory AppImageUpdateManifest.fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    final downloadUrl = json['download_url'];
    final hash = json['sha256'];
    if (version is! String || version.isEmpty) {
      throw const FormatException('manifest missing string field "version"');
    }
    if (downloadUrl is! String || downloadUrl.isEmpty) {
      throw const FormatException(
        'manifest missing string field "download_url"',
      );
    }
    if (hash is! String || hash.isEmpty) {
      throw const FormatException('manifest missing string field "sha256"');
    }
    return AppImageUpdateManifest(
      version: version,
      downloadUrl: downloadUrl,
      sha256: hash,
    );
  }

  final String version;
  final String downloadUrl;
  final String sha256;
}

class AppImageUpdateService {
  AppImageUpdateService();

  static final _logger = Logger('appimage_update');

  /// Path of the running AppImage on disk, or null if the launcher was
  /// not started from an AppImage (env var is set by AppImage runtime).
  /// If the user invoked the AppImage through a symlink (a common
  /// pattern when the file lives in `~/Applications/` and is reached
  /// via `~/.local/bin/kyber`), the symlink is resolved here so the
  /// rename in [_downloadAndReplace] hits the real file.
  static String? get appImagePath {
    final raw = Platform.environment['APPIMAGE'];
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      return File(raw).resolveSymbolicLinksSync();
    } on FileSystemException {
      return raw;
    }
  }

  /// Update endpoint URL configured via env. Empty / unset disables the
  /// container self-update entirely.
  static String get updateUrl =>
      Platform.environment['KYBER_UPDATE_URL']?.trim() ?? '';

  /// True when the launcher is inside an AppImage *and* an update
  /// endpoint is configured. Use this to gate UI elements.
  static bool get isEligible => appImagePath != null && updateUrl.isNotEmpty;

  /// Performs the full update cycle. Always returns normally; failures
  /// are logged. If a newer AppImage is downloaded successfully, the
  /// running process is replaced via `Process.start(detached) +
  /// exit(0)` and this future never returns.
  Future<void> checkAndUpdate() async {
    final appImage = appImagePath;
    if (appImage == null) {
      _logger.fine('Not running from AppImage; skipping container update.');
      return;
    }
    final url = updateUrl;
    if (url.isEmpty) {
      _logger.info(
        'KYBER_UPDATE_URL not set; AppImage container self-update disabled.',
      );
      return;
    }

    try {
      final manifest = await _fetchManifest(url);
      final current = await _currentVersion();
      // Semantic-version compare via the existing `version` package
      // (already a launcher dep). Plain string equality is wrong: the
      // running build's `info.version` and the manifest's `version`
      // can disagree on pre-release tag formatting (`0.1.0-beta.2` vs
      // `0.1.0-beta2`) or build metadata (`+1`) without representing
      // a real version difference, and equality would also miss the
      // intent to never downgrade.
      final Version currentSemver;
      final Version manifestSemver;
      try {
        currentSemver = Version.parse(current);
      } on FormatException catch (e) {
        _logger.warning(
          'Cannot parse running launcher version "$current" as semver; '
          'skipping AppImage update.',
          e,
        );
        return;
      }
      try {
        manifestSemver = Version.parse(manifest.version);
      } on FormatException catch (e) {
        _logger.warning(
          'Manifest advertised version "${manifest.version}" is not '
          'valid semver; refusing to install.',
          e,
        );
        return;
      }
      if (manifestSemver <= currentSemver) {
        _logger.info(
          'AppImage is up to date (running $currentSemver, '
          'manifest $manifestSemver).',
        );
        return;
      }
      _logger.info(
        'AppImage update available: $currentSemver -> $manifestSemver',
      );
      await _downloadAndReplace(manifest, appImage);
    } on Object catch (e, st) {
      _logger.warning(
        'AppImage container update check failed; continuing without update.',
        e,
        st,
      );
    }
  }

  Future<AppImageUpdateManifest> _fetchManifest(String url) async {
    final response = await Dio().get<dynamic>(
      url,
      options: Options(
        responseType: ResponseType.json,
        receiveTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(seconds: 30),
      ),
    );
    final data = response.data;
    if (data is! Map<String, dynamic>) {
      throw FormatException(
        'manifest endpoint did not return a JSON object: '
        '${data.runtimeType}',
      );
    }
    return AppImageUpdateManifest.fromJson(data);
  }

  Future<String> _currentVersion() async {
    // PackageInfo.buildNumber is undefined on Linux/AppImage builds
    // (Flutter-tools fills it on Android/iOS, leaves it as the empty
    // string or a build timestamp on desktop). Joining it with `+`
    // turns a perfectly valid `0.1.0` into the bogus build-metadata
    // form `0.1.0+` or `0.1.0+0`. We only consume the bare version.
    final info = await PackageInfo.fromPlatform();
    return info.version;
  }

  Future<void> _downloadAndReplace(
    AppImageUpdateManifest manifest,
    String currentPath,
  ) async {
    final tag = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final tmpPath = '$currentPath.new.$tag';
    final tmpFile = File(tmpPath);
    if (tmpFile.existsSync()) {
      await tmpFile.delete();
    }

    _logger.info(
      'Downloading new AppImage from ${manifest.downloadUrl} -> $tmpPath',
    );
    try {
      await Dio().download(
        manifest.downloadUrl,
        tmpPath,
        options: Options(
          receiveTimeout: const Duration(minutes: 30),
        ),
      );

      final actual = await _sha256OfFile(tmpPath);
      if (actual.toLowerCase() != manifest.sha256.toLowerCase()) {
        throw StateError(
          'SHA-256 mismatch on AppImage download '
          '(expected ${manifest.sha256}, got $actual)',
        );
      }

      final chmodResult = await Process.run('chmod', ['0755', tmpPath]);
      if (chmodResult.exitCode != 0) {
        throw StateError(
          'chmod 0755 on staged AppImage failed: ${chmodResult.stderr}',
        );
      }

      // Atomic replace — both files live in the same directory and on
      // the same filesystem since we derived tmpPath from currentPath.
      await tmpFile.rename(currentPath);

      // chmod sets the inode mode bit, but if currentPath lives on a
      // mount that was set up with `noexec` (some users keep
      // ~/Applications/ on a data partition mounted as ntfs/exfat)
      // then execve() fails with EACCES and the user is left with no
      // running launcher. Verify execute permission resolves before
      // exiting the running process.
      final canExec = await Process.run('test', ['-x', currentPath]);
      if (canExec.exitCode != 0) {
        throw StateError(
          'Replaced AppImage at $currentPath is not executable '
          '(noexec mount?); aborting restart so the running launcher '
          'survives.',
        );
      }

      _logger.info(
        'AppImage replaced; restarting into ${manifest.version}.',
      );
      // Forward original CLI arguments so things like `--server` or
      // protocol-handler invocations (`kyber qrc://...`) survive the
      // restart.
      await Process.start(
        currentPath,
        Platform.executableArguments,
        mode: ProcessStartMode.detached,
      );
      // Give the child a moment to fork before we tear down stdio.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      exit(0);
    } on Object {
      if (tmpFile.existsSync()) {
        try {
          await tmpFile.delete();
        } on FileSystemException catch (e) {
          _logger.warning(
            'Failed to remove partial AppImage download $tmpPath: $e',
          );
        }
      }
      rethrow;
    }
  }

  Future<String> _sha256OfFile(String path) async {
    final input = File(path).openRead();
    final digest = await sha256.bind(input).first;
    return digest.toString();
  }
}

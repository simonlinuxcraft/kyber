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
import 'package:kyber_launcher/features/settings/screens/settings_list.dart';
import 'package:logging/logging.dart';
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
  /// staging and rename hit the real file.
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

  /// True in a context where an external package manager owns the binary
  /// (AUR, distro package). Reuses the same marker the self-install hook
  /// honors. The AUR build runs the *extracted* binary (no AppImage runtime,
  /// no AppRun), so it already misses appImagePath/updateUrl; this is the
  /// belt-and-suspenders so self-update stays off even if a packaged build
  /// ever runs the .AppImage directly. pacman/yay handle updates there.
  static bool get isPackagedContext =>
      Platform.environment['KYBER_NO_AUTO_INSTALL']?.trim().isNotEmpty ?? false;

  /// True when the launcher is inside an AppImage, an update endpoint is
  /// configured, and we're not in a package-manager context. Use this to
  /// gate the update check and any UI elements.
  static bool get isEligible =>
      appImagePath != null && updateUrl.isNotEmpty && !isPackagedContext;

  /// Running launcher version, the Linux-port scheme (e.g.
  /// `0.1.0-beta.6.4.9`). NOT PackageInfo/pubspec, which carries the
  /// untouched upstream Kyber version (`2.0.0-beta9`) and would make every
  /// manifest look like a downgrade so the updater never fires.
  String get currentVersion => kLinuxPortVersion;

  /// Checks the configured endpoint and returns the manifest only when it
  /// advertises a newer version than the running launcher. Returns null
  /// when not eligible, on any network/parse error, or when already
  /// current. Never throws, never downloads, never restarts.
  Future<AppImageUpdateManifest?> checkForUpdate() async {
    if (appImagePath == null) {
      _logger.fine('Not running from AppImage; skipping container update.');
      return null;
    }
    if (isPackagedContext) {
      _logger.info(
        'Package-manager context (KYBER_NO_AUTO_INSTALL set); the AppImage '
        'self-update is disabled, the package manager handles updates.',
      );
      return null;
    }
    final url = updateUrl;
    if (url.isEmpty) {
      _logger.info(
        'KYBER_UPDATE_URL not set; AppImage container self-update disabled.',
      );
      return null;
    }

    try {
      final manifest = await _fetchManifest(url);
      // Semantic-version compare via the existing `version` package.
      // Plain string equality is wrong: pre-release tag formatting or
      // build metadata can differ without a real version change, and
      // equality would also miss the intent to never downgrade.
      final Version currentSemver;
      final Version manifestSemver;
      try {
        currentSemver = Version.parse(currentVersion);
      } on FormatException catch (e) {
        _logger.warning(
          'Cannot parse running launcher version "$currentVersion" as '
          'semver; skipping AppImage update.',
          e,
        );
        return null;
      }
      try {
        manifestSemver = Version.parse(manifest.version);
      } on FormatException catch (e) {
        _logger.warning(
          'Manifest advertised version "${manifest.version}" is not '
          'valid semver; refusing to install.',
          e,
        );
        return null;
      }
      if (manifestSemver <= currentSemver) {
        _logger.info(
          'AppImage is up to date (running $currentSemver, '
          'manifest $manifestSemver).',
        );
        return null;
      }
      _logger.info(
        'AppImage update available: $currentSemver -> $manifestSemver',
      );
      return manifest;
    } on Object catch (e, st) {
      _logger.warning(
        'AppImage container update check failed; continuing without update.',
        e,
        st,
      );
      return null;
    }
  }

  Future<AppImageUpdateManifest> _fetchManifest(String url) async {
    // connectTimeout caps a dead/unreachable endpoint so the startup chain that
    // awaits this check cannot hang on it (the check runs before the onboarding
    // dialogs). receive/send guard a slow-but-alive endpoint.
    final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 10)));
    final response = await dio.get<dynamic>(
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

  /// Downloads the manifest's AppImage to a staging file next to the
  /// running image, verifies its SHA-256, and makes it executable.
  /// Returns the staged path; the running image is NOT touched yet, so a
  /// failure here leaves the user on the current launcher. The caller
  /// applies it later via [applyAndRestart] (or [discardStaged] to cancel).
  /// Throws on any failure after cleaning up its partial download.
  Future<String> downloadUpdate(
    AppImageUpdateManifest manifest, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final currentPath = appImagePath;
    if (currentPath == null) {
      throw StateError('not running from an AppImage; cannot stage update');
    }
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
        onReceiveProgress: onProgress,
        cancelToken: cancelToken,
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
      return tmpPath;
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

  /// Atomically replaces the running AppImage with the staged file and
  /// restarts into it. Never returns on success (the process exits). On a
  /// noexec target the staged file is removed and a StateError is thrown so
  /// the running launcher survives.
  Future<void> applyAndRestart(String stagedPath) async {
    final currentPath = appImagePath;
    if (currentPath == null) {
      throw StateError('not running from an AppImage; cannot apply update');
    }
    final staged = File(stagedPath);
    try {
      // Atomic replace: staged file and target share a directory and
      // filesystem since the staged path was derived from currentPath.
      await staged.rename(currentPath);

      // chmod set the inode bit, but a noexec mount (some users keep
      // ~/Applications/ on an ntfs/exfat data partition) still fails
      // execve() with EACCES. Verify before tearing down the running one.
      final canExec = await Process.run('test', ['-x', currentPath]);
      if (canExec.exitCode != 0) {
        throw StateError(
          'Replaced AppImage at $currentPath is not executable '
          '(noexec mount?); aborting restart so the running launcher '
          'survives.',
        );
      }

      _logger.info('AppImage replaced; restarting.');
      // Forward original CLI arguments so things like `--server` or
      // protocol-handler invocations (`kyber qrc://...`) survive.
      await Process.start(
        currentPath,
        Platform.executableArguments,
        mode: ProcessStartMode.detached,
      );
      // Give the child a moment to fork before we tear down stdio.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      exit(0);
    } on Object {
      if (staged.existsSync()) {
        try {
          await staged.delete();
        } on FileSystemException catch (e) {
          _logger.warning('Failed to remove staged AppImage $stagedPath: $e');
        }
      }
      rethrow;
    }
  }

  /// Removes a staged update file (user chose "Later"). Best-effort.
  Future<void> discardStaged(String stagedPath) async {
    final f = File(stagedPath);
    if (f.existsSync()) {
      try {
        await f.delete();
      } on FileSystemException catch (e) {
        _logger.warning('Failed to discard staged AppImage $stagedPath: $e');
      }
    }
  }

  Future<String> _sha256OfFile(String path) async {
    final input = File(path).openRead();
    final digest = await sha256.bind(input).first;
    return digest.toString();
  }
}

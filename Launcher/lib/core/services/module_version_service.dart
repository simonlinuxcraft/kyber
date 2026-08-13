import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:kyber/kyber.dart';
import 'package:kyber_collection/kyber_collection.dart';
import 'package:kyber_launcher/core/services/linux_self_update_service.dart';
import 'package:kyber_launcher/core/services/notification_service.dart';
import 'package:kyber_launcher/features/kyber/services/kyber_grpc_service.dart';
import 'package:kyber_launcher/gen/rust/api/archive.dart';
import 'package:kyber_launcher/injection_container.dart';
import 'package:kyber_launcher/main.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rhttp/rhttp.dart';
import 'package:win32/win32.dart';
import 'package:win32_registry/win32_registry.dart';

const _launcherInstallerKey =
    r'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\KyberLauncher_is1';

enum VersionModule {
  //launcher,
  module,
  installer,
}

extension VersionModuleExtension on VersionModule {
  Future<String?> getCurrentVersion() async {
    switch (this) {
      case VersionModule.module:
        final x = File(join(FileHelper.getModuleDirectory().path, 'VERSION'));

        if (!x.existsSync()) {
          return null;
        }

        return x.readAsStringSync();
      case VersionModule.installer:
        final info = await PackageInfo.fromPlatform();

        return '${info.version}+${info.buildNumber}';
    }
  }

  Future<String> getDownloadDir() async {
    switch (this) {
      case VersionModule.installer:
        final tmpDir = await getTemporaryDirectory();

        return join(
          tmpDir.path,
          'kyber_launcher_${DateTime.now().millisecondsSinceEpoch}',
        );
      case VersionModule.module:
        return FileHelper.getModuleDirectory().path;
    }
  }

  Future<void> setReleaseChannel(String channel) async {
    await box.put('${name}_release_channel', channel);
  }

  String get releaseChannel {
    return box.get('${name}_release_channel') as String? ?? 'stable';
  }

  List<String> get requiredFiles {
    switch (this) {
      case VersionModule.installer:
        return [];
      case VersionModule.module:
        final modulePath = FileHelper.getModuleDirectory().path;
        return [
          '$modulePath/vivoxsdk.dll',
          '$modulePath/VanillaBundleAggregation.kb',
          '$modulePath/Kyber.dll',
        ];
    }
  }

  String get name {
    switch (this) {
      case VersionModule.installer:
        return 'kyber-installer-win64';
      case VersionModule.module:
        return 'kyber-module';
    }
  }
}

class ModuleVersionService {
  final _logger = Logger('version_service');

  bool isStandalone() {
    // TODO: find a fix for this
    return false;
    RegistryKey? key;
    try {
      key = Registry.openPath(
        RegistryHive.localMachine,
        path: _launcherInstallerKey,
      );

      final installationPath = key.getStringValue('InstallLocation');
      if (installationPath == null) {
        return true;
      }

      return normalize(installationPath) !=
          dirname(Platform.resolvedExecutable);
    } on WindowsException catch (_) {
      return true;
    } catch (e) {
      _logger.warning('Failed to check if standalone: $e');
      return false;
    } finally {
      key?.close();
    }
  }

  Future<bool> checkChannel({
    required VersionModule module,
    required String channel,
  }) async {
    if (module == VersionModule.installer) {
      final version = await getLatestLauncherVersion(channel);
      return version != null;
    }

    final rq = ServiceVersionsRequest(id: module.name, channel: channel);
    final versions = await sl.get<KyberGRPCService>().launcherClient.versions(
      rq,
    );
    return versions.versions.isNotEmpty &&
        versions.versions.firstWhereOrNull((x) => x.isLatest) != null;
  }

  Future<bool> updateAvailable({
    required VersionModule module,
    String? channel,
    KyberGRPCService? service,
  }) async {
    if (Platform.isMacOS && module == VersionModule.installer) {
      return false;
    }

    // On Linux the launcher self-update goes through
    // LinuxSelfUpdateService (download tarball, extract into
    // ~/.local/share/kyber/launcher/versions/<X.Y.Z>/, sidecar swaps
    // the `current` symlink on next start). We delegate the version
    // check too, so we can ask the server for the linux-specific
    // module instead of the win64 one.
    if (Platform.isLinux && module == VersionModule.installer) {
      return _isLinuxLauncherUpdateAvailable(
        channel: channel,
        service: service,
      );
    }

    if ((kDebugMode || kProfileMode) && module == VersionModule.installer) {
      return false;
    }

    channel ??= module.releaseChannel;
    final rq = ServiceVersionsRequest(id: module.name, channel: channel);
    final versions = await (service ?? sl.get<KyberGRPCService>())
        .launcherClient
        .versions(rq);

    final currentVersion = await module.getCurrentVersion();
    final latestVersion = versions.versions.firstWhereOrNull((x) => x.isLatest);
    if (currentVersion == null) {
      _logger.info('No version found for ${module.name}.');
      return true;
    }

    if (latestVersion == null) {
      _logger.info(
        'No latest version found for ${module.name}. Switching to stable.',
      );
      await module.setReleaseChannel('stable');
      return true;
    }

    late bool updateAvailable;
    if (module == VersionModule.installer) {
      final latestVersion = await getLatestLauncherVersion();
      if (latestVersion == 'DISCONTINUED' || latestVersion == null) {
        _logger.info(
          'The branch ${VersionModule.installer.releaseChannel} has been discontinued. Switching to main.',
        );
        await VersionModule.installer.setReleaseChannel('stable');
        return true;
      }

      updateAvailable = latestVersion != currentVersion;
    } else {
      updateAvailable = latestVersion.version != currentVersion;
    }

    if (updateAvailable) {
      _logger.info(
        'New version available for ${module.name}: ${latestVersion.version}',
      );
      return true;
    }

    if (module.requiredFiles.any((x) => !File(x).existsSync())) {
      _logger.info('Required files missing for ${module.name}.');
      return true;
    }

    return false;
  }

  Future<void> updateVersion({
    required VersionModule module,
    String? channel,
    String? token,
    KyberGRPCService? service,
    void Function(int, int)? onProgress,
  }) async {
    if (!kReleaseMode && module == VersionModule.installer) {
      return;
    }

    // Linux launcher self-update: completely separate code path.
    // module.name is hardcoded to `kyber-installer-win64`, so we'd
    // otherwise be querying the Windows artifact stream. Hand off to
    // LinuxSelfUpdateService which knows the linux module id and
    // handles tarball download + staging + marker writing.
    if (Platform.isLinux && module == VersionModule.installer) {
      await _runLinuxLauncherUpdate(
        channel: channel,
        service: service,
        onProgress: onProgress,
      );
      return;
    }

    final x = service ?? sl.get<KyberGRPCService>();
    channel ??= module.releaseChannel;
    final versions = await x.launcherClient.versions(
      ServiceVersionsRequest(id: module.name, channel: channel),
    );
    final latestVersion = versions.versions
        .where((x) => x.isLatest)
        .firstOrNull;

    if (latestVersion == null) {
      NotificationService.showNotification(
        message:
            'No latest version found for "${module.name}" on channel "$channel".',
      );
      _logger.warning('No latest version found for ${module.name}');
      return;
    }

    if (module == VersionModule.installer && isStandalone()) {
      NotificationService.showNotification(
        message:
            'The standalone version of the Launcher cannot be automatically updated.',
      );
      _logger.warning(
        'The standalone version of the Launcher cannot be automatically updated.',
      );
      return;
    }

    _logger.info('Updating ${module.name} to version ${latestVersion.version}');

    final download = await x.launcherClient.downloadUrl(
      ServiceVersionDownloadUrlRequest(
        id: module.name,
        version: latestVersion.version,
        channel: channel,
      ),
    );
    final filename = basename(download.url).split('?').first;
    final downloadDir = await module.getDownloadDir();
    final downloadPath = join(downloadDir, filename);

    _logger.fine('Downloading to $downloadPath');

    final file = File(downloadPath);
    if (file.existsSync()) {
      file.deleteSync();
    }

    file.createSync(recursive: true);

    final raf = file.openSync(mode: FileMode.write);

    try {
      final stream = await Rhttp.getStream(
        download.url,
        onReceiveProgress: onProgress,
      );

      await stream.body.forEach(raf.writeFromSync);
    } finally {
      raf.closeSync();
    }

    if (!Directory(downloadDir).existsSync()) {
      Directory(downloadDir).createSync();
    }

    _logger.fine('Extracting artifact...');

    await extract(filePath: downloadPath, targetDir: downloadDir);

    File(downloadPath).deleteSync();

    await box.put(module.name, latestVersion.version);
    if (module == VersionModule.installer) {
      await Process.run('sc', ['stop', 'MaximaBackgroundService']);
      await Process.run(join(downloadDir, 'KyberLauncherInstaller.exe'), [
        '/VERYSILENT',
        '/FORCECLOSEAPPLICATIONS',
        '/RESTARTAPPLICATIONS',
      ], runInShell: true);

      exit(0);
    } else {
      if (module == VersionModule.module) {
        File(
          join(FileHelper.getModuleDirectory().path, 'VERSION'),
        ).writeAsStringSync(latestVersion.version);
      }
    }

    _logger.info('Updated ${module.name} to version ${latestVersion.version}');
  }

  Future<String?> getLatestLauncherVersion([String? releaseChannel]) async {
    try {
      final rawVersion = await Rhttp.getText(
        'https://s3.kyber.gg/artifacts/launcher-versions/${releaseChannel ?? VersionModule.installer.releaseChannel}/latest-version',
      );

      return rawVersion.body.split(Platform.lineTerminator).first;
    } catch (e) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Linux launcher self-update.
  // ---------------------------------------------------------------------------

  /// Server publishes the Linux launcher tarball under a separate
  /// module id (the Windows installer keeps `kyber-installer-win64`).
  String get _linuxModuleId => linuxLauncherModule;

  /// Resolve "the version currently installed on this machine".
  ///
  /// Three sources, in order of authority:
  ///   1. `current` symlink target → versions/<X.Y.Z> (truth after any
  ///      successful self-update).
  ///   2. PackageInfo.version (the build-time string baked into
  ///      flutter_assets/version.json - same source the Reference
  ///      build relies on).
  ///   3. null if neither is readable (then the dialog falls through
  ///      to "no update available" so we don't trigger spurious
  ///      prompts).
  Future<String?> _linuxInstalledVersion() async {
    final link = Link(LinuxSelfUpdateService.currentLink);
    if (link.existsSync()) {
      try {
        final target = await link.target();
        final base = target.split('/').last; // versions/<X.Y.Z> => X.Y.Z
        if (base.isNotEmpty) return base;
      } catch (_) {
        // Fall through to PackageInfo.
      }
    }

    try {
      final info = await PackageInfo.fromPlatform();
      if (info.version.isNotEmpty) return info.version;
    } catch (_) {}
    return null;
  }

  Future<bool> _isLinuxLauncherUpdateAvailable({
    String? channel,
    KyberGRPCService? service,
  }) async {
    // If we already staged an update last run, the user just needs to
    // restart - re-show the dialog so they can confirm the apply.
    if (LinuxSelfUpdateService.hasPendingUpdate()) {
      return true;
    }

    channel ??= VersionModule.installer.releaseChannel;
    final x = service ?? sl.get<KyberGRPCService>();
    try {
      final versions = await x.launcherClient.versions(
        ServiceVersionsRequest(id: _linuxModuleId, channel: channel),
      );
      final latest =
          versions.versions.firstWhereOrNull((v) => v.isLatest);
      if (latest == null) {
        _logger.info(
          'No latest $_linuxModuleId published on channel $channel; '
          'skipping Linux self-update prompt.',
        );
        return false;
      }
      final current = await _linuxInstalledVersion();
      if (current == null) {
        // No reliable local version - don't prompt, the user would
        // not have any way to make the comparison work.
        return false;
      }
      return latest.version != current;
    } catch (e, s) {
      _logger.warning(
        'Linux launcher version check failed; treating as no-update',
        e,
        s,
      );
      return false;
    }
  }

  Future<void> _runLinuxLauncherUpdate({
    String? channel,
    KyberGRPCService? service,
    void Function(int, int)? onProgress,
  }) async {
    // If the apply step is already pending from a previous run, just
    // hand off to the sidecar and exit instead of re-downloading.
    if (LinuxSelfUpdateService.hasPendingUpdate()) {
      _logger.info(
        'Pending update detected; restarting via update_apply.sh',
      );
      await LinuxSelfUpdateService.applyPendingAndRestart();
      return;
    }

    channel ??= VersionModule.installer.releaseChannel;
    final x = service ?? sl.get<KyberGRPCService>();
    final versions = await x.launcherClient.versions(
      ServiceVersionsRequest(id: _linuxModuleId, channel: channel),
    );
    final latest = versions.versions.firstWhereOrNull((v) => v.isLatest);
    if (latest == null) {
      NotificationService.showNotification(
        message: 'Server hat keine Linux-Version auf Channel "$channel" '
            'veröffentlicht.',
      );
      return;
    }

    await LinuxSelfUpdateService.downloadAndStage(
      version: latest.version,
      channel: channel,
      onProgress: onProgress,
    );
    // Note: we deliberately do NOT persist latest.version here. The
    // `current` symlink (flipped by update_apply.sh on success) is
    // the single source of truth. Storing the new version eagerly
    // would lie about what's actually installed if the apply step
    // fails or the user kills the launcher mid-restart.

    NotificationService.showNotification(
      message: 'Update auf ${latest.version} bereit. Launcher startet neu '
          'um die neue Version zu aktivieren.',
    );
    _logger.info('Staged Linux launcher ${latest.version}; restarting');

    // Apply & restart immediately. update_apply.sh swaps the symlink
    // and execs into the new build. Single call - applyPendingAndRestart
    // exit(0)s the current process, anything after this line is dead
    // code.
    await LinuxSelfUpdateService.applyPendingAndRestart();
  }
}

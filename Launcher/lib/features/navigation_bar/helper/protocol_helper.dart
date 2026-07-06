import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:kyber/kyber.dart';
import 'package:kyber_collection/kyber_collection.dart';
import 'package:kyber_launcher/core/config/strings.dart';
import 'package:kyber_launcher/core/routing/app_router.dart';
import 'package:kyber_launcher/core/services/app_settings.dart';
import 'package:kyber_launcher/core/services/notification_service.dart';
import 'package:kyber_launcher/features/download_manager/models/download_link_type.dart' as dl;
import 'package:kyber_launcher/features/download_manager/models/download_request.dart';
import 'package:kyber_launcher/features/download_manager/providers/download_manager_cubit.dart';
import 'package:kyber_launcher/features/download_manager/services/download_orchestrator.dart';
import 'package:kyber_launcher/features/maxima/helper/maxima_helper.dart';
import 'package:kyber_launcher/features/maxima/providers/maxima_cubit.dart';
import 'package:kyber_launcher/features/mods/helper/mod_helper.dart';
import 'package:kyber_launcher/features/mods/services/mod_service.dart';
import 'package:kyber_launcher/features/nexusmods/services/nexusmods_service.dart';
import 'package:kyber_launcher/features/server_browser/providers/server_browser_cubit.dart';
import 'package:kyber_launcher/injection_container.dart';
import 'package:kyber_launcher/main.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart';
import 'package:protocol_handler/protocol_handler.dart';
import 'package:window_manager/window_manager.dart';

class ProtocolHelper {
  static const List<String> _supportedUrls = [
    'join_server',
    'start_game',
    'deep_link',
    'discord_linked',
  ];

  static Future<void> register() async {
    await protocolHandler.register(Strings.protocolName);
    await protocolHandler.register('nxm');

    // The protocol_handler plugin has no Linux backend (only
    // Android/iOS/macOS/Windows), so register('nxm') above is a no-op
    // there. We register the scheme ourselves via xdg-mime + a small
    // bash bridge that drops the URL into a per-user response file.
    if (Platform.isLinux) {
      await _registerLinuxNxmHandler();
    }
  }

  static Future<void> initialize() async {
    // On Linux the bash bridge can't send IPC to the running launcher
    // (the protocol_handler plugin has no Linux MethodChannel). Start
    // the inotify watcher first so it's running before any nxm:// click
    // could arrive.
    if (Platform.isLinux) {
      await _startLinuxNxmWatcher();
    }

    // protocolHandler.getInitialUrl() throws MissingPluginException on
    // Linux because there's no Linux backend — guard the call so the
    // exception doesn't tear down the rest of initialize().
    String? initialUrl;
    try {
      initialUrl = await protocolHandler.getInitialUrl();
    } catch (e) {
      if (!Platform.isLinux) {
        Logger.root.warning('protocolHandler.getInitialUrl failed: $e');
      }
    }
    if (Preferences.general.setup && initialUrl != null) {
      await ProtocolHelper.handleCall(initialUrl);
    }
  }

  static Future<void> handleCall(String url) async {
    try {
      if (!Preferences.general.setup) {
        Logger.root.severe('Received protocol url but setup is not complete');
        return;
      }

      if (await windowManager.isMinimized()) {
        await windowManager.restore();
      }

      final file = File(url);
      if (file.existsSync()) {
        const allowedExtensions = ['.kbcollection', '.kbrotation', '.kbplugin'];
        final fileExtension = extension(file.path);
        if (!allowedExtensions.contains(fileExtension)) {
          Logger.root.severe(
            'error: unsupported file extension: $fileExtension',
          );
          return;
        }

        if (fileExtension == '.kbrotation' || fileExtension == '.kbplugin') {
          Logger.root.info('Not implemented. (fileExtension: $fileExtension)');
          return;
        }

        final collection = await ModCollection.readCollection(file);

        Logger.root.info(
          'Received mod collection ${collection.localId} from protocol url',
        );

        NotificationService.showNotification(
          message:
              'Importing Collections without mod data is currently not supported',
        );

        await router.pushNamed(
          'collection_import',
          queryParameters: {'path': file.path},
        );

        return;
      }

      final uri = Uri.parse(url);
      if (uri.scheme == 'nxm') {
        Logger.root.info('Received nxm protocol url: $url');

        final gameId = uri.host;
        if (gameId != 'starwarsbattlefront22017') {
          Logger.root.severe(
            'error: unsupported game id: $gameId... trying to redirect to vortex',
          );

          if (!Platform.isWindows) {
            return NotificationService.error(
              message: 'Vortex is only supported on Windows',
            );
          }

          final vortexExe = File(
            r'C:\Program Files\Black Tree Gaming Ltd\Vortex\Vortex.exe',
          );
          if (!vortexExe.existsSync()) {
            return NotificationService.error(
              message: 'Vortex is not installed or the path is incorrect',
            );
          }

          await Process.start(vortexExe.path, [
            '-i',
            url,
          ], mode: ProcessStartMode.detached);
          return;
        }

        final modId = uri.pathSegments[1];
        final fileId = uri.pathSegments.last;
        final service = sl.get<NexusModsService>();
        if (service.apiToken == null) {
          NotificationService.showNotification(
            message: 'You need to login to download mods',
            severity: InfoBarSeverity.error,
          );
          Logger.root.severe('error: api token is null');
          return;
        }

        try {
          final mod = await service.nexusBridge.apiClient.getMod(
            gameId,
            int.parse(modId),
          );

          final request = DownloadRequest(
            link: url,
            displayName: mod.name,
            linkType: dl.DownloadLinkType.nxm,
          );
          Logger.root.info('Adding download to queue: ${mod.name}');
          await sl.get<DownloadOrchestrator>().enqueueDownload(request);
        } catch (exception, stackTrace) {
          Logger.root.severe(
            'error: failed to get download link',
            exception,
            stackTrace,
          );
          return;
        }

        return;
      }

      if (uri.queryParameters.containsKey('type')) {
        if (uri.queryParameters['type'] == 'deep_link') {
          await router.push(
            '/${uri.host}${uri.path}?${uri.queryParameters.entries.map((e) => '${e.key}=${e.value}').join('&')}',
            extra: uri.queryParameters,
          );
          return;
        }
      }

      if (!_supportedUrls.contains(uri.host)) {
        Logger.root.severe('error: unsupported protocol: $uri');
        return;
      }

      switch (uri.host) {
        case 'discord_linked':
          await navigatorKey.currentContext?.read<MaximaCubit>().verifyToken();
          return;
        case 'join_server':
          if (uri.queryParameters.isEmpty ||
              uri.queryParameters['server_id'] == null) {
            Logger.root.severe('Received protocol url but server_id is null');
            return;
          }

          var forceJoin = false;
          if (uri.queryParameters['force_join'] != null) {
            forceJoin = uri.queryParameters['force_join'] == '1';
          }

          await _joinServer(
            uri.queryParameters['server_id']!,
            forceJoin: forceJoin,
          );
        case 'start_game':
          if (!navigatorKey.currentContext!
              .read<MaximaCubit>()
              .state
              .loggedIn) {
            NotificationService.showNotification(
              message: 'You need to login to start a game',
              severity: InfoBarSeverity.error,
            );

            Logger.root.severe('Received protocol url but token is null');
            return;
          }

          final query = uri.queryParameters;
          ModCollectionMetaData? collection;
          if (query.containsKey('collection')) {
            collection = collectionBox.values
                .where((e) => e.title == query['collection'])
                .firstOrNull;
            if (collection == null) {
              NotificationService.showNotification(
                message: 'Collection "${query['collection']}" not found',
                severity: InfoBarSeverity.error,
              );
            }
          }

          await sl.isReady<ModService>();
          await MaximaHelper.requestGameLaunch(
            navigatorKey.currentContext!,
            modCollection: collection,
            showCollectionSelector: false,
          );
      }

      Logger.root.info('Received protocol url: $url');
    } catch (e, s) {
      Logger.root.severe('error: failed to handle protocol url', e, s);
    }
  }

  static Future<void> _joinServer(
    String serverId, {
    bool forceJoin = false,
  }) async {
    if (serverId.isEmpty) {
      Logger.root.severe('Received protocol url but server_id is null');
      return;
    }

    router.goNamed('home');
    final server = await sl
        .get<KyberGRPCService>()
        .serverBrowserClient
        .getServer(ServerRequest(id: serverId));
    if (!server.hasName()) {
      Logger.root.severe('error: server not found');
      return;
    }

    final context = shellNavigatorKey.currentContext;
    if (context == null) {
      Logger.root.severe('error: shellNavigator context is null');
      return;
    }

    if (context.mounted) {
      context.read<ServerBrowserCubit>().selectServer(server);

      if (forceJoin) {
        context.read<ServerBrowserCubit>().joinServer();
        return;
      }

      final mods = server.mods;
      if (mods.every((m) => ModHelper.isInstalled(m.name, m.version))) {
        context.read<ServerBrowserCubit>().joinServer();
      } else {
        context.read<ServerBrowserCubit>().selectServer(server);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Linux NXM bridge.
  //
  // The protocol_handler plugin only ships Android / iOS / macOS / Windows
  // backends, so on Linux we set the system mime handler ourselves and
  // bridge the bash-handler -> running-launcher gap with a watched file
  // under $XDG_RUNTIME_DIR.
  // ---------------------------------------------------------------------------

  static const _linuxDesktopFileBaseName = 'kyber-bf2-nxm.desktop';
  static StreamSubscription<FileSystemEvent>? _linuxNxmWatcher;

  /// Completer that the download service installs when it explicitly
  /// awaits a `nxm://` URL (free-user flow on Linux). When set, the
  /// inotify watcher completes this completer instead of running the
  /// usual handleCall() / enqueueDownload pipeline — so the same NXM
  /// response isn't processed twice (once as the awaited token, once
  /// as a freshly enqueued download).
  static Completer<String>? _pendingNxmCompleter;

  /// Register a one-shot listener that captures the next nxm:// URL the
  /// inotify bridge receives instead of routing it through handleCall().
  /// Caller owns the returned completer: await `.future` yourself, and
  /// pass this SAME completer back to [cancelPendingNxmWait] when done,
  /// so a caller cleaning up after being superseded can't wipe out a
  /// newer, still-active wait.
  static Completer<String> awaitNextNxmUrl() {
    _pendingNxmCompleter?.completeError(
      StateError('superseded by newer nxm await'),
    );
    final c = Completer<String>();
    _pendingNxmCompleter = c;
    return c;
  }

  static void cancelPendingNxmWait(Completer<String> completer) {
    if (identical(_pendingNxmCompleter, completer)) {
      _pendingNxmCompleter = null;
    }
  }

  static String _linuxRuntimeDir() {
    final fromEnv = Platform.environment['XDG_RUNTIME_DIR'];
    if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
    return '/run/user/${Platform.environment['UID'] ?? '1000'}';
  }

  static String _linuxNxmResponsePath() =>
      join(_linuxRuntimeDir(), 'kyber', 'nxm-response');

  static Future<void> _registerLinuxNxmHandler() async {
    try {
      final exeDir = dirname(Platform.resolvedExecutable);
      final handlerScript = join(exeDir, 'cli', 'bin', 'nxm_handler.sh');
      if (!File(handlerScript).existsSync()) {
        Logger.root.warning(
          'nxm_handler.sh missing at $handlerScript — nxm:// links from '
          'the browser will not reach the launcher. Free-user mod '
          'downloads will be unavailable.',
        );
        return;
      }

      final home = Platform.environment['HOME'];
      if (home == null) {
        Logger.root.warning('\$HOME unset; cannot register nxm handler');
        return;
      }
      final appsDir =
          Directory(join(home, '.local', 'share', 'applications'));
      await appsDir.create(recursive: true);

      final desktopFile = File(join(appsDir.path, _linuxDesktopFileBaseName));
      await desktopFile.writeAsString('''
[Desktop Entry]
Type=Application
Name=Kyber NXM Handler
Comment=Receives nxm:// links from Nexus Mods and forwards them to the Kyber launcher.
Exec=$handlerScript %u
NoDisplay=true
Terminal=false
StartupNotify=false
MimeType=x-scheme-handler/nxm;
''');

      // Best-effort registration. Each step is independent — if one
      // tool is missing on a slim distro we still want the others to
      // run.
      for (final step in <List<String>>[
        ['update-desktop-database', appsDir.path],
        [
          'xdg-mime',
          'default',
          _linuxDesktopFileBaseName,
          'x-scheme-handler/nxm',
        ],
      ]) {
        try {
          final r = await Process.run(step.first, step.skip(1).toList());
          if (r.exitCode != 0) {
            Logger.root.warning(
              '${step.join(' ')} exited with ${r.exitCode}: ${r.stderr}',
            );
          }
        } catch (e) {
          Logger.root.warning('${step.first} failed: $e');
        }
      }

      Logger.root.info(
        'Linux nxm:// handler registered: ${desktopFile.path} -> '
        '$handlerScript',
      );
    } catch (e, s) {
      Logger.root.severe('Failed to register Linux nxm handler', e, s);
    }
  }

  static Future<void> _startLinuxNxmWatcher() async {
    try {
      final responsePath = _linuxNxmResponsePath();
      final responseFile = File(responsePath);
      await Directory(dirname(responsePath)).create(recursive: true);

      // Drain any URL that landed before the launcher started.
      if (responseFile.existsSync()) {
        final initial = (await responseFile.readAsString()).trim();
        if (initial.isNotEmpty) {
          await responseFile.writeAsString('');
          unawaited(_dispatchLinuxNxmUrl(initial));
        }
      } else {
        await responseFile.writeAsString('');
      }

      // The bash handler renames a temp file over the target, so the
      // inode changes on each delivery. Watching the file itself would
      // detach after the first event — watch the parent directory and
      // filter by path instead.
      final dir = Directory(dirname(responsePath));
      await _linuxNxmWatcher?.cancel();
      _linuxNxmWatcher = dir.watch().listen(
        (event) async {
          if (event.path != responsePath) return;
          if (event.type != FileSystemEvent.create &&
              event.type != FileSystemEvent.modify) {
            return;
          }
          try {
            if (!responseFile.existsSync()) return;
            final url = (await responseFile.readAsString()).trim();
            if (url.isEmpty) return;
            await responseFile.writeAsString('');
            await _dispatchLinuxNxmUrl(url);
          } catch (e, s) {
            Logger.root.severe('nxm watcher dispatch failed', e, s);
          }
        },
        onError: (Object e) =>
            Logger.root.warning('nxm watcher error: $e'),
      );

      Logger.root.info('Linux nxm watcher active on $responsePath');
    } catch (e, s) {
      Logger.root.severe('Failed to start Linux nxm watcher', e, s);
    }
  }

  static Future<void> _dispatchLinuxNxmUrl(String url) async {
    Logger.root.info('Received nxm:// via Linux bridge: $url');
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {
      // window may not be ready yet during early init — handleCall()
      // below will still process the URL.
    }

    // If somebody is awaiting an nxm:// response (free-user mod
    // download flow), feed it there instead of enqueuing a fresh
    // download. Otherwise fall through to the normal handler so a
    // browser-initiated nxm:// click still works when the launcher is
    // sitting idle.
    final pending = _pendingNxmCompleter;
    if (pending != null && !pending.isCompleted) {
      _pendingNxmCompleter = null;
      pending.complete(url);
      return;
    }

    await handleCall(url);
  }
}

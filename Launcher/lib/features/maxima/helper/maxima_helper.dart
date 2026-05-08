import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';
import 'package:kyber/kyber.dart';
import 'package:kyber_collection/kyber_collection.dart';
import 'package:kyber_launcher/core/services/app_settings.dart';
import 'package:kyber_launcher/core/services/module_version_service.dart';
import 'package:kyber_launcher/core/services/notification_service.dart';
import 'package:kyber_launcher/core/services/windows_env.dart';
import 'package:kyber_launcher/features/frosty/dialogs/frosty_pack_selector_dialog.dart';
import 'package:kyber_launcher/features/game/dialogs/mod_limit_dialog.dart';
import 'package:kyber_launcher/features/kyber/services/kyber_grpc_service.dart';
import 'package:kyber_launcher/features/maxima/dialogs/maxima_start_game_dialog.dart';
import 'package:kyber_launcher/features/maxima/extensions/server_mod.dart';
import 'package:kyber_launcher/features/maxima/models/maxima_game_instance.dart';
import 'package:kyber_launcher/features/maxima/services/maxima_instance_service.dart';
import 'package:kyber_launcher/features/mod_collections/providers/mod_collection_cubit.dart';
import 'package:kyber_launcher/features/mods/services/mod_service.dart';
import 'package:kyber_launcher/gen/rust/api/maxima.dart' as maxima;
import 'package:kyber_launcher/injection_container.dart';
import 'package:kyber_launcher/shared/ui/dialog/kyber_dialog.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

class MaximaHelper {
  static final Logger _logger = Logger('maxima_helper');

  static Future<void> requestGameLaunch(
    BuildContext context, {
    ModCollectionMetaData? modCollection,
    bool showCollectionSelector = true,
    InitializeRequest? initializeRequest,
  }) async {
    if (modCollection == null && showCollectionSelector) {
      modCollection = await showKyberDialog<ModCollectionMetaData?>(
        context: context,
        builder: (_) => const FrostyPackSelectorDialog(),
      );

      if (modCollection == null) {
        _logger.fine('User cancelled selection. Aborting requestGameLaunch');
        return;
      }
    }

    initializeRequest ??= InitializeRequest();
    if (modCollection != null) {
      if (modCollection.getLocalMods().contains(null)) {
        NotificationService.error(
          message:
              'Some mods in your collection are missing. Please check your mod collection.',
        );
        return;
      }

      final modPaths = modCollection.getModPaths();
      final preloadedMods = await sl
          .get<KyberGRPCService>()
          .launcherClient
          .getPreloadedMods(Empty());
      final modLimit = Preferences.general.enabledPreloadMods
          ? 1739 - preloadedMods.mods.length
          : 1739;
      if (modPaths.length >= modLimit) {
        _logger.warning('Mod limit reached: ${modPaths.length}');

        if (context.mounted) {
          await showKyberDialog(
            context: context,
            builder: (_) => const ModLimitDialog(),
          );
        }

        return;
      }

      initializeRequest.modData = ModData(
        basePath: ModService.getBasePath(),
        modPaths: modPaths,
        mods: modCollection
            .getLocalMods(onlyGameplay: true)
            .whereType<FrostyMod>()
            .map(ServerMod().fromFrostyMod)
            .toList(),
        explodedMods: modCollection
            .getLocalMods(
              onlyGameplay: true,
              expandCollections: true,
            )
            .whereType<FrostyMod>()
            .where((e) => !e.isCollection)
            .map(ServerMod().fromFrostyMod)
            .toList(),
      );
    }

    if (!context.mounted) {
      _logger.warning('Context is not mounted, aborting requestGameLaunch');
      return;
    }

    // final gameConfig = await ConfigParser.parseConfig();
    // if (gameConfig.enableDx12) {
    //   _logger.warning('Launching game with DirectX 12 enabled');
    //   NotificationService.warning(
    //     message:
    //     'DirectX 12 is enabled. This can cause instability and issues with Kyber.',
    //   );
    // }

    if (initializeRequest.startupCommands.isNotEmpty) {
      _logger.fine(
        'Starting game with startup commands: ${initializeRequest.startupCommands}',
      );
    }

    if (!context.mounted) {
      _logger.warning('Context is not mounted, aborting requestGameLaunch');
      return;
    }

    await showKyberDialog(
      context: context,
      builder: (_) => MaximaStartGameDialog(
        initializeRequest: initializeRequest,
        mods: modCollection?.getLocalMods().whereType<FrostyMod>().toList(),
      ),
    );
  }

  static Future<MaximaGameInstance> startGame({
    InitializeRequest? initializeRequest,
    String? gameSlug,
    String? gamePath,
    String? gameDataPath,
    List<FrostyMod>? mods,
  }) async {
    initializeRequest ??= InitializeRequest();

    // Root cause identified (2026-05-07): the language-entitlement error on
    // the FFI path was caused by MAXIMA_WINE_COMMAND not being set, so
    // bootstrap fell back to raw umu-run without the umu-wrapper.sh locale
    // fix. linux_setup.rs now sets MAXIMA_WINE_COMMAND (and all STEAM env
    // vars) from init_app() before any tokio thread starts. FFI path is
    // therefore used on all platforms.

    final path = Platform.environment['PATH'];

    if (path == null) {
      throw Exception('PATH environment variable is not set');
    }

    final grpcDebug = Preferences.debug.grpcDebugLogs;
    final moduleDebug = Preferences.debug.moduleDebugLogs;
    // On Linux use : as path separator; on Windows ; (umu-wrapper.sh also
    // converts ; → : for Wine subprocesses, but the Linux process PATH itself
    // must stay colon-separated so other child processes can find executables).
    final pathSep = Platform.isLinux ? ':' : ';';
    final newPath = '$path$pathSep${FileHelper.getModuleDirectory().path}';
    final interfacePort = await KyberNetworkHelper.findAvailablePort();
    final kToken = await sl.get<KyberGRPCService>().getAuthToken(
      await maxima.getAuthToken(),
    );
    ProcessEnv.set('KYBER_API_TOKEN', kToken);
    ProcessEnv.set(
      'KYBER_MODULE_VERSION',
      (await VersionModule.module.getCurrentVersion())!,
    );
    ProcessEnv.set('KYBER_INTERFACE_PORT', interfacePort.toString());
    ProcessEnv.set(
      'KYBER_HTTP_HOSTNAME',
      sl.get<KyberGRPCService>().httpHostname,
    );
    ProcessEnv.set('PATH', newPath);
    ProcessEnv.set('KYBER_API_HOSTNAME', sl.get<KyberGRPCService>().host);

    if (grpcDebug) {
      ProcessEnv.set('GRPC_TRACE', 'all');
      ProcessEnv.set('GRPC_VERBOSITY', 'debug');
    } else {
      ProcessEnv.delete('GRPC_TRACE');
      ProcessEnv.delete('GRPC_VERBOSITY');
    }

    if (moduleDebug) {
      ProcessEnv.set('KYBER_LOG_LEVEL', 'debug');
    } else {
      ProcessEnv.delete('KYBER_LOG_LEVEL');
    }

    final gameClient = ClientGRPCService('127.0.0.1', interfacePort);
    final gamePID = await maxima.startGame(
      gameSlug: gameSlug ?? 'star-wars-battlefront-2',
      gamePathOverride: gamePath,
    );
    _logger.info('Started game with PID: $gamePID');

    if (sl.isRegistered<MaximaGameInstance>()) {
      _logger.warning(
        'ClientGRPCService was already registered, unregistering...',
      );

      try {
        Process.killPid(sl.get<MaximaGameInstance>().pid);
      } catch (_) {}

      sl.unregister<MaximaGameInstance>();
    }

    final instance = MaximaGameInstance(
      pid: gamePID,
      clientService: gameClient,
      isDedicated: false,
      mods: mods ?? [],
    );

    // MAXIMA-LINUX-PORT-MOD: Convert ModData.basePath from native Linux path
    // to Wine Z:\… form. Kyber.dll runs inside the Wine prefix and resolves
    // mod files via the Win32 API, so an absolute /home/... path passed
    // through gRPC's Initialize() response would fail to open and crash
    // BF2 during mod-bundle loading. Mirrors CLI's _toWinePath in
    // start_game.dart so the FFI launch path matches the CLI behaviour.
    if (Platform.isLinux &&
        initializeRequest.hasModData() &&
        initializeRequest.modData.basePath.isNotEmpty) {
      final orig = initializeRequest.modData.basePath;
      // Already a Wine drive-letter path? leave it alone.
      if (!(orig.length >= 2 && orig[1] == ':')) {
        final normalised = orig.replaceAll('/', r'\');
        initializeRequest.modData.basePath = 'Z:' +
            (normalised.startsWith(r'\') ? normalised : '\\$normalised');
        _logger.info(
          'Converted ModData.basePath: $orig → '
          '${initializeRequest.modData.basePath}',
        );
      }
    }

    try {
      sl.get<KyberGRPCServer>().setInitializeRequest(initializeRequest);
      await maxima
          .lsxGetEventStream(pid: gamePID, isStartup: true)
          .firstWhere((e) => e == 'RequestLicense');
      await maxima.injectKyber(
        pid: gamePID,
        path: p.join(FileHelper.getModuleDirectory().path, 'Kyber.dll'),
      );
    } catch (e) {
      if (e is AnyhowException) {
        _logger.severe('Failed to inject Kyber into game: ${e.message}');
      }
      rethrow;
    }

    sl.registerSingleton<MaximaGameInstance>(instance);
    sl.get<MaximaInstanceService>().addInstance(instance);

    return instance;
  }

  // On Linux the FFI launch path produces a language-entitlement error whose
  // root cause is unknown. Delegating to kyber_cli runs the identical Maxima
  // code in a fresh subprocess with an environment we fully control — this
  // avoids any German locale state inherited from the Flutter process.
  static Future<MaximaGameInstance> _startGameViaCli({
    required InitializeRequest initializeRequest,
    String? gamePath,
    List<FrostyMod>? mods,
  }) async {
    final bundleDir = p.dirname(Platform.resolvedExecutable);
    final cliDir = p.join(bundleDir, 'cli');
    final kyberCliPath = p.join(cliDir, 'kyber_cli');
    final wrapperPath = p.join(cliDir, 'umu-wrapper.sh');
    final libDir = p.join(bundleDir, 'lib');
    final moduleDir = FileHelper.getModuleDirectory().path;

    final tmpFile = File(
      p.join(Directory.systemTemp.path, 'kyber_init_${DateTime.now().millisecondsSinceEpoch}.json'),
    );
    await tmpFile.writeAsString(jsonEncode(initializeRequest.toProto3Json()));

    final interfacePort = await KyberNetworkHelper.findAvailablePort();
    final kyberService = sl.get<KyberGRPCService>();
    final kToken = await kyberService.getAuthToken(await maxima.getAuthToken());
    final moduleVersion = (await VersionModule.module.getCurrentVersion()) ?? '';

    final existingLd = Platform.environment['LD_LIBRARY_PATH'] ?? '';
    final ldLibraryPath = [cliDir, libDir, if (existingLd.isNotEmpty) existingLd].join(':');
    final existingPath = Platform.environment['PATH'] ?? '';

    final env = <String, String>{
      ...Platform.environment,
      'MAXIMA_WINE_COMMAND': wrapperPath,
      'LD_LIBRARY_PATH': ldLibraryPath,
      'KYBER_INTERFACE_PORT': interfacePort.toString(),
      'KYBER_API_TOKEN': kToken,
      'KYBER_API_HOSTNAME': kyberService.host,
      'KYBER_HTTP_HOSTNAME': kyberService.httpHostname,
      'KYBER_MODULE_VERSION': moduleVersion,
      // Suppress Kyber.dll's debug console window on Linux — beta builds
      // call AllocConsole() unless KYBER_HIDE_CONSOLE is set, which on
      // Windows GUI launches is set by the production launcher but not
      // wired up on the Linux side. Logs continue to be written to the
      // kyber.log file regardless (see Kyber/Module/Source/Core/Program.cpp).
      'KYBER_HIDE_CONSOLE': '1',
      // Use ; separator so umu-wrapper.sh's PATH//;/: fix works for the module dir
      'PATH': '$moduleDir;$existingPath',
    };

    final args = [
      'start_game',
      '--init-request-file', tmpFile.path,
      '--skip-updates',
      '--module-path', moduleDir,
    ];
    if (gamePath != null) args.addAll(['--game-path', gamePath]);

    _logger.info('Delegating game launch to kyber_cli (Linux CLI path)...');
    final process = await Process.start(kyberCliPath, args, environment: env);

    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _logger.warning('[kyber_cli] $line'));

    int? gamePid;
    final completer = Completer<int>();

    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) {
        _logger.info('[kyber_cli] $line');
        final pidMatch = RegExp(r'PID:\s*(\d+)').firstMatch(line);
        if (pidMatch != null) {
          gamePid = int.tryParse(pidMatch.group(1)!);
        }
        if (line.contains('Kyber started') && gamePid != null && !completer.isCompleted) {
          completer.complete(gamePid!);
        }
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.completeError(Exception('kyber_cli exited before game started'));
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
    );

    try {
      final pid = await completer.future.timeout(const Duration(seconds: 180));
      try { tmpFile.deleteSync(); } catch (_) {}

      final instance = MaximaGameInstance(
        pid: pid,
        clientService: ClientGRPCService('127.0.0.1', interfacePort),
        isDedicated: false,
        mods: mods ?? [],
      );

      if (sl.isRegistered<MaximaGameInstance>()) {
        try { Process.killPid(sl.get<MaximaGameInstance>().pid); } catch (_) {}
        sl.unregister<MaximaGameInstance>();
      }

      sl.registerSingleton<MaximaGameInstance>(instance);
      sl.get<MaximaInstanceService>().addInstance(instance);

      return instance;
    } catch (e) {
      try { tmpFile.deleteSync(); } catch (_) {}
      rethrow;
    }
  }

}

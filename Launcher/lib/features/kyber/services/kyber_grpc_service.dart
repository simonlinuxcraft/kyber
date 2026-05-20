import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:grpc/grpc.dart';
import 'package:kyber/gen/Proto/kyber_interface.pbgrpc.dart'
    hide CustomLevelDataRequest, CustomLevelDataResponse, InitializeRequest;
import 'package:kyber/kyber.dart' hide Server;
import 'package:kyber_collection/kyber_collection.dart';
import 'package:kyber_launcher/core/core.dart';
import 'package:kyber_launcher/features/kyber/providers/kyber_status_cubit.dart';
import 'package:kyber_launcher/features/maxima/models/maxima_game_instance.dart';
import 'package:kyber_launcher/features/mods/services/level_declaration_service.dart';
import 'package:kyber_launcher/injection_container.dart';
import 'package:logging/logging.dart';

class LauncherService extends LauncherCommonServiceBase {
  @override
  Future<InitializeRequest> initialize(ServiceCall _, Empty __) {
    sl.get<KyberGRPCServer>().signalDllConnected();
    return Future.value(sl.get<KyberGRPCServer>().getInitializeRequest());
  }

  @override
  Future<CustomLevelDataResponse> getCustomLevelData(
    ServiceCall call,
    CustomLevelDataRequest req,
  ) {
    if (!sl.isRegistered<MaximaGameInstance>()) {
      throw Exception(
        'MaximaGameInstance is not registered in the service locator',
      );
    }

    final instance = sl.get<MaximaGameInstance>();
    final levelService = sl.get<LevelDeclarationService>();
    final collection = ModCollectionMetaData(
      localId: '',
      title: '',
      mods: instance.mods.map((e) => e.toCollectionMod()).toList(),
    );
    final map = levelService.getMapByMode(
      map: req.map,
      mode: req.mode,
      collection: collection,
    );
    final mode = levelService.getModeName(
      mode: req.mode,
      collection: collection,
    );

    return Future.value(
      CustomLevelDataResponse(mapName: map?.name, modeName: mode),
    );
  }

  @override
  Future<Empty> onServerJoined(ServiceCall call, Empty request) {
    navigatorKey.currentContext!.read<KyberStatusCubit>()
      ..joined = true
      ..onTick();
    Logger.root.info('Server joined notification received');
    return Future.value(Empty());
  }

  @override
  Future<Empty> onServerLeft(ServiceCall call, Empty request) {
    navigatorKey.currentContext!.read<KyberStatusCubit>()
      ..joined = false
      ..onTick();
    Logger.root.info('Server left notification received');
    return Future.value(Empty());
  }
}

class KyberGRPCServer {
  final _logger = Logger('grpc_server');

  Server? _server;
  InitializeRequest? _initializeRequest;

  Completer<void> _dllConnected = Completer<void>();

  InitializeRequest getInitializeRequest() {
    final request = _initializeRequest;
    if (request == null) {
      throw Exception('Initialize request is not set');
    }

    return _initializeRequest!;
  }

  void setInitializeRequest(InitializeRequest request) {
    _initializeRequest = request;
    _dllConnected = Completer<void>();
  }

  void signalDllConnected() {
    if (!_dllConnected.isCompleted) {
      _dllConnected.complete();
    }
  }

  Future<void> waitForDllConnect({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    // Pin the completer: setInitializeRequest() can swap _dllConnected for a
    // fresh one, and the grace path below must keep waiting on the same one.
    final completer = _dllConnected;
    try {
      await completer.future.timeout(timeout);
    } on TimeoutException {
      // The DLL can connect right as the timeout fires. signalDllConnected()
      // runs from an incoming gRPC call, dispatched a loop tick after the
      // timeout error, so give it a short grace window before reporting a
      // failed handshake.
      if (completer.isCompleted) return;
      await completer.future.timeout(const Duration(seconds: 2));
    }
  }

  Future<void> start() async {
    _logger.info('Starting gRPC server');
    _server = Server.create(
      services: [
        LauncherService(),
      ],
      errorHandler: (error, trace) {
        _logger.severe('An error occurred: $error', error, trace);
      },
    );

    final port = await KyberNetworkHelper.findAvailablePort();
    await _server?.serve(port: port);
    ProcessEnv.set('KYBER_LAUNCHER_PORT', port.toString());

    _logger.info('Server listening on port $port');
  }

  void dispose() {
    _server?.shutdown();
  }
}

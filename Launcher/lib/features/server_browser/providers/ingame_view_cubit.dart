import 'dart:async';
import 'dart:io';

import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:grpc/grpc.dart' hide Server;
import 'package:kyber/kyber.dart';
import 'package:kyber_launcher/core/services/app_settings.dart';
import 'package:kyber_launcher/core/services/notification_service.dart';
import 'package:kyber_launcher/injection_container.dart';
import 'package:logging/logging.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:window_manager/window_manager.dart';

class IngameViewCubit extends Cubit<IngameViewState> {
  IngameViewCubit() : super(const IngameViewState());

  final _logger = Logger('ingame_view_cubit');
  Timer? _keepAliveTimer;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  bool _loadingInFlight = false;

  @override
  Future<void> close() {
    unloadServer();
    return super.close();
  }

  void unloadServer() {
    _logger.info('Unloading server');

    unawaited(_subscription?.cancel());
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;

    emit(const IngameViewState());

    if (isClosed) {
      return;
    }

    // After BF2 exits the launcher window typically remains where the
    // user last saw it (often minimised to the task bar because BF2 ran
    // fullscreen and stole focus). Bring it back to the foreground so
    // the user lands in the launcher, not on the desktop.
    if (Platform.isLinux || Platform.isWindows) {
      unawaited(_refocusLauncherWindow());
    }
  }

  Future<void> _refocusLauncherWindow() async {
    try {
      if (await windowManager.isMinimized()) {
        await windowManager.restore();
      }
      await windowManager.show();
      await windowManager.focus();
    } on Object catch (e, s) {
      _logger.warning('Failed to refocus launcher window after game exit', e, s);
    }
  }

  Future<void> loadServer(Server server) async {
    emit(IngameViewState(id: server.id, server: server));
    await selectServer(serverId: server.id);
  }

  Future<void> selectServer({String? serverId}) async {
    if (state.server == null && serverId == null) {
      return;
    }

    // Guard against duplicate selectServer calls. KyberStatusPlaying can
    // fire multiple times in quick succession (heartbeat, player-count
    // update) which would make _channel.stream.listen() throw "Stream has
    // already been listened to" on the second call and also triggers the
    // "port = 0" / 403 follow-up symptom when two parallel WebSocket
    // connects race the backend.
    if (_loadingInFlight) {
      _logger.warning('selectServer already in flight, skipping duplicate');
      return;
    }
    _loadingInFlight = true;

    try {
      await _subscription?.cancel();
      _subscription = null;
      await _channel?.sink.close();
      _channel = null;
      _keepAliveTimer?.cancel();
      final id = serverId ?? state.id;
      _logger.info('Loading server $id');
      emit(IngameViewState(id: id));
      final service = sl.get<KyberGRPCService>();
      final server = await service.serverBrowserClient.getServer(
        ServerRequest(id: id),
      );
      emit(state.copyWith(id: id, server: server));

      _logger.info('Subscribing to server events');

      _channel = IOWebSocketChannel.connect(
        'wss://api.${Preferences.admin.apiEnv}.kyber.gg/ws/client/${server.id}',
        headers: {
          'Authorization': service.token,
        },
        connectTimeout: const Duration(seconds: 10),
      );

      await _channel?.ready;

      _subscription = _channel?.stream.listen(
        (event) {
          try {
            final data = ServerManagementAPIEvent.fromBuffer(
              event as List<int>,
            );
            if (data.hasPlayers()) {
              _logger.fine('Received players event');
              emit(state.copyWith(players: data.players.players));
            } else if (data.hasConsole()) {
              _logger.fine('Received console event');
              final commands = List<String>.from(state.commands)
                ..add(data.console.message);
              emit(state.copyWith(commands: commands));
            }
          } catch (e, s) {
            _logger.severe('Error parsing event', e, s);
          }
        },
        onDone: () {
          _logger.info('Stream done');
          unloadServer();
        },
        onError: (dynamic e, StackTrace s) {
          NotificationService.showNotification(
            title: 'Server error',
            message: 'An error occurred while communicating with the server',
          );
          _logger.severe('Stream error', e, s);
          unloadServer();
        },
      );

      _keepAliveTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) async => _channel?.sink.add(''),
      );

      await Future<void>.delayed(const Duration(seconds: 3));
    } on WebSocketException catch (e, s) {
      var error = 'Failed to connect to websocket';
      switch (e.httpStatusCode ?? 0) {
        case 401:
          error = 'Failed to connect to websocket: Unauthorized';
        case 404:
          error = 'The specified server was not found';
      }

      _logger.severe('Failed to connect to websocket', e, s);
      NotificationService.error(message: error);
      unloadServer();
    } on GrpcError catch (e, s) {
      _logger.severe('Error loading server:', e, s);
      NotificationService.showNotification(
        title: 'Server error',
        message:
            e.message ??
            'An error occurred while communicating with the server',
        severity: InfoBarSeverity.error,
      );
      unloadServer();
    } on SocketException catch (e, s) {
      _logger.severe('Socket error:', e, s);
      NotificationService.showNotification(
        title: 'Server error',
        message: 'An error occurred while communicating with the server',
        severity: InfoBarSeverity.error,
      );
      unloadServer();
    } catch (e, s) {
      _logger.severe('Error loading server:', e, s);
      NotificationService.showNotification(
        title: 'Server error',
        message: 'An error occurred while communicating with the server',
        severity: InfoBarSeverity.error,
      );
      unloadServer();
    } finally {
      _loadingInFlight = false;
    }
  }
}

class IngameViewState {
  const IngameViewState({
    this.id,
    this.server,
    this.players = const [],
    this.commands = const [],
  });

  final String? id;
  final Server? server;
  final List<ServerPlayer> players;
  final List<String> commands;

  IngameViewState copyWith({
    String? id,
    Server? server,
    List<ServerPlayer>? players,
    List<String>? commands,
  }) {
    return IngameViewState(
      id: id ?? this.id,
      server: server ?? this.server,
      players: players ?? this.players,
      commands: commands ?? this.commands,
    );
  }
}

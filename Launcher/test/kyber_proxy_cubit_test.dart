import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kyber/kyber.dart';
import 'package:kyber_launcher/features/kyber/providers/kyber_proxy_cubit.dart';

void main() {
  test(
    'a proxy that accepts the socket but never answers does not block joins',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      server.listen((request) async {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          sockets.add(await WebSocketTransformer.upgrade(request));
        } else {
          request.response.statusCode = HttpStatus.badRequest;
          await request.response.close();
        }
      });
      addTearDown(() async {
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
      });

      final cubit = KyberProxyCubit();
      addTearDown(cubit.close);
      await cubit.ensureReady();

      await cubit
          .loadProxies(
            initialProxies: [
              ProxyInfo(
                id: 'silent',
                name: 'Silent',
                ip: '127.0.0.1:${server.port}',
              ),
            ],
          )
          .timeout(const Duration(seconds: 30));

      expect(sockets, isNotEmpty);
      expect(cubit.isLoading, isFalse);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

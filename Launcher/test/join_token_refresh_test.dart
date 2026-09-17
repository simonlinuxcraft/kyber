import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';
import 'package:kyber/kyber.dart';
import 'package:kyber_launcher/features/maxima/helper/maxima_helper.dart';

// Once CreateJoinToken starts, the old token may be deleted even if the client
// only sees a transport or backend error. Never launch with an uncertain token.
void main() {
  InitializeRequest joinRequest(String token) => InitializeRequest(
    joinServer: JoinServerRequest(id: 'server-1', joinToken: token),
  );

  test('a fresh token replaces the old one', () async {
    final out = await MaximaHelper.withLiveJoinToken(
      joinRequest('old'),
      () async => 'fresh',
    );

    expect(out!.joinServer.joinToken, 'fresh');
  });

  test('any refresh failure aborts instead of risking a dead token', () async {
    for (final code in [
      StatusCode.resourceExhausted,
      StatusCode.permissionDenied,
      StatusCode.notFound,
      StatusCode.unavailable,
      StatusCode.deadlineExceeded,
      StatusCode.internal,
    ]) {
      await expectLater(
        MaximaHelper.withLiveJoinToken(
          joinRequest('old'),
          () async => throw GrpcError.custom(code, 'refused'),
        ),
        throwsA(isA<JoinTokenRefreshException>()),
        reason: 'code $code must not fall back to a possibly deleted token',
      );
    }
  });

  test('a null refresh result keeps the current token', () async {
    final out = await MaximaHelper.withLiveJoinToken(
      joinRequest('old'),
      () async => null,
    );

    expect(out!.joinServer.joinToken, 'old');
  });

  test('an empty refreshed token aborts', () async {
    await expectLater(
      MaximaHelper.withLiveJoinToken(joinRequest('old'), () async => ''),
      throwsA(isA<JoinTokenRefreshException>()),
    );
  });

  test('a request without joinServer is passed through untouched', () async {
    final req = InitializeRequest();
    expect(await MaximaHelper.withLiveJoinToken(req, () async => 'fresh'), req);
  });
}

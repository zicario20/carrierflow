import 'dart:async';
import 'dart:convert';

import 'package:carrierflow_driver/core/bootstrap/driver_push_registration_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

final class _FakeSession implements DriverPushSession {
  _FakeSession({this.userId, this.accessToken});

  @override
  String? userId;
  @override
  String? accessToken;
}

final class _FakeTransport implements DriverPushHttpTransport {
  final calls = <_Request>[];
  FutureOr<void> Function()? beforeResponse;
  int responseStatus = 200;

  @override
  Future<int> post(
    Uri uri, {
    required Map<String, String> headers,
    required String body,
  }) async {
    calls.add(_Request(uri, headers, body));
    await beforeResponse?.call();
    return responseStatus;
  }
}

final class _Request {
  const _Request(this.uri, this.headers, this.body);

  final Uri uri;
  final Map<String, String> headers;
  final String body;
}

void main() {
  group('authenticated driver push registration gateway', () {
    test('posts only token/platform to the HTTPS server endpoint using the current bearer', () async {
      final session = _FakeSession(
        userId: 'driver-session-a',
        accessToken: 'access-token-a',
      );
      final transport = _FakeTransport();
      final gateway = AuthenticatedDriverPushRegistrationGateway(
        session: session,
        endpoint: Uri.parse('https://admin.carrierflow.test/api/driver/push-device'),
        transport: transport,
      );

      await gateway.registerOwnPushDevice(
        pushToken: 'private-fcm-token-abcdefghijklmnopqrstuvwxyz',
        platform: 'android',
      );

      expect(transport.calls, hasLength(1));
      final request = transport.calls.single;
      expect(request.uri.toString(), 'https://admin.carrierflow.test/api/driver/push-device');
      expect(request.headers, <String, String>{
        'authorization': 'Bearer access-token-a',
        'content-type': 'application/json',
      });
      expect(jsonDecode(request.body), <String, Object?>{
        'pushToken': 'private-fcm-token-abcdefghijklmnopqrstuvwxyz',
        'platform': 'android',
      });
      expect(request.body, isNot(contains('company')));
      expect(request.body, isNot(contains('driver-session-a')));
      expect(request.body, isNot(contains('load')));
    });

    test('rejects an acknowledgement if the authenticated session changes during the request', () async {
      final session = _FakeSession(
        userId: 'driver-session-a',
        accessToken: 'access-token-a',
      );
      final transport = _FakeTransport()
        ..beforeResponse = () {
          session.userId = 'driver-session-b';
          session.accessToken = 'access-token-b';
        };
      final gateway = AuthenticatedDriverPushRegistrationGateway(
        session: session,
        endpoint: Uri.parse('https://admin.carrierflow.test/api/driver/push-device'),
        transport: transport,
      );

      await expectLater(
        gateway.registerOwnPushDevice(
          pushToken: 'private-fcm-token-abcdefghijklmnopqrstuvwxyz',
          platform: 'ios',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}

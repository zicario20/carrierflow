import 'dart:convert';
import 'dart:io';

import 'package:carrierflow_driver/core/push/push_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Session material is read only at the mobile boundary. Neither a company,
/// driver, nor load id is accepted or sent; the Next route verifies the bearer
/// through Supabase auth.getUser before its service-role writer is called.
abstract interface class DriverPushSession {
  String? get userId;
  String? get accessToken;
}

final class SupabaseDriverPushSession implements DriverPushSession {
  SupabaseDriverPushSession(this._client);

  final SupabaseClient _client;

  @override
  String? get userId => _client.auth.currentUser?.id;

  @override
  String? get accessToken => _client.auth.currentSession?.accessToken;
}

abstract interface class DriverPushHttpTransport {
  Future<int> post(
    Uri uri, {
    required Map<String, String> headers,
    required String body,
  });
}

final class DartIoDriverPushHttpTransport implements DriverPushHttpTransport {
  DartIoDriverPushHttpTransport({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  @override
  Future<int> post(
    Uri uri, {
    required Map<String, String> headers,
    required String body,
  }) async {
    final request = await _client.postUrl(uri);
    headers.forEach(request.headers.set);
    request.add(utf8.encode(body));
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  }
}

/// Authenticated HTTPS gateway for the server-only AES registration endpoint.
/// A non-200 response and any session switch fail closed so the visible driver
/// notification state remains `unavailable`, never a false registration claim.
final class AuthenticatedDriverPushRegistrationGateway
    implements DriverPushRegistrationGateway {
  AuthenticatedDriverPushRegistrationGateway({
    required DriverPushSession session,
    required Uri? endpoint,
    DriverPushHttpTransport? transport,
  }) : _session = session,
       _endpoint = endpoint,
       _transport = transport ?? DartIoDriverPushHttpTransport();

  final DriverPushSession _session;
  final Uri? _endpoint;
  final DriverPushHttpTransport _transport;

  @override
  String? get currentUserId => _session.userId;

  @override
  Future<void> registerOwnPushDevice({
    required String pushToken,
    required String platform,
  }) async {
    final initiatingUserId = _session.userId;
    final initiatingAccessToken = _session.accessToken;
    final endpoint = _endpoint;
    if (
        initiatingUserId == null ||
        initiatingAccessToken == null ||
        endpoint == null ||
        endpoint.scheme != 'https' ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        (platform != 'android' && platform != 'ios')) {
      throw StateError('authenticated push registration is unavailable');
    }

    final statusCode = await _transport.post(
      endpoint,
      headers: <String, String>{
        'authorization': 'Bearer $initiatingAccessToken',
        'content-type': 'application/json',
      },
      body: jsonEncode(<String, String>{
        'pushToken': pushToken,
        'platform': platform,
      }),
    );
    if (
        _session.userId != initiatingUserId ||
        _session.accessToken != initiatingAccessToken ||
        statusCode != HttpStatus.ok) {
      throw StateError('authenticated push registration was not acknowledged');
    }
  }
}

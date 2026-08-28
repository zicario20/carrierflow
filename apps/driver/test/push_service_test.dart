import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:carrierflow_driver/core/push/push_service.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';

final class _FakePushMessageSource implements DriverPushMessageSource {
  final foreground = StreamController<Map<String, Object?>>.broadcast();
  final opened = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get foregroundMessages => foreground.stream;

  @override
  Stream<Map<String, Object?>> get openedAppMessages => opened.stream;

  Future<void> dispose() async {
    await foreground.close();
    await opened.close();
  }
}

final class _FakePushPlatform
    implements DriverPushPlatform, DriverPushInitialMessageSource {
  _FakePushPlatform({
    this.authorization = PushNotificationAuthorization.notDetermined,
    this.requestedAuthorization = PushNotificationAuthorization.authorized,
    this.token = 'abcdefghijklmnopqrstuvwxyz1234567890',
    this.platform = 'android',
    List<Future<Map<String, Object?>?>>? initialMessages,
  }) : _initialMessages = Queue<Future<Map<String, Object?>?>>.of(
         initialMessages ?? <Future<Map<String, Object?>?>>[Future.value(null)],
       );

  PushNotificationAuthorization authorization;
  final PushNotificationAuthorization requestedAuthorization;
  String? token;
  @override
  final String platform;
  var tokenReads = 0;
  var permissionRequests = 0;
  var initialMessageReads = 0;
  final Queue<Future<Map<String, Object?>?>> _initialMessages;
  final foreground = StreamController<Map<String, Object?>>.broadcast();
  final opened = StreamController<Map<String, Object?>>.broadcast();
  final refreshedTokens = StreamController<String>.broadcast();

  @override
  Stream<Map<String, Object?>> get foregroundMessages => foreground.stream;

  @override
  Stream<Map<String, Object?>> get openedAppMessages => opened.stream;

  @override
  Future<PushNotificationAuthorization> currentAuthorization() async =>
      authorization;

  @override
  Future<PushNotificationAuthorization> requestAuthorization() async {
    permissionRequests += 1;
    authorization = requestedAuthorization;
    return authorization;
  }

  @override
  Future<String?> getToken() async {
    tokenReads += 1;
    return token;
  }

  Future<Map<String, Object?>?> getInitialMessage() {
    initialMessageReads += 1;
    if (_initialMessages.isEmpty) return Future<Map<String, Object?>?>.value(null);
    return _initialMessages.removeFirst();
  }

  @override
  Stream<String> get tokenRefreshes => refreshedTokens.stream;

  Future<void> dispose() async {
    await foreground.close();
    await opened.close();
    await refreshedTokens.close();
  }
}

final class _FakePushRegistrationGateway
    implements DriverPushRegistrationGateway {
  _FakePushRegistrationGateway(this.currentUserId);

  @override
  String? currentUserId;
  Object? registrationError;
  final registrations = <Map<String, String>>[];

  @override
  Future<void> registerOwnPushDevice({
    required String pushToken,
    required String platform,
  }) async {
    if (registrationError != null) throw registrationError!;
    registrations.add(<String, String>{
      'pushToken': pushToken,
      'platform': platform,
    });
  }
}

final class _MemoryPendingPushStore implements DriverPendingPushStore {
  String? notificationId;
  final remembered = <String>[];

  @override
  Future<void> clear() async {
    notificationId = null;
  }

  @override
  Future<String?> take() async {
    final pending = notificationId;
    notificationId = null;
    return pending;
  }

  @override
  Future<void> remember(String value) async {
    remembered.add(value);
    notificationId = value;
  }
}

final class _DelayedClearPendingPushStore implements DriverPendingPushStore {
  String? notificationId;
  final clearStarted = Completer<void>();
  final allowClear = Completer<void>();

  @override
  Future<void> clear() async {
    if (!clearStarted.isCompleted) clearStarted.complete();
    await allowClear.future;
    notificationId = null;
  }

  @override
  Future<void> remember(String value) async {
    notificationId = value;
  }

  @override
  Future<String?> take() async {
    final pending = notificationId;
    notificationId = null;
    return pending;
  }
}

final class _FakeBackgroundPushRegistrar
    implements DriverPushBackgroundRegistrar {
  Future<void> Function(RemoteMessage)? registeredHandler;

  @override
  void register(Future<void> Function(RemoteMessage) handler) {
    registeredHandler = handler;
  }
}

void main() {
  test('emits an own-view refresh only for a minimal notification UUID', () async {
    final source = _FakePushMessageSource();
    final service = DriverPushRefreshService(source: source);
    final refreshes = <void>[];
    final subscription = service.ownViewRefreshes.listen(refreshes.add);
    addTearDown(() async {
      await subscription.cancel();
      service.dispose();
      await source.dispose();
    });

    service.start();
    source.foreground.add(<String, Object?>{
      'companyId': 'must-not-be-a-client-scope',
      'loadId': 'must-not-be-a-client-scope',
    });
    await Future<void>.delayed(Duration.zero);
    expect(refreshes, isEmpty);

    source.opened.add(<String, Object?>{
      'notificationId': '11111111-1111-4111-8111-111111111111',
      'loadId': 'ignored-and-never-routed',
    });
    await Future<void>.delayed(Duration.zero);
    expect(refreshes, hasLength(1));
  });

  test('stops listening when the authenticated driver view is disposed', () async {
    final source = _FakePushMessageSource();
    final service = DriverPushRefreshService(source: source);
    final refreshes = <void>[];
    final subscription = service.ownViewRefreshes.listen(refreshes.add);
    addTearDown(() async {
      await subscription.cancel();
      service.dispose();
      await source.dispose();
    });

    service.start();
    service.stop();
    source.foreground.add(<String, Object?>{
      'notificationId': '11111111-1111-4111-8111-111111111111',
    });
    await Future<void>.delayed(Duration.zero);

    expect(refreshes, isEmpty);
  });

  test('persists only a valid opaque UUID from a background push', () async {
    final store = _MemoryPendingPushStore();

    await persistDriverPushBackgroundHint(
      <String, Object?>{
        'notificationId': '11111111-1111-4111-8111-111111111111',
        'loadId': 'must-not-be-persisted',
        'location': 'must-not-be-persisted',
        'token': 'must-not-be-persisted',
      },
      store: store,
    );
    await persistDriverPushBackgroundHint(
      <String, Object?>{'notificationId': 'not-a-uuid'},
      store: store,
    );

    expect(store.remembered, <String>[
      '11111111-1111-4111-8111-111111111111',
    ]);
    expect(store.notificationId, '11111111-1111-4111-8111-111111111111');
  });

  test('registers the top-level background handler before app lifecycle use', () {
    final registrar = _FakeBackgroundPushRegistrar();

    registerCarrierFlowDriverPushBackgroundHandler(registrar: registrar);

    expect(registrar.registeredHandler, same(carrierFlowDriverPushBackgroundHandler));
  });

  test('boot registers the background handler before the Flutter app starts', () {
    final mainSource = File('lib/main.dart').readAsStringSync();

    expect(
      mainSource.indexOf('registerCarrierFlowDriverPushBackgroundHandler();'),
      greaterThanOrEqualTo(0),
    );
    expect(
      mainSource.indexOf('registerCarrierFlowDriverPushBackgroundHandler();'),
      lessThan(mainSource.indexOf('runApp(')),
    );
  });

  test('declares the Firebase terminated-tap port on the production platform', () {
    final source = File('lib/core/push/push_service.dart').readAsStringSync();

    expect(
      source,
      contains('implements DriverPushPlatform, DriverPushInitialMessageSource'),
    );
    expect(source, contains('_messaging.getInitialMessage()'));
  });

  test('consumes a background hint only through the current authenticated own view', () async {
    final source = _FakePushMessageSource();
    final store = _MemoryPendingPushStore()
      ..notificationId = '11111111-1111-4111-8111-111111111111';
    final service = DriverPushRefreshService(
      source: source,
      pendingPushStore: store,
    );
    final refreshes = <void>[];
    final subscription = service.ownViewRefreshes.listen(refreshes.add);
    addTearDown(() async {
      await subscription.cancel();
      service.dispose();
      await source.dispose();
    });

    await service.startForAuthenticatedSession('driver-a');
    await service.consumePendingRefreshForCurrentSession();
    await Future<void>.delayed(Duration.zero);

    expect(refreshes, hasLength(1));
    expect(store.notificationId, isNull);
  });

  test('discards a background hint before a signed-out or A-to-B session can consume it', () async {
    final source = _FakePushMessageSource();
    final store = _MemoryPendingPushStore()
      ..notificationId = '11111111-1111-4111-8111-111111111111';
    final service = DriverPushRefreshService(
      source: source,
      pendingPushStore: store,
    );
    final refreshes = <void>[];
    final subscription = service.ownViewRefreshes.listen(refreshes.add);
    addTearDown(() async {
      await subscription.cancel();
      service.dispose();
      await source.dispose();
    });

    await service.startForAuthenticatedSession('driver-a');
    await service.discardPendingRefresh();
    service.stop();
    await service.startForAuthenticatedSession('driver-b');
    await service.consumePendingRefreshForCurrentSession();

    expect(refreshes, isEmpty);
    expect(store.notificationId, isNull);
  });

  test('holds B pending-hint consumption behind an in-flight A-to-B clear', () async {
    final source = _FakePushMessageSource();
    final store = _DelayedClearPendingPushStore()
      ..notificationId = '11111111-1111-4111-8111-111111111111';
    final service = DriverPushRefreshService(
      source: source,
      pendingPushStore: store,
    );
    final refreshes = <void>[];
    final subscription = service.ownViewRefreshes.listen(refreshes.add);
    addTearDown(() async {
      await subscription.cancel();
      service.dispose();
      await source.dispose();
    });

    await service.startForAuthenticatedSession('driver-a');
    final clear = service.discardPendingRefresh();
    await store.clearStarted.future;
    await service.startForAuthenticatedSession('driver-b');
    final consume = service.consumePendingRefreshForCurrentSession();
    await Future<void>.delayed(Duration.zero);

    expect(refreshes, isEmpty);
    store.allowClear.complete();
    await Future.wait<void>(<Future<void>>[clear, consume]);
    expect(refreshes, isEmpty);
    expect(store.notificationId, isNull);
  });

  test('refreshes an authenticated own view from one terminated-app tap UUID only', () async {
    final platform = _FakePushPlatform(
      authorization: PushNotificationAuthorization.authorized,
      initialMessages: <Future<Map<String, Object?>?>>[
        Future<Map<String, Object?>?>.value(<String, Object?>{
          'notificationId': '11111111-1111-4111-8111-111111111111',
          'loadId': 'never-a-client-scope',
          'location': 'never-a-client-scope',
        }),
      ],
    );
    final gateway = _FakePushRegistrationGateway('driver-a');
    final store = _MemoryPendingPushStore()
      ..notificationId = '11111111-1111-4111-8111-111111111111';
    final service = DriverPushRefreshService(
      platformFactory: () async => platform,
      registrationGateway: gateway,
      pendingPushStore: store,
    );
    final refreshes = <void>[];
    final subscription = service.ownViewRefreshes.listen(refreshes.add);
    addTearDown(() async {
      await subscription.cancel();
      service.dispose();
      await platform.dispose();
    });

    await service.startForAuthenticatedSession('driver-a');
    await Future<void>.delayed(Duration.zero);
    await service.consumePendingRefreshForCurrentSession();
    await Future<void>.delayed(Duration.zero);

    expect(platform.initialMessageReads, 1);
    expect(refreshes, hasLength(1));
    expect(store.notificationId, isNull);
  });

  test('dedupes a background tap and resumed lifecycle by opaque UUID', () async {
    final platform = _FakePushPlatform(
      authorization: PushNotificationAuthorization.authorized,
    );
    final gateway = _FakePushRegistrationGateway('driver-a');
    final store = _MemoryPendingPushStore()
      ..notificationId = '11111111-1111-4111-8111-111111111111';
    final service = DriverPushRefreshService(
      platformFactory: () async => platform,
      registrationGateway: gateway,
      pendingPushStore: store,
    );
    final refreshes = <void>[];
    final subscription = service.ownViewRefreshes.listen(refreshes.add);
    addTearDown(() async {
      await subscription.cancel();
      service.dispose();
      await platform.dispose();
    });

    await service.startForAuthenticatedSession('driver-a');
    platform.opened.add(<String, Object?>{
      'notificationId': '11111111-1111-4111-8111-111111111111',
      'driverId': 'never-a-client-scope',
    });
    await Future<void>.delayed(Duration.zero);
    await service.consumePendingRefreshForCurrentSession();
    await Future<void>.delayed(Duration.zero);

    expect(refreshes, hasLength(1));
    expect(store.notificationId, isNull);
  });

  test('ignores a terminated-app tap that resolves after an A-to-B session switch', () async {
    final staleInitialMessage = Completer<Map<String, Object?>?>();
    final platform = _FakePushPlatform(
      authorization: PushNotificationAuthorization.authorized,
      initialMessages: <Future<Map<String, Object?>?>>[
        staleInitialMessage.future,
        Future<Map<String, Object?>?>.value(null),
      ],
    );
    final gateway = _FakePushRegistrationGateway('driver-a');
    final service = DriverPushRefreshService(
      platformFactory: () async => platform,
      registrationGateway: gateway,
    );
    final refreshes = <void>[];
    final subscription = service.ownViewRefreshes.listen(refreshes.add);
    addTearDown(() async {
      await subscription.cancel();
      service.dispose();
      await platform.dispose();
    });

    unawaited(service.startForAuthenticatedSession('driver-a'));
    await Future<void>.delayed(Duration.zero);
    gateway.currentUserId = 'driver-b';
    await service.startForAuthenticatedSession('driver-b');
    staleInitialMessage.complete(<String, Object?>{
      'notificationId': '11111111-1111-4111-8111-111111111111',
    });
    await Future<void>.delayed(Duration.zero);

    expect(refreshes, isEmpty);
  });

  test('is an honest no-op when Firebase messaging is not configured', () async {
    final service = DriverPushRefreshService.unavailable();
    final refreshes = <void>[];
    final subscription = service.ownViewRefreshes.listen(refreshes.add);
    addTearDown(() async {
      await subscription.cancel();
      service.dispose();
    });

    service.start();
    await Future<void>.delayed(Duration.zero);
    expect(refreshes, isEmpty);
  });

  test('does not initialize Firebase or register a token without its initiating authenticated session', () async {
    var factoryCalls = 0;
    final platform = _FakePushPlatform(
      requestedAuthorization: PushNotificationAuthorization.authorized,
      token: 'abcdefghijklmnopqrstuvwxyz1234567890',
      platform: 'android',
    );
    final gateway = _FakePushRegistrationGateway(null);
    final service = DriverPushRefreshService(
      platformFactory: () async {
        factoryCalls += 1;
        return platform;
      },
      registrationGateway: gateway,
    );
    addTearDown(() async {
      service.dispose();
      await platform.dispose();
    });

    await service.startForAuthenticatedSession('driver-a');

    expect(factoryCalls, 0);
    expect(platform.tokenReads, 0);
    expect(gateway.registrations, isEmpty);
    expect(service.notificationState.value.status, PushNotificationStatus.unavailable);
  });

  test('requests explicit notification consent before a zero-scope token registration', () async {
    final platform = _FakePushPlatform(platform: 'ios');
    final gateway = _FakePushRegistrationGateway('driver-a');
    final service = DriverPushRefreshService(
      platformFactory: () async => platform,
      registrationGateway: gateway,
    );
    addTearDown(() async {
      service.dispose();
      await platform.dispose();
    });

    await service.startForAuthenticatedSession('driver-a');
    expect(service.notificationState.value.status, PushNotificationStatus.permissionRequired);
    expect(platform.tokenReads, 0);
    expect(gateway.registrations, isEmpty);

    await service.requestPermissionAndRegister();

    expect(platform.permissionRequests, 1);
    expect(gateway.registrations, <Map<String, String>>[
      <String, String>{
        'pushToken': 'abcdefghijklmnopqrstuvwxyz1234567890',
        'platform': 'ios',
      },
    ]);
    expect(service.notificationState.value.status, PushNotificationStatus.ready);
  });

  test('reports permission denial without reading or registering a provider token', () async {
    final platform = _FakePushPlatform(
      requestedAuthorization: PushNotificationAuthorization.denied,
    );
    final gateway = _FakePushRegistrationGateway('driver-a');
    final service = DriverPushRefreshService(
      platformFactory: () async => platform,
      registrationGateway: gateway,
    );
    addTearDown(() async {
      service.dispose();
      await platform.dispose();
    });

    await service.startForAuthenticatedSession('driver-a');
    await service.requestPermissionAndRegister();

    expect(service.notificationState.value.status, PushNotificationStatus.denied);
    expect(platform.tokenReads, 0);
    expect(gateway.registrations, isEmpty);
  });

  test('never shows ready when the server declines delivery configuration', () async {
    final platform = _FakePushPlatform();
    final gateway = _FakePushRegistrationGateway('driver-a')
      ..registrationError = StateError('delivery unavailable');
    final service = DriverPushRefreshService(
      platformFactory: () async => platform,
      registrationGateway: gateway,
    );
    addTearDown(() async {
      service.dispose();
      await platform.dispose();
    });

    await service.startForAuthenticatedSession('driver-a');
    await service.requestPermissionAndRegister();

    expect(
      service.notificationState.value.status,
      PushNotificationStatus.registrationUnavailable,
    );
    expect(service.notificationState.value.status, isNot(PushNotificationStatus.ready));
  });

  test('disposes an old token-refresh listener before a session change can register it', () async {
    final platform = _FakePushPlatform(
      authorization: PushNotificationAuthorization.authorized,
    );
    final gateway = _FakePushRegistrationGateway('driver-a');
    final service = DriverPushRefreshService(
      platformFactory: () async => platform,
      registrationGateway: gateway,
    );
    addTearDown(() async {
      service.dispose();
      await platform.dispose();
    });

    await service.startForAuthenticatedSession('driver-a');
    expect(gateway.registrations, hasLength(1));
    gateway.currentUserId = 'driver-b';
    service.stop();
    platform.refreshedTokens.add('bcdefghijklmnopqrstuvwxyz12345678901');
    await Future<void>.delayed(Duration.zero);

    expect(gateway.registrations, hasLength(1));
    expect(service.notificationState.value.status, PushNotificationStatus.unavailable);
  });
}

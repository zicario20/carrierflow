import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A background FCM isolate is not authorized to read a driver, company, load,
/// location, or session. It retains only one opaque notification acknowledgement
/// so the next authenticated foreground lifecycle can reread its own view.
abstract interface class DriverPendingPushStore {
  Future<void> remember(String notificationId);

  Future<String?> take();

  Future<void> clear();
}

/// Keychain/Keystore-backed storage for one opaque UUID. This namespace must
/// never contain FCM tokens, route data, locations, loads, or auth sessions.
final class FlutterSecurePendingPushStore implements DriverPendingPushStore {
  FlutterSecurePendingPushStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(
              storageNamespace: 'carrierflow.driver.push',
              resetOnError: false,
              migrateOnAlgorithmChange: false,
            ),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
              synchronizable: false,
            ),
          );

  static const _pendingNotificationKey =
      'carrierflow.driver.push.pending-notification-id';

  final FlutterSecureStorage _storage;

  @override
  Future<void> clear() => _storage.delete(key: _pendingNotificationKey);

  @override
  Future<void> remember(String notificationId) =>
      _storage.write(key: _pendingNotificationKey, value: notificationId);

  @override
  Future<String?> take() async {
    final notificationId = await _storage.read(key: _pendingNotificationKey);
    await _storage.delete(key: _pendingNotificationKey);
    return notificationId;
  }
}

final RegExp _driverPushNotificationIdPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

/// Persists only a valid opaque notification UUID. The input map is treated as
/// untrusted transport data: every field other than `notificationId` is ignored.
Future<void> persistDriverPushBackgroundHint(
  Map<String, Object?> data, {
  required DriverPendingPushStore store,
}) async {
  final notificationId = data['notificationId'];
  if (notificationId is! String ||
      !_driverPushNotificationIdPattern.hasMatch(notificationId)) {
    return;
  }
  await store.remember(notificationId);
}

/// Firebase requires a top-level entry point for data messages delivered while
/// the UI isolate is unavailable. This is deliberately best effort: OS delivery
/// policies and force-quit behavior still apply. It cannot register devices,
/// call backend RPCs, or refresh a view until a user is authenticated again.
@pragma('vm:entry-point')
Future<void> carrierFlowDriverPushBackgroundHandler(RemoteMessage message) async {
  try {
    if (Firebase.apps.isEmpty) await Firebase.initializeApp();
    await persistDriverPushBackgroundHint(
      Map<String, Object?>.from(message.data),
      store: FlutterSecurePendingPushStore(),
    );
  } on Object {
    // No Firebase configuration or secure-store access is a degraded no-op.
  }
}

abstract interface class DriverPushBackgroundRegistrar {
  void register(Future<void> Function(RemoteMessage) handler);
}

final class FirebaseDriverPushBackgroundRegistrar
    implements DriverPushBackgroundRegistrar {
  const FirebaseDriverPushBackgroundRegistrar();

  @override
  void register(Future<void> Function(RemoteMessage) handler) {
    FirebaseMessaging.onBackgroundMessage(handler);
  }
}

/// Registers before [runApp] so a data-only operational update can be retained
/// by the OS background isolate and consumed later by an authenticated view.
void registerCarrierFlowDriverPushBackgroundHandler({
  DriverPushBackgroundRegistrar? registrar,
}) {
  (registrar ?? const FirebaseDriverPushBackgroundRegistrar()).register(
    carrierFlowDriverPushBackgroundHandler,
  );
}

/// A narrow message boundary. Driver refresh notifications intentionally carry
/// no tenant, driver, load, cargo, location, pricing, or document scope.
abstract interface class DriverPushMessageSource {
  Stream<Map<String, Object?>> get foregroundMessages;
  Stream<Map<String, Object?>> get openedAppMessages;
}

/// Firebase exposes a terminated-app notification tap separately from the
/// foreground and background-open streams. It remains an opaque acknowledgement
/// and is read only after the authenticated session has been established.
abstract interface class DriverPushInitialMessageSource {
  Future<Map<String, Object?>?> getInitialMessage();
}

/// The OS permission result is deliberately separate from a registration
/// result: a user may authorize a notification but Firebase configuration or
/// server-side encrypted registration can still be unavailable.
enum PushNotificationAuthorization { notDetermined, authorized, denied }

enum PushNotificationStatus {
  unavailable,
  permissionRequired,
  denied,
  registrationUnavailable,
  ready,
}

final class PushNotificationState {
  const PushNotificationState(this.status);

  final PushNotificationStatus status;
}

/// Platform capability used only after a driver is authenticated. It has no
/// company, driver, load, or device-registration scope.
abstract interface class DriverPushPlatform implements DriverPushMessageSource {
  String get platform;
  Future<PushNotificationAuthorization> currentAuthorization();
  Future<PushNotificationAuthorization> requestAuthorization();
  Future<String?> getToken();
  Stream<String> get tokenRefreshes;
}

typedef DriverPushPlatformFactory = Future<DriverPushPlatform?> Function();

/// This HTTP boundary remains zero-scope. It sends only a bearer, provider
/// token and platform to the authenticated Next route; the server verifies
/// auth.getUser and derives active driver/company membership before its
/// service-role encrypted write.
abstract interface class DriverPushRegistrationGateway {
  String? get currentUserId;

  Future<void> registerOwnPushDevice({
    required String pushToken,
    required String platform,
  });
}

final class FirebaseDriverPushPlatform
    implements DriverPushPlatform, DriverPushInitialMessageSource {
  FirebaseDriverPushPlatform._(this._messaging, this.platform);

  final FirebaseMessaging _messaging;

  @override
  final String platform;

  static Future<DriverPushPlatform?> initializeIfAvailable() async {
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
      final platform = switch (defaultTargetPlatform) {
        TargetPlatform.android => 'android',
        TargetPlatform.iOS => 'ios',
        _ => null,
      };
      if (platform == null) return null;
      return FirebaseDriverPushPlatform._(FirebaseMessaging.instance, platform);
    } on Object {
      // A local/private-pilot build without Firebase configuration must not
      // imply that notifications were configured or a token was registered.
      return null;
    }
  }

  @override
  Stream<Map<String, Object?>> get foregroundMessages =>
      FirebaseMessaging.onMessage.map(_minimalData);

  @override
  Stream<Map<String, Object?>> get openedAppMessages =>
      FirebaseMessaging.onMessageOpenedApp.map(_minimalData);

  @override
  Future<Map<String, Object?>?> getInitialMessage() async {
    final message = await _messaging.getInitialMessage();
    return message == null ? null : _minimalData(message);
  }

  @override
  Stream<String> get tokenRefreshes => _messaging.onTokenRefresh;

  @override
  Future<PushNotificationAuthorization> currentAuthorization() async =>
      _authorizationFor(await _messaging.getNotificationSettings());

  @override
  Future<PushNotificationAuthorization> requestAuthorization() async =>
      _authorizationFor(
        await _messaging.requestPermission(alert: true, badge: true, sound: true),
      );

  @override
  Future<String?> getToken() => _messaging.getToken();

  static Map<String, Object?> _minimalData(RemoteMessage message) =>
      Map<String, Object?>.from(message.data);

  static PushNotificationAuthorization _authorizationFor(
    NotificationSettings settings,
  ) => switch (settings.authorizationStatus) {
    AuthorizationStatus.authorized || AuthorizationStatus.provisional =>
      PushNotificationAuthorization.authorized,
    AuthorizationStatus.denied || AuthorizationStatus.deniedPermanently =>
      PushNotificationAuthorization.denied,
    AuthorizationStatus.notDetermined =>
      PushNotificationAuthorization.notDetermined,
  };
}

/// Receives an opaque push acknowledgement and asks the already-authenticated
/// driver screen to reread its own server-authorized view. Firebase is created
/// only during an authenticated lifecycle; signed-out callers neither initialize
/// Firebase nor request/register a device token.
final class DriverPushRefreshService {
  DriverPushRefreshService({
    DriverPushMessageSource? source,
    DriverPushPlatformFactory? platformFactory,
    DriverPushRegistrationGateway? registrationGateway,
    DriverPendingPushStore? pendingPushStore,
  }) : _source = source,
       _platformFactory = platformFactory,
       _registrationGateway = registrationGateway,
       _pendingPushStore =
           pendingPushStore ?? FlutterSecurePendingPushStore();

  factory DriverPushRefreshService.unavailable() => DriverPushRefreshService();

  factory DriverPushRefreshService.fromFirebaseIfAvailable({
    required DriverPushRegistrationGateway registrationGateway,
  }) => DriverPushRefreshService(
    platformFactory: FirebaseDriverPushPlatform.initializeIfAvailable,
    registrationGateway: registrationGateway,
  );

  static final RegExp _tokenPattern = RegExp(r'^[A-Za-z0-9:_-]{20,4096}$');

  final DriverPushMessageSource? _source;
  final DriverPushPlatformFactory? _platformFactory;
  final DriverPushRegistrationGateway? _registrationGateway;
  final DriverPendingPushStore _pendingPushStore;
  Future<void> _pendingStoreBarrier = Future<void>.value();
  final StreamController<void> _ownViewRefreshController =
      StreamController<void>.broadcast();
  final ValueNotifier<PushNotificationState> notificationState =
      ValueNotifier<PushNotificationState>(
        const PushNotificationState(PushNotificationStatus.unavailable),
      );
  StreamSubscription<Map<String, Object?>>? _foregroundSubscription;
  StreamSubscription<Map<String, Object?>>? _openedSubscription;
  StreamSubscription<String>? _tokenRefreshSubscription;
  DriverPushPlatform? _platform;
  String? _sessionUserId;
  String? _lastRefreshedNotificationId;
  var _lastRefreshGeneration = -1;
  var _generation = 0;
  var _disposed = false;
  var _started = false;

  Stream<void> get ownViewRefreshes => _ownViewRefreshController.stream;

  /// Compatibility boundary for opaque-message refresh tests. The production
  /// authenticated lifecycle uses [startForAuthenticatedSession] instead.
  void start() {
    final source = _source;
    if (_disposed || _started || source == null) return;
    _startMessageSource(source);
  }

  Future<void> startForAuthenticatedSession(String userId) async {
    if (_disposed) return;
    stop();
    if (userId.isEmpty) {
      _setStatus(PushNotificationStatus.unavailable);
      return;
    }

    final generation = ++_generation;
    _sessionUserId = userId;
    final gateway = _registrationGateway;
    final factory = _platformFactory;
    if (gateway == null || factory == null ||
        gateway.currentUserId != userId) {
      // A caller-provided opaque source is used by the refresh-only boundary
      // and test harness. It has no Firebase initialization or registration
      // capability, but it must remain able to trigger an own-view reread.
      final source = _source;
      if (source != null) _startMessageSource(source);
      _setStatus(PushNotificationStatus.unavailable);
      return;
    }

    DriverPushPlatform? platform;
    try {
      platform = await factory();
    } on Object {
      platform = null;
    }
    if (!_isActiveSession(userId, generation) || platform == null) {
      if (_isActiveSession(userId, generation)) {
        _setStatus(PushNotificationStatus.unavailable);
      }
      return;
    }

    _platform = platform;
    _startMessageSource(platform);
    unawaited(_consumeInitialMessageIfAvailable(platform, userId, generation));
    PushNotificationAuthorization authorization;
    try {
      authorization = await platform.currentAuthorization();
    } on Object {
      if (_isActiveSession(userId, generation)) {
        _setStatus(PushNotificationStatus.unavailable);
      }
      return;
    }
    if (!_isActiveSession(userId, generation)) return;
    await _applyAuthorization(authorization, userId, generation);
  }

  /// Must be called from an explicit user action. It never opens an OS prompt
  /// merely because a driver signed in.
  Future<void> requestPermissionAndRegister() async {
    final userId = _sessionUserId;
    final platform = _platform;
    if (userId == null || platform == null || !_isActiveSession(userId, _generation)) {
      _setStatus(PushNotificationStatus.unavailable);
      return;
    }

    PushNotificationAuthorization authorization;
    try {
      authorization = await platform.requestAuthorization();
    } on Object {
      if (_isActiveSession(userId, _generation)) {
        _setStatus(PushNotificationStatus.unavailable);
      }
      return;
    }
    if (!_isActiveSession(userId, _generation)) return;
    await _applyAuthorization(authorization, userId, _generation);
  }

  /// Invoked after authentication and on app resume. The pending value carries
  /// no routing scope; after it is consumed the UI refreshes only through its
  /// already-authorized own-load repository.
  Future<void> consumePendingRefreshForCurrentSession() async {
    final userId = _sessionUserId;
    final generation = _generation;
    if (userId == null || !_isCurrentSession(userId, generation)) return;

    String? notificationId;
    try {
      notificationId = await _enqueuePendingStoreOperation(
        _pendingPushStore.take,
      );
    } on Object {
      return;
    }
    if (notificationId == null ||
        !_driverPushNotificationIdPattern.hasMatch(notificationId)) {
      return;
    }
    _emitOwnViewRefreshForNotification(notificationId, userId, generation);
  }

  /// Explicit session boundaries discard a hint from the prior authenticated
  /// user before another account can resume its own view.
  Future<void> discardPendingRefresh() async {
    try {
      await _enqueuePendingStoreOperation(_pendingPushStore.clear);
    } on Object {
      // A secure-store failure must not keep the signed-out UI alive.
    }
  }

  void stop() {
    _generation += 1;
    _sessionUserId = null;
    _platform = null;
    _lastRefreshedNotificationId = null;
    _lastRefreshGeneration = -1;
    _started = false;
    final foregroundSubscription = _foregroundSubscription;
    final openedSubscription = _openedSubscription;
    final tokenRefreshSubscription = _tokenRefreshSubscription;
    _foregroundSubscription = null;
    _openedSubscription = null;
    _tokenRefreshSubscription = null;
    if (foregroundSubscription != null) {
      unawaited(foregroundSubscription.cancel());
    }
    if (openedSubscription != null) {
      unawaited(openedSubscription.cancel());
    }
    if (tokenRefreshSubscription != null) {
      unawaited(tokenRefreshSubscription.cancel());
    }
    if (!_disposed) _setStatus(PushNotificationStatus.unavailable);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    stop();
    notificationState.dispose();
    unawaited(_ownViewRefreshController.close());
  }

  Future<void> _applyAuthorization(
    PushNotificationAuthorization authorization,
    String userId,
    int generation,
  ) async {
    switch (authorization) {
      case PushNotificationAuthorization.notDetermined:
        _setStatus(PushNotificationStatus.permissionRequired);
        return;
      case PushNotificationAuthorization.denied:
        _setStatus(PushNotificationStatus.denied);
        return;
      case PushNotificationAuthorization.authorized:
        await _registerCurrentToken(userId, generation);
    }
  }

  Future<void> _registerCurrentToken(String userId, int generation) async {
    final platform = _platform;
    final gateway = _registrationGateway;
    if (platform == null || gateway == null || !_isActiveSession(userId, generation)) {
      return;
    }
    String? token;
    try {
      token = await platform.getToken();
    } on Object {
      token = null;
    }
    if (!_isActiveSession(userId, generation)) return;
    if (token == null || !_tokenPattern.hasMatch(token)) {
      _setStatus(PushNotificationStatus.registrationUnavailable);
      return;
    }

    try {
      await gateway.registerOwnPushDevice(
        pushToken: token,
        platform: platform.platform,
      );
    } on Object {
      if (_isActiveSession(userId, generation)) {
        _setStatus(PushNotificationStatus.registrationUnavailable);
      }
      return;
    }
    if (!_isActiveSession(userId, generation)) return;

    _startMessageSource(platform);
    _tokenRefreshSubscription ??= platform.tokenRefreshes.listen((refreshedToken) {
      unawaited(_registerRefreshedToken(refreshedToken, userId, generation));
    });
    _setStatus(PushNotificationStatus.ready);
  }

  Future<void> _registerRefreshedToken(
    String token,
    String userId,
    int generation,
  ) async {
    final gateway = _registrationGateway;
    final platform = _platform;
    if (gateway == null || platform == null || !_isActiveSession(userId, generation)) {
      return;
    }
    if (!_tokenPattern.hasMatch(token)) {
      _setStatus(PushNotificationStatus.registrationUnavailable);
      return;
    }
    try {
      await gateway.registerOwnPushDevice(pushToken: token, platform: platform.platform);
    } on Object {
      if (_isActiveSession(userId, generation)) {
        _setStatus(PushNotificationStatus.registrationUnavailable);
      }
    }
  }

  bool _isCurrentSession(String userId, int generation) =>
      !_disposed &&
      _sessionUserId == userId &&
      _generation == generation &&
      (_registrationGateway == null ||
          _registrationGateway.currentUserId == userId);

  bool _isActiveSession(String userId, int generation) =>
      _registrationGateway != null && _isCurrentSession(userId, generation);

  void _startMessageSource(DriverPushMessageSource source) {
    if (_disposed || _started) return;
    _started = true;
    _foregroundSubscription = source.foregroundMessages.listen(
      (data) => unawaited(_handleMessage(data)),
    );
    _openedSubscription = source.openedAppMessages.listen(
      (data) => unawaited(_handleMessage(data)),
    );
  }

  void _setStatus(PushNotificationStatus status) {
    if (_disposed || notificationState.value.status == status) return;
    notificationState.value = PushNotificationState(status);
  }

  Future<void> _consumeInitialMessageIfAvailable(
    DriverPushPlatform platform,
    String userId,
    int generation,
  ) async {
    final DriverPushInitialMessageSource? initialMessageSource =
        platform is DriverPushInitialMessageSource
        ? platform as DriverPushInitialMessageSource
        : null;
    if (initialMessageSource == null ||
        !_isCurrentSession(userId, generation)) {
      return;
    }
    Map<String, Object?>? data;
    try {
      data = await initialMessageSource.getInitialMessage();
    } on Object {
      return;
    }
    if (data == null) return;
    await _handleMessageForSession(data, userId, generation);
  }

  Future<void> _handleMessage(Map<String, Object?> data) =>
      _handleMessageForSession(data, _sessionUserId, _generation);

  Future<void> _handleMessageForSession(
    Map<String, Object?> data,
    String? userId,
    int generation,
  ) async {
    if (_disposed || !_started) return;
    final notificationId = data['notificationId'];
    if (notificationId is! String ||
        !_driverPushNotificationIdPattern.hasMatch(notificationId)) {
      return;
    }
    // A notification tap can follow an OS background delivery of the same
    // opaque UUID. Queue its retained hint for discard, but do not make a
    // valid direct refresh wait on Keychain/Keystore; the in-memory UUID
    // dedupe below already prevents a resumed lifecycle from fetching twice.
    unawaited(_discardPendingHintAfterDirectMessage());
    _emitOwnViewRefreshForNotification(notificationId, userId, generation);
  }

  void _emitOwnViewRefreshForNotification(
    String notificationId,
    String? userId,
    int generation,
  ) {
    final currentSession = userId == null
        ? !_disposed && _started
        : _isCurrentSession(userId, generation);
    if (!currentSession ||
        (_lastRefreshGeneration == generation &&
            _lastRefreshedNotificationId == notificationId)) {
      return;
    }
    _lastRefreshGeneration = generation;
    _lastRefreshedNotificationId = notificationId;
    _ownViewRefreshController.add(null);
  }

  /// Keychain/Keystore calls are asynchronous. Serialize clear/take operations
  /// so an unawaited A-to-B clear in AuthGate cannot race B's initial consume.
  Future<T> _enqueuePendingStoreOperation<T>(Future<T> Function() operation) {
    final result = _pendingStoreBarrier.then((_) => operation());
    _pendingStoreBarrier = result.then<void>(
      (_) {},
      onError: (_, __) {},
    );
    return result;
  }

  Future<void> _discardPendingHintAfterDirectMessage() async {
    try {
      await _enqueuePendingStoreOperation(_pendingPushStore.take);
    } on Object {
      // The source message itself remains an authenticated opaque refresh;
      // a storage failure must not claim that a token or delivery succeeded.
    }
  }
}

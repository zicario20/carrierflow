import 'dart:async';
import 'dart:convert';

import 'package:carrierflow_driver/core/bootstrap/driver_execution_repository.dart';
import 'package:carrierflow_driver/core/bootstrap/driver_push_registration_gateway.dart';
import 'package:carrierflow_driver/core/bootstrap/secure_supabase_storage.dart';
import 'package:carrierflow_driver/core/push/push_service.dart';
import 'package:carrierflow_driver/core/sync/sync_lifecycle.dart';
import 'package:carrierflow_driver/features/auth/auth_gate.dart';
import 'package:carrierflow_driver/features/loads/load_state_controller.dart';
import 'package:carrierflow_driver/features/tracking/tracking_background_work.dart';
import 'package:carrierflow_driver/features/tracking/tracking_runtime_coordinator.dart';
import 'package:carrierflow_driver/features/tracking/tracking_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class DriverRuntimeConfiguration {
  const DriverRuntimeConfiguration._({
    required this.supabaseUrl,
    required this.supabasePublishableKey,
    required this.driverApiUrl,
  });

  factory DriverRuntimeConfiguration.fromEnvironment() {
    return DriverRuntimeConfiguration.fromValues(
      supabaseUrl: String.fromEnvironment('SUPABASE_URL'),
      supabasePublishableKey: String.fromEnvironment(
        'SUPABASE_PUBLISHABLE_KEY',
      ),
      driverApiUrl: String.fromEnvironment('CARRIERFLOW_DRIVER_API_URL'),
    );
  }

  factory DriverRuntimeConfiguration.fromValues({
    required String supabaseUrl,
    required String supabasePublishableKey,
    String driverApiUrl = '',
  }) => DriverRuntimeConfiguration._(
    supabaseUrl: supabaseUrl.trim(),
    supabasePublishableKey: supabasePublishableKey.trim(),
    driverApiUrl: driverApiUrl.trim(),
  );

  final String supabaseUrl;
  final String supabasePublishableKey;
  final String driverApiUrl;

  /// This is a public routing setting, not a credential. Its absence keeps
  /// notifications visibly unavailable rather than falling back to a direct
  /// mobile database registration call.
  Uri? get pushDeviceRegistrationEndpoint {
    final base = Uri.tryParse(driverApiUrl);
    if (
        base == null ||
        base.scheme != 'https' ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty) {
      return null;
    }
    return base.replace(
      path: '/api/driver/push-device',
      query: null,
      fragment: null,
    );
  }

  bool get isConfigured {
    final url = Uri.tryParse(supabaseUrl);
    return url != null &&
        url.scheme == 'https' &&
        url.host.isNotEmpty &&
        url.userInfo.isEmpty &&
        supabasePublishableKey.isNotEmpty &&
        !supabasePublishableKey.startsWith('sb_secret_') &&
        !_isLegacyServiceRoleJwt(supabasePublishableKey);
  }

  static bool _isLegacyServiceRoleJwt(String value) {
    final segments = value.split('.');
    if (segments.length != 3) {
      return false;
    }

    try {
      final payload = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(segments[1]))),
      );
      return payload is Map<String, dynamic> &&
          payload['role'] == 'service_role';
    } on FormatException {
      return false;
    } on ArgumentError {
      return false;
    }
  }
}

/// Initializes only the public mobile Supabase client. The service-role key
/// is never accepted by this bootstrap and must remain server-only.
class DriverBootstrap {
  DriverBootstrap._(this._client, this._configuration);

  final SupabaseClient _client;
  final DriverRuntimeConfiguration _configuration;

  static Future<DriverBootstrap?> initializeFromEnvironment() async {
    final configuration = DriverRuntimeConfiguration.fromEnvironment();
    if (!configuration.isConfigured) {
      return null;
    }

    try {
      await Supabase.initialize(
        url: configuration.supabaseUrl,
        publishableKey: configuration.supabasePublishableKey,
        debug: false,
        authOptions: authOptionsFor(configuration),
      );
      return DriverBootstrap._(Supabase.instance.client, configuration);
    } on Object {
      // A malformed or unreachable runtime configuration exposes no data.
      return null;
    }
  }

  static String _sessionKeyFor(String supabaseUrl) =>
      'sb-${Uri.parse(supabaseUrl).host.split('.').first}-auth-token';

  static FlutterAuthClientOptions authOptionsFor(
    DriverRuntimeConfiguration configuration, {
    SecureValueStore? secureValueStore,
  }) {
    final store = secureValueStore ?? FlutterSecureValueStore();
    return FlutterAuthClientOptions(
      authFlowType: AuthFlowType.pkce,
      localStorage: SecureSupabaseSessionStorage(
        store,
        persistSessionKey: _sessionKeyFor(configuration.supabaseUrl),
      ),
      pkceAsyncStorage: SecurePkceStorage(store),
    );
  }

  late final SupabaseDriverExecutionRpcGateway _driverExecutionGateway =
      SupabaseDriverExecutionRpcGateway(_client);

  late final SupabaseDriverExecutionRepository _driverExecutionRepository =
      SupabaseDriverExecutionRepository(_driverExecutionGateway);

  OwnAssignedLoadRepository get ownAssignedLoadRepository =>
      _driverExecutionRepository;

  OwnLoadExecutionRepository get ownLoadExecutionRepository =>
      _driverExecutionRepository;

  late final DriverLoadStateSyncReconciler _loadStateSyncReconciler =
      DriverLoadStateSyncReconciler(
        _driverExecutionRepository,
        currentActorId: () => _client.auth.currentUser?.id,
      );

  DriverLoadStateSyncReconciler get loadStateSyncReconciler =>
      _loadStateSyncReconciler;

  late final DriverSyncLifecycleCoordinator _syncLifecycle =
      DriverSyncLifecycleCoordinator(
        resumer: _driverExecutionRepository,
        onSuccessfulReplay: _loadStateSyncReconciler.reconcile,
      );

  DriverSyncLifecycleCoordinator get syncLifecycle => _syncLifecycle;

  late final DriverPushRefreshService _pushRefreshService =
      DriverPushRefreshService.fromFirebaseIfAvailable(
        registrationGateway: AuthenticatedDriverPushRegistrationGateway(
          session: SupabaseDriverPushSession(_client),
          endpoint: _configuration.pushDeviceRegistrationEndpoint,
        ),
      );

  DriverPushRefreshService get pushRefreshService => _pushRefreshService;

  late final DriverTrackingRuntimeCoordinator _trackingLifecycle =
      DriverTrackingRuntimeCoordinator(
        backgroundWorkScheduler: WorkmanagerTrackingBackgroundWorkScheduler(),
        locationPlatform: GeolocatorTrackingLocationPlatform(),
        service: TrackingService(
          gateway: SupabaseTrackingGateway(
            SupabaseDriverExecutionRpcGateway(_client),
          ),
        ),
        trackingContextRepository: _driverExecutionRepository,
      );

  DriverTrackingRuntimeCoordinator get trackingLifecycle => _trackingLifecycle;

  Future<bool> runBackgroundTrackingWork() => DriverTrackingBackgroundTask(
    clock: DateTime.now,
    locationPlatform: GeolocatorTrackingLocationPlatform(),
    scheduler: WorkmanagerTrackingBackgroundWorkScheduler(),
    service: TrackingService(
      gateway: SupabaseTrackingGateway(
        SupabaseDriverExecutionRpcGateway(_client),
      ),
    ),
    trackingContextRepository: _driverExecutionRepository,
  ).run();

  static Future<bool> runBackgroundTrackingWorkFromEnvironment() async {
    final bootstrap = await initializeFromEnvironment();
    if (bootstrap == null) return true;
    return bootstrap.runBackgroundTrackingWork();
  }

  void dispose() {
    _pushRefreshService.dispose();
    _trackingLifecycle.dispose();
    _syncLifecycle.dispose();
  }

  Stream<DriverSessionState> get authStateChanges async* {
    final currentSession = _client.auth.currentSession;
    if (currentSession != null) unawaited(_syncLifecycle.resume());
    yield currentSession == null
        ? const DriverSessionSignedOut()
        : DriverSessionAuthenticated(userId: currentSession.user.id);

    await for (final event in _client.auth.onAuthStateChange) {
      if (event.session != null) unawaited(_syncLifecycle.resume());
      yield event.session == null
          ? const DriverSessionSignedOut()
          : DriverSessionAuthenticated(userId: event.session!.user.id);
    }
  }
}

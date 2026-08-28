import 'package:carrierflow_driver/core/bootstrap/driver_bootstrap.dart';
import 'package:carrierflow_driver/core/bootstrap/secure_supabase_storage.dart';
import 'package:carrierflow_driver/features/loads/load_home_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _MemorySecureValueStore implements SecureValueStore {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
  }
}

void main() {
  group('driver bootstrap runtime configuration', () {
    test('accepts only an HTTPS Supabase URL with a non-secret key', () {
      expect(
        DriverRuntimeConfiguration.fromValues(
          supabaseUrl: 'https://carrierflow.example',
          supabasePublishableKey: 'sb_publishable_test-only',
        ).isConfigured,
        isTrue,
      );

      for (final configuration in <DriverRuntimeConfiguration>[
        DriverRuntimeConfiguration.fromValues(
          supabaseUrl: 'http://carrierflow.example',
          supabasePublishableKey: 'sb_publishable_test-only',
        ),
        DriverRuntimeConfiguration.fromValues(
          supabaseUrl: '',
          supabasePublishableKey: 'sb_publishable_test-only',
        ),
        DriverRuntimeConfiguration.fromValues(
          supabaseUrl: 'https://carrierflow.example',
          supabasePublishableKey: '',
        ),
      ]) {
        expect(configuration.isConfigured, isFalse);
      }
    });

    test('rejects secret and legacy service-role keys from mobile config', () {
      const legacyServiceRoleJwt =
          'eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.signature';

      for (final key in <String>['sb_secret_test-only', legacyServiceRoleJwt]) {
        expect(
          DriverRuntimeConfiguration.fromValues(
            supabaseUrl: 'https://carrierflow.example',
            supabasePublishableKey: key,
          ).isConfigured,
          isFalse,
        );
      }
    });

    test('uses an optional HTTPS API endpoint for server-side push registration', () {
      final missing = DriverRuntimeConfiguration.fromValues(
        supabaseUrl: 'https://carrierflow.example',
        supabasePublishableKey: 'sb_publishable_test-only',
      );
      final configured = DriverRuntimeConfiguration.fromValues(
        supabaseUrl: 'https://carrierflow.example',
        supabasePublishableKey: 'sb_publishable_test-only',
        driverApiUrl: 'https://admin.carrierflow.example/base',
      );
      final insecure = DriverRuntimeConfiguration.fromValues(
        supabaseUrl: 'https://carrierflow.example',
        supabasePublishableKey: 'sb_publishable_test-only',
        driverApiUrl: 'http://admin.carrierflow.example',
      );

      expect(missing.pushDeviceRegistrationEndpoint, isNull);
      expect(
        configured.pushDeviceRegistrationEndpoint.toString(),
        'https://admin.carrierflow.example/api/driver/push-device',
      );
      expect(insecure.pushDeviceRegistrationEndpoint, isNull);
    });
  });

  group('secure Supabase storage', () {
    test('configures persistent auth with secure storage and PKCE', () {
      final options = DriverBootstrap.authOptionsFor(
        DriverRuntimeConfiguration.fromValues(
          supabaseUrl: 'https://carrierflow.example',
          supabasePublishableKey: 'sb_publishable_test-only',
        ),
        secureValueStore: _MemorySecureValueStore(),
      );

      expect(options.authFlowType, AuthFlowType.pkce);
      expect(options.persistSession, isTrue);
      expect(options.localStorage, isA<SecureSupabaseSessionStorage>());
      expect(options.pkceAsyncStorage, isA<SecurePkceStorage>());
    });

    test(
      'persists the session and PKCE verifier under separate secure keys',
      () async {
        final values = _MemorySecureValueStore();
        final sessionStorage = SecureSupabaseSessionStorage(
          values,
          persistSessionKey: 'sb-carrierflow-auth-token',
        );
        final pkceStorage = SecurePkceStorage(values);

        await sessionStorage.initialize();
        await sessionStorage.persistSession('test-session');
        await pkceStorage.setItem(
          key: 'supabase.auth.token-code-verifier',
          value: 'test-verifier',
        );

        expect(await sessionStorage.accessToken(), 'test-session');
        expect(
          await pkceStorage.getItem(key: 'supabase.auth.token-code-verifier'),
          'test-verifier',
        );
        expect(values.values.keys, contains('sb-carrierflow-auth-token'));
        expect(
          values.values.keys,
          contains('carrierflow.pkce.supabase.auth.token-code-verifier'),
        );
      },
    );

    test(
      'removes only the persistent session when the driver signs out',
      () async {
        final values = _MemorySecureValueStore();
        final sessionStorage = SecureSupabaseSessionStorage(
          values,
          persistSessionKey: 'sb-carrierflow-auth-token',
        );
        final pkceStorage = SecurePkceStorage(values);
        await sessionStorage.initialize();
        await sessionStorage.persistSession('session');
        await pkceStorage.setItem(key: 'code-verifier', value: 'verifier');

        await sessionStorage.removePersistedSession();

        expect(await sessionStorage.hasAccessToken(), isFalse);
        expect(await pkceStorage.getItem(key: 'code-verifier'), 'verifier');
      },
    );

    test(
      'clears the pending PKCE verifier after explicit auth cancellation',
      () async {
        final values = _MemorySecureValueStore();
        final pkceStorage = SecurePkceStorage(values);
        await pkceStorage.setItem(
          key: SecurePkceStorage.codeVerifierKey,
          value: 'verifier',
        );

        await pkceStorage.clearPendingCodeVerifier();

        expect(
          await pkceStorage.getItem(key: SecurePkceStorage.codeVerifierKey),
          isNull,
        );
      },
    );
  });

  group('driver load partitioning', () {
    test('makes an active load current and an assigned load next regardless of row order', () {
      final snapshot = OwnAssignedLoadSnapshot.partition(
        const <DriverAssignedLoad>[
          DriverAssignedLoad(
            loadId: 'b-load',
            loadNumber: 'CF-200',
            pickupLabel: 'Dallas, TX',
            deliveryLabel: 'Houston, TX',
            operationalStatus: DriverLoadOperationalStatus.assigned,
          ),
          DriverAssignedLoad(
            loadId: 'a-load',
            loadNumber: 'CF-100',
            pickupLabel: 'Austin, TX',
            deliveryLabel: 'Dallas, TX',
            operationalStatus: DriverLoadOperationalStatus.enRouteToDelivery,
          ),
        ],
      );

      expect(snapshot.currentLoad?.loadNumber, 'CF-100');
      expect(snapshot.nextLoad?.loadNumber, 'CF-200');
    });
  });
}

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Small boundary that keeps secure platform storage replaceable in tests.
abstract interface class SecureValueStore {
  Future<String?> read(String key);

  Future<void> write({required String key, required String value});

  Future<void> delete(String key);
}

/// Keychain on iOS and Android Keystore-backed encrypted storage on Android.
/// The storage namespace is dedicated to driver auth material.
class FlutterSecureValueStore implements SecureValueStore {
  FlutterSecureValueStore()
    : _storage = const FlutterSecureStorage(
        aOptions: AndroidOptions(
          storageNamespace: 'carrierflow.driver.auth',
          resetOnError: false,
          migrateOnAlgorithmChange: false,
        ),
        iOptions: IOSOptions(
          accessibility: KeychainAccessibility.first_unlock_this_device,
          synchronizable: false,
        ),
      );

  final FlutterSecureStorage _storage;

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write({required String key, required String value}) =>
      _storage.write(key: key, value: value);
}

/// Auth sessions are persisted only by [SecureValueStore], never in shared
/// preferences. The exact Supabase session key stays compatible with the SDK.
class SecureSupabaseSessionStorage extends LocalStorage {
  SecureSupabaseSessionStorage(this._store, {required this.persistSessionKey});

  final SecureValueStore _store;
  final String persistSessionKey;

  @override
  Future<String?> accessToken() => _store.read(persistSessionKey);

  @override
  Future<bool> hasAccessToken() async =>
      (await _store.read(persistSessionKey)) != null;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> persistSession(String persistSessionString) =>
      _store.write(key: persistSessionKey, value: persistSessionString);

  @override
  Future<void> removePersistedSession() => _store.delete(persistSessionKey);
}

/// PKCE code verifiers are as sensitive as session material and use the same
/// secure platform store under a distinct namespace.
class SecurePkceStorage extends GotrueAsyncStorage {
  SecurePkceStorage(this._store);

  static const _prefix = 'carrierflow.pkce.';
  static const codeVerifierKey = 'supabase.auth.token-code-verifier';

  final SecureValueStore _store;

  @override
  Future<String?> getItem({required String key}) => _store.read(_key(key));

  @override
  Future<void> removeItem({required String key}) => _store.delete(_key(key));

  @override
  Future<void> setItem({required String key, required String value}) =>
      _store.write(key: _key(key), value: value);

  /// Auth UI must invoke this only after an explicit OAuth cancellation or
  /// sign-out. It is deliberately not cleared during bootstrap, where a valid
  /// redirect callback may still need the verifier.
  Future<void> clearPendingCodeVerifier() => removeItem(key: codeVerifierKey);

  String _key(String key) => '$_prefix$key';
}

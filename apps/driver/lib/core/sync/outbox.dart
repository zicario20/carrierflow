import 'dart:math';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A durable outbox entry is intentionally zero-scope: it stores the client
/// mutation id and typed RPC arguments only. PostgreSQL derives the driver,
/// company, load, and next state from the authenticated session at replay.
enum SyncRetryState { pending, retryable, succeeded, blocked }

abstract interface class SyncMutationIdFactory {
  String create();
}

final class UuidV4SyncMutationIdFactory implements SyncMutationIdFactory {
  UuidV4SyncMutationIdFactory({Random? random})
    : _random = random ?? Random.secure();

  final Random _random;

  @override
  String create() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}

/// The durable-storage adapter owns encryption and platform persistence. It
/// must commit [insert] before allowing a caller to schedule a network send.
/// The in-memory implementation lives only in tests; production wiring uses a
/// private on-device store and must not place outbox records in public logs.
abstract interface class SyncOutboxStore {
  Future<void> insert(SyncOutboxRecord record);

  Future<List<SyncOutboxRecord>> readPending();

  Future<void> replace(SyncOutboxRecord record);
}

abstract interface class SyncOutboxSecureValueStore {
  Future<String?> read({required String key});

  Future<void> write({required String key, required String value});
}

final class FlutterSyncOutboxSecureValueStore
    implements SyncOutboxSecureValueStore {
  FlutterSyncOutboxSecureValueStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read({required String key}) => _storage.read(key: key);

  @override
  Future<void> write({required String key, required String value}) =>
      _storage.write(key: key, value: value);
}

/// Persists the encrypted outbox as one private device value. No storage URL,
/// server credential, company, driver, or load scope is written by this
/// adapter; the RPC remains the authorization source of truth.
final class SecureSyncOutboxStore implements SyncOutboxStore {
  SecureSyncOutboxStore({SyncOutboxSecureValueStore? storage})
    : _storage = storage ?? FlutterSyncOutboxSecureValueStore();

  static const String _storageKey = 'carrierflow.sync.outbox.v1';
  final SyncOutboxSecureValueStore _storage;
  Future<void> _accessTail = Future<void>.value();

  @override
  Future<void> insert(SyncOutboxRecord record) => _serialize(() async {
    final records = await _readRecords();
    records.add(record);
    await _writeRecords(records);
  });

  @override
  Future<List<SyncOutboxRecord>> readPending() => _serialize(_readRecords);

  @override
  Future<void> replace(SyncOutboxRecord record) => _serialize(() async {
    final records = await _readRecords();
    final index = records.indexWhere(
      (candidate) => candidate.clientMutationId == record.clientMutationId,
    );
    if (index < 0) {
      throw StateError('The sync record is no longer available.');
    }
    records[index] = record;
    await _writeRecords(records);
  });

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final scheduled = _accessTail.then((_) => operation());
    _accessTail = scheduled.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return scheduled;
  }

  Future<List<SyncOutboxRecord>> _readRecords() async {
    final encoded = await _storage.read(key: _storageKey);
    if (encoded == null || encoded.isEmpty) return <SyncOutboxRecord>[];
    final decoded = jsonDecode(encoded);
    if (decoded is! List) throw const FormatException('Invalid sync outbox.');
    return decoded
        .map((entry) => _recordFromJson(entry))
        .toList(growable: true);
  }

  Future<void> _writeRecords(List<SyncOutboxRecord> records) => _storage.write(
    key: _storageKey,
    value: jsonEncode(records.map(_recordToJson).toList(growable: false)),
  );
}

final class SyncOutboxRecord {
  SyncOutboxRecord({
    required this.clientMutationId,
    required this.actorSessionId,
    required this.sequence,
    required this.functionName,
    required Map<String, Object?> arguments,
    required this.retryState,
    required this.attempts,
    this.dependsOn,
  }) : arguments = Map<String, Object?>.unmodifiable(arguments) {
    if (!_uuidV4.hasMatch(clientMutationId) ||
        actorSessionId.trim().isEmpty ||
        sequence < 0 ||
        functionName.isEmpty ||
        attempts < 0 ||
        (dependsOn != null && !_uuidV4.hasMatch(dependsOn!))) {
      throw ArgumentError('A sync outbox record is invalid.');
    }
    if (_containsClientControlledScope(this.arguments)) {
      throw ArgumentError('Outbox operations must remain server scoped.');
    }
  }

  final String clientMutationId;

  /// Private, opaque on-device ownership metadata. It is deliberately not an
  /// RPC argument: PostgreSQL still derives authority from auth.uid().
  final String actorSessionId;
  final int sequence;
  final String functionName;
  final Map<String, Object?> arguments;
  final String? dependsOn;
  final SyncRetryState retryState;
  final int attempts;

  SyncOutboxRecord copyWith({SyncRetryState? retryState, int? attempts}) =>
      SyncOutboxRecord(
        clientMutationId: clientMutationId,
        actorSessionId: actorSessionId,
        sequence: sequence,
        functionName: functionName,
        arguments: arguments,
        dependsOn: dependsOn,
        retryState: retryState ?? this.retryState,
        attempts: attempts ?? this.attempts,
      );
}

final class DriverSyncOutbox {
  DriverSyncOutbox({
    required SyncOutboxStore store,
    SyncMutationIdFactory? mutationIdFactory,
  }) : _store = store,
       _mutationIdFactory = mutationIdFactory ?? UuidV4SyncMutationIdFactory();

  final SyncOutboxStore _store;
  final SyncMutationIdFactory _mutationIdFactory;
  int _nextSequence = 0;
  Future<void> _enqueueTail = Future<void>.value();

  Future<SyncOutboxRecord> enqueueStateTransition({
    required String actorSessionId,
    String? dependsOn,
  }) => _enqueue(
    actorSessionId: actorSessionId,
    functionName: 'advance_own_driver_load_state_idempotent',
    argumentsFor: (clientMutationId) => <String, Object?>{
      'client_mutation_id': clientMutationId,
    },
    dependsOn: dependsOn,
  );

  Future<SyncOutboxRecord> enqueueEvidence({
    required String actorSessionId,
    required String evidenceType,
    required Map<String, Object?> evidenceContent,
    String? dependsOn,
  }) {
    if (!_evidenceTypes.contains(evidenceType) || evidenceContent.isEmpty) {
      throw ArgumentError(
        'A supported evidence type and content are required.',
      );
    }
    return _enqueue(
      actorSessionId: actorSessionId,
      functionName: 'record_own_driver_load_evidence_idempotent',
      argumentsFor: (clientMutationId) => <String, Object?>{
        'client_mutation_id': clientMutationId,
        'evidence_type_value': evidenceType,
        'evidence_content': evidenceContent,
      },
      dependsOn: dependsOn,
    );
  }

  Future<SyncOutboxRecord> enqueueIncident({
    required String actorSessionId,
    required String clientMutationId,
    required String incidentType,
    required String description,
    required List<String> attachments,
    required Map<String, Object?>? location,
  }) {
    if (!_uuidV4.hasMatch(clientMutationId) ||
        incidentType.isEmpty ||
        description.trim().isEmpty) {
      throw ArgumentError('Valid incident details are required.');
    }
    return _enqueueWithId(
      actorSessionId: actorSessionId,
      clientMutationId: clientMutationId,
      functionName: 'report_own_driver_load_incident_idempotent',
      arguments: <String, Object?>{
        'client_mutation_id': clientMutationId,
        'incident_type_value': incidentType,
        'incident_description': description.trim(),
        'incident_attachments': attachments,
        'incident_location': location,
      },
      dependsOn: null,
    );
  }

  Future<List<SyncOutboxRecord>> pending() async => (await _allRecords())
      .where(
        (record) =>
            record.retryState == SyncRetryState.pending ||
            record.retryState == SyncRetryState.retryable,
      )
      .toList(growable: false);

  Future<List<SyncOutboxRecord>> allRecords() => _allRecords();

  Future<void> markSucceeded(SyncOutboxRecord record) => _store.replace(
    record.copyWith(
      retryState: SyncRetryState.succeeded,
      attempts: record.attempts + 1,
    ),
  );

  Future<void> markTransientFailure(SyncOutboxRecord record) => _store.replace(
    record.copyWith(
      retryState: SyncRetryState.retryable,
      attempts: record.attempts + 1,
    ),
  );

  Future<void> markBlocked(SyncOutboxRecord record) => _store.replace(
    record.copyWith(
      retryState: SyncRetryState.blocked,
      attempts: record.attempts + 1,
    ),
  );

  Future<SyncOutboxRecord> _enqueue({
    required String actorSessionId,
    required String functionName,
    required Map<String, Object?> Function(String clientMutationId)
    argumentsFor,
    required String? dependsOn,
  }) => _serializeEnqueue(() async {
    if (functionName == 'advance_own_driver_load_state_idempotent') {
      final existing = _pendingStateTransitionFor(
        await _allRecords(),
        actorSessionId,
      );
      if (existing != null) return existing;
    }
    final clientMutationId = _mutationIdFactory.create();
    if (!_uuidV4.hasMatch(clientMutationId)) {
      throw ArgumentError('The mutation id factory must create UUIDv4 values.');
    }
    return _enqueueWithIdLocked(
      actorSessionId: actorSessionId,
      clientMutationId: clientMutationId,
      functionName: functionName,
      arguments: argumentsFor(clientMutationId),
      dependsOn: dependsOn,
    );
  });

  Future<SyncOutboxRecord> _enqueueWithId({
    required String actorSessionId,
    required String clientMutationId,
    required String functionName,
    required Map<String, Object?> arguments,
    required String? dependsOn,
  }) => _serializeEnqueue(
    () => _enqueueWithIdLocked(
      actorSessionId: actorSessionId,
      clientMutationId: clientMutationId,
      functionName: functionName,
      arguments: arguments,
      dependsOn: dependsOn,
    ),
  );

  Future<SyncOutboxRecord> _enqueueWithIdLocked({
    required String actorSessionId,
    required String clientMutationId,
    required String functionName,
    required Map<String, Object?> arguments,
    required String? dependsOn,
  }) async {
    final existingRecords = await _allRecords();
    final existing = existingRecords
        .where((record) => record.clientMutationId == clientMutationId)
        .toList(growable: false);
    if (existing.length == 1) {
      if (existing.single.actorSessionId != actorSessionId) {
        throw StateError('A different local actor owns this mutation id.');
      }
      return existing.single;
    }
    if (existing.length > 1) {
      throw StateError('The sync outbox contains duplicate mutation ids.');
    }
    if (functionName == 'advance_own_driver_load_state_idempotent') {
      final pendingState = _pendingStateTransitionFor(
        existingRecords,
        actorSessionId,
      );
      if (pendingState != null) return pendingState;
    }
    final nextPersistedSequence = existingRecords.fold<int>(
      0,
      (current, record) => max(current, record.sequence + 1),
    );
    _nextSequence = max(_nextSequence, nextPersistedSequence);
    final record = SyncOutboxRecord(
      clientMutationId: clientMutationId,
      actorSessionId: actorSessionId,
      sequence: _nextSequence++,
      functionName: functionName,
      arguments: arguments,
      dependsOn: dependsOn,
      retryState: SyncRetryState.pending,
      attempts: 0,
    );
    await _store.insert(record);
    return record;
  }

  Future<T> _serializeEnqueue<T>(Future<T> Function() operation) {
    final scheduled = _enqueueTail.then((_) => operation());
    _enqueueTail = scheduled.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return scheduled;
  }

  SyncOutboxRecord? _pendingStateTransitionFor(
    List<SyncOutboxRecord> records,
    String actorSessionId,
  ) {
    final pendingState = records
        .where(
          (record) =>
              record.actorSessionId == actorSessionId &&
              record.functionName ==
                  'advance_own_driver_load_state_idempotent' &&
              (record.retryState == SyncRetryState.pending ||
                  record.retryState == SyncRetryState.retryable),
        )
        .toList(growable: false);
    if (pendingState.length > 1) {
      throw StateError('The sync outbox has multiple pending state changes.');
    }
    return pendingState.isEmpty ? null : pendingState.single;
  }

  Future<List<SyncOutboxRecord>> _allRecords() async {
    final records = List<SyncOutboxRecord>.from(await _store.readPending());
    return records
      ..sort((left, right) => left.sequence.compareTo(right.sequence));
  }
}

const Set<String> _evidenceTypes = <String>{
  'photo',
  'receiver_name',
  'signature',
  'bol',
  'pod',
  'reference_number',
  'delivery_timestamp',
  'delivery_gps',
};

final RegExp _uuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
);

bool _containsClientControlledScope(Map<String, Object?> arguments) =>
    arguments.keys.any(
      (key) => const <String>{
        'target_company_id',
        'target_driver_id',
        'target_load_id',
        'target_operational_status',
      }.contains(key),
    );

Map<String, Object?> _recordToJson(SyncOutboxRecord record) =>
    <String, Object?>{
      'clientMutationId': record.clientMutationId,
      'actorSessionId': record.actorSessionId,
      'sequence': record.sequence,
      'functionName': record.functionName,
      'arguments': record.arguments,
      'dependsOn': record.dependsOn,
      'retryState': record.retryState.name,
      'attempts': record.attempts,
    };

SyncOutboxRecord _recordFromJson(Object? value) {
  if (value is! Map) throw const FormatException('Invalid sync outbox record.');
  final retryState = value['retryState'];
  final arguments = value['arguments'];
  final clientMutationId = value['clientMutationId'];
  final actorSessionId = value['actorSessionId'];
  final sequence = value['sequence'];
  final functionName = value['functionName'];
  final dependsOn = value['dependsOn'];
  final attempts = value['attempts'];
  if (clientMutationId is! String ||
      (actorSessionId != null && actorSessionId is! String) ||
      sequence is! int ||
      functionName is! String ||
      arguments is! Map ||
      dependsOn is! String? ||
      attempts is! int ||
      retryState is! String) {
    throw const FormatException('Invalid sync outbox record.');
  }
  final state = SyncRetryState.values.where((item) => item.name == retryState);
  if (state.isEmpty) throw const FormatException('Invalid sync retry state.');
  return SyncOutboxRecord(
    clientMutationId: clientMutationId,
    // An entry written before actor binding is intentionally unreplayable by
    // an authenticated worker. It must never be recontextualized to a later
    // account merely because that account signs in on the same device.
    actorSessionId: actorSessionId ?? _legacyUnboundActorSessionId,
    sequence: sequence,
    functionName: functionName,
    arguments: Map<String, Object?>.from(arguments),
    dependsOn: dependsOn,
    retryState: state.single,
    attempts: attempts,
  );
}

const String _legacyUnboundActorSessionId = '_legacy_unbound_';

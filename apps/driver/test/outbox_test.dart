import 'dart:async';

import 'package:carrierflow_driver/core/sync/outbox.dart';
import 'package:carrierflow_driver/core/sync/sync_worker.dart';
import 'package:flutter_test/flutter_test.dart';

final class _FixedMutationIdFactory implements SyncMutationIdFactory {
  _FixedMutationIdFactory(this._ids);

  final List<String> _ids;

  int get remaining => _ids.length;

  @override
  String create() => _ids.removeAt(0);
}

final class _MemoryOutboxStore implements SyncOutboxStore {
  final List<SyncOutboxRecord> records = <SyncOutboxRecord>[];

  @override
  Future<void> insert(SyncOutboxRecord record) async {
    records.add(record);
  }

  @override
  Future<List<SyncOutboxRecord>> readPending() async =>
      List<SyncOutboxRecord>.unmodifiable(records);

  @override
  Future<void> replace(SyncOutboxRecord record) async {
    final index = records.indexWhere(
      (candidate) => candidate.clientMutationId == record.clientMutationId,
    );
    records[index] = record;
  }
}

final class _RecordingTransport implements SyncMutationTransport {
  final List<SyncOutboxRecord> sent = <SyncOutboxRecord>[];
  final Map<String, SyncTransportResult> results =
      <String, SyncTransportResult>{};

  @override
  Future<SyncTransportResult> send(SyncOutboxRecord record) async {
    sent.add(record);
    return results[record.clientMutationId] ?? const SyncTransportSucceeded();
  }
}

final class _AccountSwitchingTransport implements SyncMutationTransport {
  _AccountSwitchingTransport(this._onSend);

  final void Function() _onSend;
  final List<SyncOutboxRecord> sent = <SyncOutboxRecord>[];

  @override
  Future<SyncTransportResult> send(SyncOutboxRecord record) async {
    sent.add(record);
    _onSend();
    return const SyncTransportSucceeded();
  }
}

final class _SwitchableActor {
  _SwitchableActor(this.value);

  String? value;
}

final class _ContendedSyncOutboxStore implements SyncOutboxStore {
  final List<SyncOutboxRecord> records = <SyncOutboxRecord>[];
  var activeInserts = 0;
  var maxConcurrentInserts = 0;

  @override
  Future<void> insert(SyncOutboxRecord record) async {
    activeInserts += 1;
    maxConcurrentInserts = maxConcurrentInserts < activeInserts
        ? activeInserts
        : maxConcurrentInserts;
    await Future<void>.delayed(Duration.zero);
    records.add(record);
    activeInserts -= 1;
  }

  @override
  Future<List<SyncOutboxRecord>> readPending() async =>
      List<SyncOutboxRecord>.from(records);

  @override
  Future<void> replace(SyncOutboxRecord record) async {
    final index = records.indexWhere(
      (candidate) => candidate.clientMutationId == record.clientMutationId,
    );
    records[index] = record;
  }
}

final class _ContendedSecureValueStore implements SyncOutboxSecureValueStore {
  String? value;
  final Completer<void> _releaseReads = Completer<void>();
  var reads = 0;

  @override
  Future<String?> read({required String key}) async {
    final snapshot = value;
    reads += 1;
    if (reads == 1) Timer.run(_releaseReads.complete);
    await _releaseReads.future;
    return snapshot;
  }

  @override
  Future<void> write({required String key, required String value}) async {
    this.value = value;
  }
}

void main() {
  group('durable driver outbox', () {
    test('persists zero-scope state and evidence records with unique IDs before any network send', () async {
      final store = _MemoryOutboxStore();
      final outbox = DriverSyncOutbox(
        store: store,
        mutationIdFactory: _FixedMutationIdFactory(<String>[
          '11111111-1111-4111-8111-111111111111',
          '22222222-2222-4222-8222-222222222222',
        ]),
      );
      final transport = _RecordingTransport();

      final state = await outbox.enqueueStateTransition(
        actorSessionId: 'driver-a',
      );
      final evidence = await outbox.enqueueEvidence(
        actorSessionId: 'driver-a',
        evidenceType: 'signature',
        evidenceContent: const <String, Object?>{'value': 'Receiver name'},
        dependsOn: state.clientMutationId,
      );

      expect(transport.sent, isEmpty);
      expect(store.records, hasLength(2));
      expect(state.clientMutationId, '11111111-1111-4111-8111-111111111111');
      expect(evidence.clientMutationId, '22222222-2222-4222-8222-222222222222');
      expect(state.functionName, 'advance_own_driver_load_state_idempotent');
      expect(state.actorSessionId, 'driver-a');
      expect(state.arguments, <String, Object?>{
        'client_mutation_id': state.clientMutationId,
      });
      expect(evidence.functionName, 'record_own_driver_load_evidence_idempotent');
      expect(evidence.arguments, <String, Object?>{
        'client_mutation_id': evidence.clientMutationId,
        'evidence_type_value': 'signature',
        'evidence_content': <String, Object?>{'value': 'Receiver name'},
      });
      expect(
        <String>[...state.arguments.keys, ...evidence.arguments.keys],
        isNot(containsAll(<String>[
          'target_company_id',
          'target_driver_id',
          'target_load_id',
          'target_operational_status',
          'actor_session_id',
        ])),
      );

      await SyncWorker(
        outbox: outbox,
        transport: transport,
        currentActorId: () => 'driver-a',
      ).flush();

      expect(
        transport.sent.map((record) => record.clientMutationId),
        <String>[state.clientMutationId, evidence.clientMutationId],
      );
    });

    test('retains transiently failed work for retry and blocks dependent work until it succeeds', () async {
      final store = _MemoryOutboxStore();
      final outbox = DriverSyncOutbox(
        store: store,
        mutationIdFactory: _FixedMutationIdFactory(<String>[
          '33333333-3333-4333-8333-333333333333',
          '44444444-4444-4444-8444-444444444444',
        ]),
      );
      final state = await outbox.enqueueStateTransition(
        actorSessionId: 'driver-a',
      );
      final evidence = await outbox.enqueueEvidence(
        actorSessionId: 'driver-a',
        evidenceType: 'pod',
        evidenceContent: const <String, Object?>{
          'receiptKey': 'pod-receipt',
          'mimeType': 'application/pdf',
          'byteLength': 512,
        },
        dependsOn: state.clientMutationId,
      );
      final transport = _RecordingTransport()
        ..results[state.clientMutationId] = const SyncTransportTransientFailure();
      final worker = SyncWorker(
        outbox: outbox,
        transport: transport,
        currentActorId: () => 'driver-a',
      );

      final firstFlush = await worker.flush();

      expect(firstFlush.transientFailures, 1);
      expect(firstFlush.sent, 0);
      expect(transport.sent.map((record) => record.clientMutationId), <String>[
        state.clientMutationId,
      ]);
      expect(
        (await outbox.pending()).singleWhere(
          (record) => record.clientMutationId == state.clientMutationId,
        ).retryState,
        SyncRetryState.retryable,
      );

      transport.results[state.clientMutationId] = const SyncTransportSucceeded();
      final secondFlush = await worker.flush();

      expect(secondFlush.sent, 2);
      expect(transport.sent.map((record) => record.clientMutationId), <String>[
        state.clientMutationId,
        state.clientMutationId,
        evidence.clientMutationId,
      ]);
      expect(await outbox.pending(), isEmpty);
    });

    test('continues its durable sequence after an app restart', () async {
      final store = _MemoryOutboxStore();
      final firstOutbox = DriverSyncOutbox(
        store: store,
        mutationIdFactory: _FixedMutationIdFactory(<String>[
          '55555555-5555-4555-8555-555555555555',
        ]),
      );
      final first = await firstOutbox.enqueueStateTransition(
        actorSessionId: 'driver-a',
      );
      final restartedOutbox = DriverSyncOutbox(
        store: store,
        mutationIdFactory: _FixedMutationIdFactory(<String>[
          '66666666-6666-4666-8666-666666666666',
        ]),
      );

      final second = await restartedOutbox.enqueueEvidence(
        actorSessionId: 'driver-a',
        evidenceType: 'signature',
        evidenceContent: const <String, Object?>{'value': 'Receiver name'},
      );

      expect(first.sequence, 0);
      expect(second.sequence, 1);
    });

    test('reuses a pending state transition without allocating another mutation id', () async {
      final ids = _FixedMutationIdFactory(<String>[
        '67676767-6767-4767-8767-676767676767',
        '68686868-6868-4868-8868-686868686868',
      ]);
      final outbox = DriverSyncOutbox(
        store: _MemoryOutboxStore(),
        mutationIdFactory: ids,
      );

      final first = await outbox.enqueueStateTransition(actorSessionId: 'driver-a');
      final second = await outbox.enqueueStateTransition(
        actorSessionId: 'driver-a',
      );

      expect(second.clientMutationId, first.clientMutationId);
      expect(ids.remaining, 1);
    });

    test(
      'does not replay a persisted mutation after the device switches accounts',
      () async {
        final store = _MemoryOutboxStore();
        final outbox = DriverSyncOutbox(
          store: store,
          mutationIdFactory: _FixedMutationIdFactory(<String>[
            '77777777-7777-4777-8777-777777777777',
          ]),
        );
        await outbox.enqueueStateTransition(actorSessionId: 'driver-a');
        final actor = _SwitchableActor('driver-b');
        final transport = _RecordingTransport();

        final worker = SyncWorker(
          outbox: outbox,
          transport: transport,
          currentActorId: () => actor.value,
        );
        await worker.flush();

        expect(transport.sent, isEmpty);
        expect(
          (await outbox.pending()).single.retryState,
          SyncRetryState.pending,
        );

        actor.value = 'driver-a';
        await worker.flush();
        expect(transport.sent, hasLength(1));
        expect(await outbox.pending(), isEmpty);
      },
    );

    test(
      'does not confirm an operation when the account changes during its RPC',
      () async {
        final store = _MemoryOutboxStore();
        final outbox = DriverSyncOutbox(
          store: store,
          mutationIdFactory: _FixedMutationIdFactory(<String>[
            '88888888-8888-4888-8888-888888888888',
          ]),
        );
        await outbox.enqueueStateTransition(actorSessionId: 'driver-a');
        final actor = _SwitchableActor('driver-a');
        final transport = _AccountSwitchingTransport(
          () => actor.value = 'driver-b',
        );

        final report = await SyncWorker(
          outbox: outbox,
          transport: transport,
          currentActorId: () => actor.value,
        ).flush();

        expect(transport.sent, hasLength(1));
        expect(report.sent, 0);
        expect(
          (await outbox.pending()).single.retryState,
          SyncRetryState.pending,
        );
      },
    );

    test('serializes concurrent outbox allocation and insertion', () async {
      final store = _ContendedSyncOutboxStore();
      final outbox = DriverSyncOutbox(
        store: store,
        mutationIdFactory: _FixedMutationIdFactory(<String>[
          '12121212-1212-4212-8212-121212121212',
          '13131313-1313-4313-8313-131313131313',
        ]),
      );

      final records = await Future.wait(<Future<SyncOutboxRecord>>[
        outbox.enqueueStateTransition(actorSessionId: 'driver-a'),
        outbox.enqueueEvidence(
          actorSessionId: 'driver-a',
          evidenceType: 'signature',
          evidenceContent: const <String, Object?>{'value': 'Receiver'},
        ),
      ]);

      expect(store.maxConcurrentInserts, 1);
      expect(store.records.map((record) => record.clientMutationId), <String>[
        '12121212-1212-4212-8212-121212121212',
        '13131313-1313-4313-8313-131313131313',
      ]);
      expect(records.map((record) => record.sequence), <int>[0, 1]);
    });

    test('serializes secure encrypted read-modify-write operations', () async {
      final secureValues = _ContendedSecureValueStore();
      final store = SecureSyncOutboxStore(storage: secureValues);
      final first = SyncOutboxRecord(
        clientMutationId: '14141414-1414-4414-8414-141414141414',
        actorSessionId: 'driver-a',
        sequence: 0,
        functionName: 'advance_own_driver_load_state_idempotent',
        arguments: const <String, Object?>{
          'client_mutation_id': '14141414-1414-4414-8414-141414141414',
        },
        retryState: SyncRetryState.pending,
        attempts: 0,
      );
      final second = SyncOutboxRecord(
        clientMutationId: '15151515-1515-4515-8515-151515151515',
        actorSessionId: 'driver-a',
        sequence: 1,
        functionName: 'advance_own_driver_load_state_idempotent',
        arguments: const <String, Object?>{
          'client_mutation_id': '15151515-1515-4515-8515-151515151515',
        },
        retryState: SyncRetryState.pending,
        attempts: 0,
      );

      final writes = Future.wait(<Future<void>>[
        store.insert(first),
        store.insert(second),
      ]);
      await writes;

      expect(
        (await store.readPending()).map((record) => record.clientMutationId),
        <String>[first.clientMutationId, second.clientMutationId],
      );
    });
  });
}

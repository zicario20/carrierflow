import 'dart:async';

import 'package:carrierflow_driver/core/bootstrap/driver_execution_repository.dart';
import 'package:carrierflow_driver/core/sync/outbox.dart';
import 'package:carrierflow_driver/core/sync/sync_lifecycle.dart';
import 'package:carrierflow_driver/core/sync/sync_worker.dart';
import 'package:carrierflow_driver/core/localization/driver_localizations.dart';
import 'package:carrierflow_driver/features/evidence/evidence_capture.dart';
import 'package:carrierflow_driver/features/loads/driver_load_status.dart';
import 'package:carrierflow_driver/features/loads/load_detail_page.dart';
import 'package:carrierflow_driver/features/loads/load_state_controller.dart';
import 'package:carrierflow_driver/features/tracking/tracking_authorization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _RecordedRpcCall {
  const _RecordedRpcCall(this.name, this.arguments);

  final String name;
  final Map<String, dynamic> arguments;
}

class _FakeDriverExecutionRpcGateway implements DriverExecutionRpcGateway {
  _FakeDriverExecutionRpcGateway({this.currentUserId = 'driver-session-user'});

  @override
  String? currentUserId;
  final calls = <_RecordedRpcCall>[];
  final responses = <String, Object?>{};
  final errors = <String, Object?>{};
  void Function(String functionName)? onInvoke;
  Future<void> Function(String functionName)? beforeResponse;

  @override
  Future<Object?> invoke(
    String functionName, {
    Map<String, dynamic> arguments = const <String, dynamic>{},
  }) async {
    calls.add(
      _RecordedRpcCall(functionName, Map<String, dynamic>.from(arguments)),
    );
    onInvoke?.call(functionName);
    await beforeResponse?.call(functionName);
    final error = errors[functionName];
    if (error != null) throw error;
    return responses[functionName];
  }
}

final class _MemoryOutboxStore implements SyncOutboxStore {
  final List<SyncOutboxRecord> records = <SyncOutboxRecord>[];

  @override
  Future<void> insert(SyncOutboxRecord record) async => records.add(record);

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

final class _OfflineNetworkAvailability implements SyncNetworkAvailability {
  const _OfflineNetworkAvailability();

  @override
  Future<bool> get isAvailable async => false;
}

final class _OnlineNetworkAvailability implements SyncNetworkAvailability {
  const _OnlineNetworkAvailability();

  @override
  Future<bool> get isAvailable async => true;
}

final class _ToggleNetworkAvailability implements SyncNetworkAvailability {
  _ToggleNetworkAvailability(this.isOnline);

  bool isOnline;

  @override
  Future<bool> get isAvailable async => isOnline;
}

final class _TestConnectivityEvents implements SyncConnectivityEvents {
  final StreamController<bool> _controller = StreamController<bool>();

  @override
  Stream<bool> get availabilityChanges => _controller.stream;

  void emit(bool available) => _controller.add(available);

  Future<void> dispose() => _controller.close();
}

SupabaseDriverExecutionRepository _repository(
  _FakeDriverExecutionRpcGateway gateway,
) => SupabaseDriverExecutionRepository(
  gateway,
  outbox: DriverSyncOutbox(store: _MemoryOutboxStore()),
  networkAvailability: const _OnlineNetworkAvailability(),
);

const _homeRows = <Object?>[
  <String, Object?>{
    'loadId': '22222222-2222-2222-2222-222222222222',
    'loadNumber': 'CF-102',
    'pickupLabel': 'Dallas, TX',
    'deliveryLabel': 'Houston, TX',
    'operationalStatus': 'assigned',
  },
  <String, Object?>{
    'loadId': '11111111-1111-1111-1111-111111111111',
    'loadNumber': 'CF-101',
    'pickupLabel': 'Austin, TX',
    'deliveryLabel': 'Dallas, TX',
    'operationalStatus': 'en_route_to_pickup',
  },
];

Map<String, Object?> _executionSnapshot({
  String status = 'unloading',
  String? nextStatus = 'delivered',
  List<Object?> requiredEvidence = const <Object?>['signature'],
  List<Object?> recordedEvidence = const <Object?>[],
}) => <String, Object?>{
  'loadId': '11111111-1111-1111-1111-111111111111',
  'loadNumber': 'CF-101',
  'pickupLabel': 'Austin, TX',
  'deliveryLabel': 'Dallas, TX',
  'operationalStatus': status,
  'serverDefinedNextStatus': nextStatus,
  'requiredDeliveryEvidence': requiredEvidence,
  'recordedEvidence': recordedEvidence,
};

void main() {
  group('server-authoritative driver execution repository', () {
    test(
      'maps only server-derived own loads and never sends a driver scope',
      () async {
        final gateway = _FakeDriverExecutionRpcGateway()
          ..responses['get_own_driver_assigned_loads'] = _homeRows;
        final repository = _repository(gateway);

        final snapshot = await repository.fetchOwnAssignedLoads();

        expect(snapshot.currentLoad?.loadNumber, 'CF-101');
        expect(snapshot.nextLoad?.loadNumber, 'CF-102');
        expect(gateway.calls, hasLength(1));
        expect(gateway.calls.single.name, 'get_own_driver_assigned_loads');
        expect(gateway.calls.single.arguments, isEmpty);
      },
    );

    test(
      'reads only a zero-scope server-derived tracking eligibility context',
      () async {
        final gateway = _FakeDriverExecutionRpcGateway()
          ..responses['get_own_driver_tracking_context'] =
              <String, Object?>{
                'isOnDuty': true,
                'hasActiveLoad': false,
              };
        final repository = _repository(gateway);

        final context = await repository.fetchOwnDriverTrackingContext();

        expect(
          context,
          const AuthorizedDriverTrackingContext(
            isOnDuty: true,
            hasActiveLoad: false,
          ),
        );
        expect(gateway.calls, hasLength(1));
        expect(gateway.calls.single.name, 'get_own_driver_tracking_context');
        expect(gateway.calls.single.arguments, isEmpty);
      },
    );

    test(
      'fails closed when the session changes while a response is pending',
      () async {
        final gateway = _FakeDriverExecutionRpcGateway(currentUserId: null)
          ..responses['get_own_driver_assigned_loads'] = _homeRows;
        final repository = _repository(gateway);

        expect(await repository.fetchOwnAssignedLoads(), isA<Object>());
        expect((await repository.fetchOwnAssignedLoads()).isEmpty, isTrue);
        expect(gateway.calls, isEmpty);
      },
    );

    test(
      'next transition calls a zero-scope RPC and refreshes the snapshot',
      () async {
        final gateway = _FakeDriverExecutionRpcGateway()
          ..responses['get_own_driver_execution_snapshot'] =
              _executionSnapshot();
        final repository = _repository(gateway);
        final snapshot = await repository.fetchOwnCurrentLoadExecution();
        expect(snapshot, isNotNull);

        gateway.responses['advance_own_driver_load_state_idempotent'] = <String, Object?>{
          'operational_status': 'delivered',
        };
        gateway.responses['get_own_driver_execution_snapshot'] =
            _executionSnapshot(
              status: 'delivered',
              nextStatus: null,
              recordedEvidence: const <Object?>[
                <String, Object?>{
                  'type': 'signature',
                  'recordedAt': '2026-08-28T12:00:00Z',
                },
              ],
            );

        final result = await snapshot!.actions
            .requestServerDefinedNextTransition();

        expect(result, isA<DriverLoadActionUpdated>());
        final advance = gateway.calls.firstWhere(
          (call) => call.name == 'advance_own_driver_load_state_idempotent',
        );
        expect(advance.arguments['client_mutation_id'], isA<String>());
        expect(
          advance.arguments.keys,
          isNot(
            containsAll(<String>[
              'target_company_id',
              'target_driver_id',
              'target_load_id',
              'target_operational_status',
            ]),
          ),
        );
      },
    );

    test(
      'rejects a transition when its initiating session changes after the RPC',
      () async {
        final gateway = _FakeDriverExecutionRpcGateway()
          ..responses['get_own_driver_execution_snapshot'] =
              _executionSnapshot()
          ..responses['advance_own_driver_load_state_idempotent'] = <String, Object?>{
            'operational_status': 'delivered',
          };
        final repository = _repository(gateway);
        final snapshot = await repository.fetchOwnCurrentLoadExecution();
        gateway.onInvoke = (functionName) {
          if (functionName == 'advance_own_driver_load_state_idempotent') {
            gateway.currentUserId = 'different-driver-session';
          }
        };

        final result = await snapshot!.actions
            .requestServerDefinedNextTransition();

        expect(
          result,
          isA<DriverLoadActionRejected>().having(
            (rejected) => rejected.failure,
            'failure',
            DriverExecutionFailure.denied,
          ),
        );
        expect(
          gateway.calls
              .where((call) => call.name == 'get_own_driver_execution_snapshot')
              .length,
          1,
        );
      },
    );

    test(
      'rejects a transition when its initiating session changes during refresh',
      () async {
        var snapshotRequests = 0;
        final gateway = _FakeDriverExecutionRpcGateway()
          ..responses['get_own_driver_execution_snapshot'] =
              _executionSnapshot()
          ..responses['advance_own_driver_load_state_idempotent'] = <String, Object?>{
            'operational_status': 'delivered',
          };
        final repository = _repository(gateway);
        gateway.onInvoke = (functionName) {
          if (functionName != 'get_own_driver_execution_snapshot') return;
          snapshotRequests += 1;
          if (snapshotRequests == 2) {
            gateway.currentUserId = 'different-driver-session';
          }
        };
        final snapshot = await repository.fetchOwnCurrentLoadExecution();

        final result = await snapshot!.actions
            .requestServerDefinedNextTransition();

        expect(
          result,
          isA<DriverLoadActionRejected>().having(
            (rejected) => rejected.failure,
            'failure',
            DriverExecutionFailure.denied,
          ),
        );
      },
    );

    test(
      'records scalar evidence through the own-load RPC without a target scope',
      () async {
        final gateway = _FakeDriverExecutionRpcGateway()
          ..responses['get_own_driver_execution_snapshot'] =
              _executionSnapshot();
        final repository = _repository(gateway);
        final snapshot = await repository.fetchOwnCurrentLoadExecution();
        gateway.responses['record_own_driver_load_evidence_idempotent'] =
            <String, Object?>{'id': 'evidence-id'};
        gateway.responses['get_own_driver_execution_snapshot'] =
            _executionSnapshot(
              recordedEvidence: const <Object?>[
                <String, Object?>{
                  'type': 'signature',
                  'recordedAt': '2026-08-28T12:00:00Z',
                },
              ],
            );

        await snapshot!.actions.recordEvidence(
          DriverEvidenceCapture.textValue(
            receiptId: 'receipt-signature',
            type: DriverEvidenceType.signature,
            capturedAt: DateTime.utc(2026, 8, 28, 12),
            value: 'Receiver signature',
          ),
        );

        final evidence = gateway.calls.firstWhere(
          (call) => call.name == 'record_own_driver_load_evidence_idempotent',
        );
        expect(evidence.arguments['client_mutation_id'], isA<String>());
        expect(evidence.arguments, containsPair('evidence_type_value', 'signature'));
        expect(evidence.arguments, containsPair('evidence_content', <String, Object?>{
          'value': 'Receiver signature',
        }));
        expect(evidence.arguments.keys, isNot(contains('target_company_id')));
        expect(evidence.arguments.keys, isNot(contains('target_load_id')));
      },
    );

    test(
      'sends private evidence as opaque receipt metadata, never a storage URL',
      () async {
        final gateway = _FakeDriverExecutionRpcGateway()
          ..responses['get_own_driver_execution_snapshot'] =
              _executionSnapshot();
        final repository = _repository(gateway);
        final snapshot = await repository.fetchOwnCurrentLoadExecution();
        gateway.responses['record_own_driver_load_evidence_idempotent'] =
            <String, Object?>{'id': 'evidence-id'};

        await snapshot!.actions.recordEvidence(
          DriverEvidenceCapture(
            receiptId: 'receipt-bol',
            type: DriverEvidenceType.billOfLading,
            capturedAt: DateTime.utc(2026, 8, 28, 12),
            summary: 'Private BOL receipt',
            attachment: PrivateEvidenceReference.localReceiptKey('receipt-bol'),
            metadata: const EvidenceCaptureMetadata(
              mimeType: 'application/pdf',
              byteLength: 1024,
            ),
          ),
        );

        final evidence = gateway.calls.firstWhere(
          (call) => call.name == 'record_own_driver_load_evidence_idempotent',
        );
        expect(evidence.arguments['client_mutation_id'], isA<String>());
        expect(evidence.arguments, containsPair('evidence_type_value', 'bol'));
        expect(evidence.arguments, containsPair('evidence_content', <String, Object?>{
            'receiptKey': 'receipt-bol',
            'mimeType': 'application/pdf',
            'byteLength': 1024,
          }));
        expect(evidence.arguments.toString(), isNot(contains('private/')));
        expect(evidence.arguments.toString(), isNot(contains('://')));
      },
    );

    test(
      'accepts a minimal opaque acknowledgement for an idempotent incident',
      () async {
        final gateway = _FakeDriverExecutionRpcGateway()
          ..responses['get_own_driver_execution_snapshot'] =
              _executionSnapshot();
        final repository = _repository(gateway);
        final snapshot = await repository.fetchOwnCurrentLoadExecution();
        gateway.responses['report_own_driver_load_incident_idempotent'] =
            <String, Object?>{
              'clientMutationId': '77777777-7777-4777-8777-777777777777',
            };

        final result = await snapshot!.actions.enqueueIncident(
          DriverIncidentReport(
            clientMutationId: '77777777-7777-4777-8777-777777777777',
            type: DriverIncidentType.customerUnavailable,
            description: 'Receiver asked the driver to wait.',
            location: const DriverIncidentLocation(
              latitude: 41.8781,
              longitude: -87.6298,
            ),
            attachments: const <PrivateEvidenceReference>[],
          ),
        );

        expect(result, isA<DriverIncidentAcknowledged>());
        final incident = gateway.calls.firstWhere(
          (call) => call.name == 'report_own_driver_load_incident_idempotent',
        );
        expect(incident.arguments, <String, Object?>{
          'client_mutation_id': '77777777-7777-4777-8777-777777777777',
          'incident_type_value': 'customer_unavailable',
          'incident_description': 'Receiver asked the driver to wait.',
          'incident_attachments': const <Object?>[],
          'incident_location': <String, double>{
            'latitude': 41.8781,
            'longitude': -87.6298,
          },
        });
        expect(
          incident.arguments.keys,
          isNot(
            containsAll(<String>[
              'target_company_id',
              'target_driver_id',
              'target_load_id',
              'target_operational_status',
            ]),
          ),
        );
      },
    );

    test(
      'persists state, evidence, and incident work before an offline check without invoking a mutation RPC',
      () async {
        final gateway = _FakeDriverExecutionRpcGateway()
          ..responses['get_own_driver_execution_snapshot'] =
              _executionSnapshot();
        final store = _MemoryOutboxStore();
        final repository = SupabaseDriverExecutionRepository(
          gateway,
          outbox: DriverSyncOutbox(store: store),
          networkAvailability: const _OfflineNetworkAvailability(),
        );
        final snapshot = await repository.fetchOwnCurrentLoadExecution();

        final stateResult = await snapshot!.actions
            .requestServerDefinedNextTransition();
        final evidenceResult = await snapshot.actions.recordEvidence(
          DriverEvidenceCapture.textValue(
            receiptId: 'offline-signature',
            type: DriverEvidenceType.signature,
            capturedAt: DateTime.utc(2026, 8, 28, 12),
            value: 'Receiver signature',
          ),
        );
        final incidentResult = await snapshot.actions.enqueueIncident(
          DriverIncidentReport(
            clientMutationId: '99999999-9999-4999-8999-999999999999',
            type: DriverIncidentType.customerUnavailable,
            description: 'The receiver has not arrived.',
            location: null,
            attachments: const <PrivateEvidenceReference>[],
          ),
        );

        expect(
          stateResult,
          isA<DriverLoadActionQueued>().having(
            (result) => result.receipt.clientMutationId,
            'durable state id',
            isNotEmpty,
          ),
        );
        expect(
          evidenceResult,
          isA<DriverLoadActionQueued>().having(
            (result) => result.receipt.clientMutationId,
            'durable evidence id',
            isNotEmpty,
          ),
        );
        expect(
          incidentResult,
          isA<DriverIncidentQueued>().having(
            (result) => result.receipt.clientMutationId,
            'durable incident id',
            '99999999-9999-4999-8999-999999999999',
          ),
        );
        expect(store.records, hasLength(3));
        expect(
          store.records.map((record) => record.actorSessionId),
          everyElement('driver-session-user'),
        );
        expect(
          store.records.expand((record) => record.arguments.keys),
          isNot(contains('actor_session_id')),
        );
        expect(
          gateway.calls.map((call) => call.name),
          <String>['get_own_driver_execution_snapshot'],
        );
      },
    );

    test(
      'keeps an offline transition queued and replays its original mutation id after sync resumes',
      () async {
        final gateway = _FakeDriverExecutionRpcGateway()
          ..responses['get_own_driver_execution_snapshot'] =
              _executionSnapshot();
        final store = _MemoryOutboxStore();
        final network = _ToggleNetworkAvailability(false);
        final repository = SupabaseDriverExecutionRepository(
          gateway,
          outbox: DriverSyncOutbox(store: store),
          networkAvailability: network,
        );
        final snapshot = await repository.fetchOwnCurrentLoadExecution();

        final first = await snapshot!.actions
            .requestServerDefinedNextTransition();
        final second = await snapshot.actions
            .requestServerDefinedNextTransition();

        expect(
          first,
          isA<DriverLoadActionQueued>().having(
            (queued) => queued.receipt.clientMutationId,
            'durable mutation id',
            isA<String>(),
          ),
        );
        final firstQueued = first is DriverLoadActionQueued
            ? first
            : throw StateError('offline operation must remain queued');
        expect(
          second,
          isA<DriverLoadActionQueued>().having(
            (queued) => queued.receipt.clientMutationId,
            'reused mutation id',
            firstQueued.receipt.clientMutationId,
          ),
        );
        expect(store.records, hasLength(1));
        expect(
          gateway.calls.map((call) => call.name),
          <String>['get_own_driver_execution_snapshot'],
        );

        network.isOnline = true;
        await repository.resumePendingSync();

        final replay = gateway.calls.singleWhere(
          (call) => call.name == 'advance_own_driver_load_state_idempotent',
        );
        expect(
          replay.arguments['client_mutation_id'],
          firstQueued.receipt.clientMutationId,
        );
        expect(store.records.single.retryState, SyncRetryState.succeeded);
      },
    );

    test(
      'queues separate required evidence offline without reusing either durable mutation id',
      () async {
        final gateway = _FakeDriverExecutionRpcGateway()
          ..responses['get_own_driver_execution_snapshot'] = _executionSnapshot(
            requiredEvidence: const <Object?>['signature', 'bol'],
          );
        final store = _MemoryOutboxStore();
        final repository = SupabaseDriverExecutionRepository(
          gateway,
          outbox: DriverSyncOutbox(store: store),
          networkAvailability: const _OfflineNetworkAvailability(),
        );
        final snapshot = await repository.fetchOwnCurrentLoadExecution();
        final controller = DriverLoadStateController(snapshot!);
        addTearDown(controller.dispose);

        await controller.recordEvidence(
          DriverEvidenceCapture.textValue(
            receiptId: 'queued-signature',
            type: DriverEvidenceType.signature,
            capturedAt: DateTime.utc(2026, 8, 28, 12),
            value: 'Receiver signature',
          ),
        );
        await controller.recordEvidence(
          DriverEvidenceCapture(
            receiptId: 'queued-bol',
            type: DriverEvidenceType.billOfLading,
            capturedAt: DateTime.utc(2026, 8, 28, 12, 1),
            summary: 'Private BOL receipt',
            attachment: PrivateEvidenceReference.localReceiptKey('queued-bol'),
            metadata: const EvidenceCaptureMetadata(
              mimeType: 'application/pdf',
              byteLength: 1024,
            ),
          ),
        );
        await controller.recordEvidence(
          DriverEvidenceCapture.textValue(
            receiptId: 'queued-signature-duplicate',
            type: DriverEvidenceType.signature,
            capturedAt: DateTime.utc(2026, 8, 28, 12, 2),
            value: 'Duplicate signature',
          ),
        );

        expect(store.records, hasLength(2));
        expect(
          store.records.map((record) => record.sequence),
          <int>[0, 1],
        );
        expect(
          store.records.map((record) => record.arguments['evidence_type_value']),
          <Object?>['signature', 'bol'],
        );
        expect(
          controller.queuedEvidenceFor(DriverEvidenceType.signature)
              ?.clientMutationId,
          store.records[0].clientMutationId,
        );
        expect(
          controller.queuedEvidenceFor(DriverEvidenceType.billOfLading)
              ?.clientMutationId,
          store.records[1].clientMutationId,
        );
        expect(store.records[0].clientMutationId, isNot(store.records[1].clientMutationId));
      },
    );

    testWidgets(
      'reconciles the displayed queued action only after a lifecycle replay receives a server response',
      (tester) async {
        final gateway = _FakeDriverExecutionRpcGateway()
          ..responses['get_own_driver_execution_snapshot'] = _executionSnapshot(
            status: 'en_route_to_pickup',
            nextStatus: 'arrived_pickup',
            requiredEvidence: const <Object?>[],
          );
        final store = _MemoryOutboxStore();
        final network = _ToggleNetworkAvailability(false);
        final repository = SupabaseDriverExecutionRepository(
          gateway,
          outbox: DriverSyncOutbox(store: store),
          networkAvailability: network,
        );
        final initial = await repository.fetchOwnCurrentLoadExecution();
        final controller = DriverLoadStateController(initial!);
        final reconciler = DriverLoadStateSyncReconciler(
          repository,
          currentActorId: () => gateway.currentUserId,
        )..attach(controller, actorSessionId: 'driver-session-user');
        final connectivity = _TestConnectivityEvents();
        final lifecycle = DriverSyncLifecycleCoordinator(
          resumer: repository,
          connectivityEvents: connectivity,
          onSuccessfulReplay: reconciler.reconcile,
        );
        addTearDown(() async {
          lifecycle.dispose();
          await connectivity.dispose();
          controller.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
              DriverStrings.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: LoadDetailPage(snapshot: initial, controller: controller),
          ),
        );
        await tester.pumpAndSettle();

        await tester.ensureVisible(
          find.byKey(LoadDetailPage.advanceButtonKey),
        );
        await tester.tap(find.byKey(LoadDetailPage.advanceButtonKey));
        await tester.pumpAndSettle();
        final queuedId = controller.queuedAction?.clientMutationId;
        expect(queuedId, isNotNull);
        expect(find.text('Update queued. CarrierFlow will sync it after service connection is restored.'), findsOneWidget);
        expect(
          tester.widget<FilledButton>(find.byKey(LoadDetailPage.advanceButtonKey)).onPressed,
          isNull,
        );
        expect(
          gateway.calls.where((call) => call.name == 'advance_own_driver_load_state_idempotent'),
          isEmpty,
        );

        gateway.responses['advance_own_driver_load_state_idempotent'] =
            <String, Object?>{'operational_status': 'arrived_pickup'};
        gateway.responses['get_own_driver_execution_snapshot'] = _executionSnapshot(
          status: 'arrived_pickup',
          nextStatus: 'loading',
          requiredEvidence: const <Object?>[],
        );
        network.isOnline = true;
        connectivity.emit(false);
        await tester.pump();
        connectivity.emit(true);
        await tester.pumpAndSettle();

        expect(
          gateway.calls.singleWhere(
            (call) => call.name == 'advance_own_driver_load_state_idempotent',
          ).arguments['client_mutation_id'],
          queuedId,
        );
        expect(controller.queuedAction, isNull);
        expect(
          controller.snapshot.operationalStatus,
          DriverLoadOperationalStatus.arrivedPickup,
        );
        expect(
          tester.widget<FilledButton>(find.byKey(LoadDetailPage.advanceButtonKey)).onPressed,
          isNotNull,
        );
        expect(find.text('Update queued. CarrierFlow will sync it after service connection is restored.'), findsNothing);
      },
    );

    testWidgets(
      'renders an authoritative delivered terminal result when offline unloading replays after its active snapshot is gone',
      (tester) async {
        final gateway = _FakeDriverExecutionRpcGateway()
          ..responses['get_own_driver_execution_snapshot'] = _executionSnapshot(
            status: 'unloading',
            nextStatus: 'delivered',
            requiredEvidence: const <Object?>[],
          );
        final store = _MemoryOutboxStore();
        final network = _ToggleNetworkAvailability(false);
        final repository = SupabaseDriverExecutionRepository(
          gateway,
          outbox: DriverSyncOutbox(store: store),
          networkAvailability: network,
        );
        final initial = await repository.fetchOwnCurrentLoadExecution();
        final controller = DriverLoadStateController(initial!);
        final reconciler = DriverLoadStateSyncReconciler(
          repository,
          currentActorId: () => gateway.currentUserId,
        )..attach(controller, actorSessionId: 'driver-session-user');
        final connectivity = _TestConnectivityEvents();
        final lifecycle = DriverSyncLifecycleCoordinator(
          resumer: repository,
          connectivityEvents: connectivity,
          onSuccessfulReplay: reconciler.reconcile,
        );
        addTearDown(() async {
          lifecycle.dispose();
          await connectivity.dispose();
          controller.dispose();
        });

        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
              DriverStrings.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: LoadDetailPage(snapshot: initial, controller: controller),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(LoadDetailPage.advanceButtonKey),
        );
        await tester.tap(find.byKey(LoadDetailPage.advanceButtonKey));
        await tester.pumpAndSettle();
        final queuedId = controller.queuedAction?.clientMutationId;
        expect(queuedId, isNotNull);

        gateway.responses['advance_own_driver_load_state_idempotent'] =
            <String, Object?>{'operationalStatus': 'delivered'};
        gateway.errors['get_own_driver_execution_snapshot'] =
            const PostgrestException(
              message: 'no active assigned load is available for this driver',
              code: '42501',
            );
        network.isOnline = true;
        connectivity.emit(false);
        await tester.pump();
        connectivity.emit(true);
        await tester.pumpAndSettle();

        expect(
          gateway.calls.singleWhere(
            (call) => call.name == 'advance_own_driver_load_state_idempotent',
          ).arguments['client_mutation_id'],
          queuedId,
        );
        expect(controller.queuedAction, isNull);
        expect(
          controller.terminalStatus,
          DriverLoadOperationalStatus.delivered,
        );
        expect(
          find.text('Delivery confirmed. This load is no longer active.'),
          findsOneWidget,
        );
        expect(find.byKey(LoadDetailPage.advanceButtonKey), findsNothing);
        expect(find.text('Update queued. CarrierFlow will sync it after service connection is restored.'), findsNothing);
      },
    );

    test(
      'returns an acknowledged delivered terminal result for an immediate online transition with no active snapshot',
      () async {
        final gateway = _FakeDriverExecutionRpcGateway()
          ..responses['get_own_driver_execution_snapshot'] = _executionSnapshot(
            status: 'unloading',
            nextStatus: 'delivered',
            requiredEvidence: const <Object?>[],
          );
        final repository = SupabaseDriverExecutionRepository(
          gateway,
          outbox: DriverSyncOutbox(store: _MemoryOutboxStore()),
          networkAvailability: const _OnlineNetworkAvailability(),
        );
        final initial = await repository.fetchOwnCurrentLoadExecution();
        final controller = DriverLoadStateController(initial!);
        addTearDown(controller.dispose);
        gateway.responses['advance_own_driver_load_state_idempotent'] =
            <String, Object?>{'operationalStatus': 'delivered'};
        gateway.errors['get_own_driver_execution_snapshot'] =
            const PostgrestException(
              message: 'no active assigned load is available for this driver',
              code: '42501',
            );

        await controller.advanceServerDefinedStep();

        expect(controller.terminalStatus, DriverLoadOperationalStatus.delivered);
        expect(controller.queuedAction, isNull);
        expect(
          controller.snapshot.operationalStatus,
          DriverLoadOperationalStatus.unloading,
          reason: 'the terminal view must not fabricate a mutable snapshot',
        );
      },
    );

    test(
      'serializes concurrent immediate action and lifecycle flushes for one durable mutation id',
      () async {
        final gateway = _FakeDriverExecutionRpcGateway()
          ..responses['get_own_driver_execution_snapshot'] = _executionSnapshot(
            status: 'en_route_to_pickup',
            nextStatus: 'arrived_pickup',
            requiredEvidence: const <Object?>[],
          );
        final rpcStarted = Completer<void>();
        final releaseRpc = Completer<void>();
        gateway.beforeResponse = (functionName) async {
          if (functionName == 'advance_own_driver_load_state_idempotent') {
            if (!rpcStarted.isCompleted) rpcStarted.complete();
            await releaseRpc.future;
          }
        };
        final repository = SupabaseDriverExecutionRepository(
          gateway,
          outbox: DriverSyncOutbox(store: _MemoryOutboxStore()),
          networkAvailability: const _OnlineNetworkAvailability(),
        );
        final initial = await repository.fetchOwnCurrentLoadExecution();
        gateway.responses['advance_own_driver_load_state_idempotent'] =
            <String, Object?>{'operationalStatus': 'arrived_pickup'};
        gateway.responses['get_own_driver_execution_snapshot'] = _executionSnapshot(
          status: 'arrived_pickup',
          nextStatus: 'loading',
          requiredEvidence: const <Object?>[],
        );

        final action = initial!.actions.requestServerDefinedNextTransition();
        await rpcStarted.future;
        final resumed = repository.resumePendingSync();
        releaseRpc.complete();
        await Future.wait(<Future<Object?>>[action, resumed]);

        final mutations = gateway.calls
            .where(
              (call) => call.name == 'advance_own_driver_load_state_idempotent',
            )
            .toList(growable: false);
        expect(mutations, hasLength(1));
        expect(mutations.single.arguments['client_mutation_id'], isNotNull);
      },
    );

    test(
      'does not reconcile an A controller after a direct session switch to B',
      () async {
        final gateway = _FakeDriverExecutionRpcGateway()
          ..responses['get_own_driver_execution_snapshot'] = _executionSnapshot(
            status: 'en_route_to_pickup',
            nextStatus: 'arrived_pickup',
            requiredEvidence: const <Object?>[],
          );
        final repository = SupabaseDriverExecutionRepository(
          gateway,
          outbox: DriverSyncOutbox(store: _MemoryOutboxStore()),
          networkAvailability: const _OfflineNetworkAvailability(),
        );
        final initial = await repository.fetchOwnCurrentLoadExecution();
        final controller = DriverLoadStateController(initial!);
        addTearDown(controller.dispose);
        await controller.advanceServerDefinedStep();
        final queuedId = controller.queuedAction!.clientMutationId;
        var activeUserId = 'driver-session-a';
        final reconciler = DriverLoadStateSyncReconciler(
          repository,
          currentActorId: () => activeUserId,
        )..attach(controller, actorSessionId: 'driver-session-a');

        activeUserId = 'driver-session-b';
        await reconciler.reconcile(
          SyncFlushReport(
            sent: 1,
            transientFailures: 0,
            blocked: 0,
            succeededMutationIds: <String>[queuedId],
            succeededMutations: <SyncMutationAcknowledgement>[
              SyncMutationAcknowledgement(
                clientMutationId: queuedId,
                operationalStatus: 'arrived_pickup',
              ),
            ],
          ),
        );

        expect(controller.queuedAction?.clientMutationId, queuedId);
        expect(
          controller.snapshot.operationalStatus,
          DriverLoadOperationalStatus.enRouteToPickup,
        );
      },
    );

    test(
      'blocks only permanent authorization, validation, and constraint RPC errors',
      () async {
        final gateway = _FakeDriverExecutionRpcGateway()
          ..errors['advance_own_driver_load_state_idempotent'] =
              const PostgrestException(
                message: 'permission denied',
                code: '42501',
              );
        final transport = GatewaySyncMutationTransport(gateway);
        final record = SyncOutboxRecord(
          clientMutationId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          actorSessionId: 'driver-session-user',
          sequence: 0,
          functionName: 'advance_own_driver_load_state_idempotent',
          arguments: const <String, Object?>{
            'client_mutation_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          },
          retryState: SyncRetryState.pending,
          attempts: 0,
        );

        for (final code in <String>['42501', '22023', '22P02', '23514']) {
          gateway.errors['advance_own_driver_load_state_idempotent'] =
              PostgrestException(message: 'permanent client failure', code: code);
          expect(await transport.send(record), isA<SyncTransportBlocked>());
        }
      },
    );

    test(
      'keeps PostgREST 5xx and unknown transport errors retryable',
      () async {
        final gateway = _FakeDriverExecutionRpcGateway()
          ..errors['advance_own_driver_load_state_idempotent'] =
              const PostgrestException(message: 'gateway failed', code: '502');
        final transport = GatewaySyncMutationTransport(gateway);
        final record = SyncOutboxRecord(
          clientMutationId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
          actorSessionId: 'driver-session-user',
          sequence: 0,
          functionName: 'advance_own_driver_load_state_idempotent',
          arguments: const <String, Object?>{
            'client_mutation_id': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
          },
          retryState: SyncRetryState.pending,
          attempts: 0,
        );

        expect(await transport.send(record), isA<SyncTransportTransientFailure>());

        gateway.errors['advance_own_driver_load_state_idempotent'] =
            StateError('network socket closed');
        expect(await transport.send(record), isA<SyncTransportTransientFailure>());
      },
    );

    test(
      'rejects an incident when its initiating session changes after RPC',
      () async {
        final gateway = _FakeDriverExecutionRpcGateway()
          ..responses['get_own_driver_execution_snapshot'] =
              _executionSnapshot()
          ..responses['report_own_driver_load_incident_idempotent'] =
              <String, Object?>{
                'clientMutationId': '55555555-5555-4555-8555-555555555555',
              };
        final repository = _repository(gateway);
        final snapshot = await repository.fetchOwnCurrentLoadExecution();
        gateway.onInvoke = (functionName) {
          if (functionName == 'report_own_driver_load_incident_idempotent') {
            gateway.currentUserId = null;
          }
        };

        final result = await snapshot!.actions.enqueueIncident(
          DriverIncidentReport(
            clientMutationId: '55555555-5555-4555-8555-555555555555',
            type: DriverIncidentType.customerUnavailable,
            description: 'The receiver has not arrived.',
            location: null,
            attachments: <PrivateEvidenceReference>[],
          ),
        );

        expect(
          result,
          isA<DriverIncidentQueueRejected>().having(
            (rejected) => rejected.failure,
            'failure',
            DriverExecutionFailure.denied,
          ),
        );
      },
    );
  });
}

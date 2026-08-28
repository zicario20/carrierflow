import 'package:carrierflow_driver/features/auth/auth_gate.dart';
import 'package:carrierflow_driver/features/evidence/evidence_capture.dart';
import 'package:carrierflow_driver/features/loads/load_home_page.dart';
import 'package:carrierflow_driver/features/loads/load_state_controller.dart';
import 'package:carrierflow_driver/features/tracking/tracking_authorization.dart';
import 'package:carrierflow_driver/core/sync/outbox.dart';
import 'package:carrierflow_driver/core/sync/sync_lifecycle.dart';
import 'package:carrierflow_driver/core/sync/sync_worker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Narrow RPC boundary for the driver app. Its public methods deliberately do
/// not accept a company, driver, load, or operational status identifier.
abstract interface class DriverExecutionRpcGateway {
  String? get currentUserId;

  Future<Object?> invoke(
    String functionName, {
    Map<String, dynamic> arguments = const <String, dynamic>{},
  });
}

/// The production gateway uses only the session-backed public Supabase client.
/// It has no direct table DML and never owns a service-role credential.
final class SupabaseDriverExecutionRpcGateway
    implements DriverExecutionRpcGateway {
  SupabaseDriverExecutionRpcGateway(this._client);

  final SupabaseClient _client;

  @override
  String? get currentUserId => _client.auth.currentUser?.id;

  @override
  Future<Object?> invoke(
    String functionName, {
    Map<String, dynamic> arguments = const <String, dynamic>{},
  }) => _client.rpc(functionName, params: arguments);
}

SyncWorker _createDriverSyncWorker({
  required DriverSyncOutbox outbox,
  required SyncNetworkAvailability networkAvailability,
  required DriverExecutionRpcGateway gateway,
}) => SyncWorker(
  outbox: outbox,
  networkAvailability: networkAvailability,
  transport: GatewaySyncMutationTransport(gateway),
  currentActorId: () => gateway.currentUserId,
);

/// Maps only zero-scope server RPC responses to driver-visible models. The
/// database derives the effective tenant, driver and active assignment from
/// auth.uid(); a response that cannot be typed is discarded fail-closed.
final class SupabaseDriverExecutionRepository
    implements
        OwnAssignedLoadRepository,
        OwnDriverTrackingContextRepository,
        OwnLoadExecutionRepository,
        DriverSyncResumer {
  SupabaseDriverExecutionRepository(
    this._gateway, {
    DriverSyncOutbox? outbox,
    SyncNetworkAvailability? networkAvailability,
  }) : _outbox = outbox ?? DriverSyncOutbox(store: SecureSyncOutboxStore()),
       _networkAvailability =
           networkAvailability ?? ConnectivityPlusSyncNetwork();

  final DriverExecutionRpcGateway _gateway;
  final DriverSyncOutbox _outbox;
  final SyncNetworkAvailability _networkAvailability;
  Future<void> _flushTail = Future<void>.value();

  @override
  Future<SyncFlushReport> resumePendingSync() => _flushPendingSync();

  Future<SyncFlushReport> _flushPendingSync() {
    final scheduled = _flushTail.then(
      (_) => _createDriverSyncWorker(
        outbox: _outbox,
        networkAvailability: _networkAvailability,
        gateway: _gateway,
      ).flush(),
    );
    _flushTail = scheduled.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return scheduled;
  }

  @override
  Future<OwnAssignedLoadSnapshot> fetchOwnAssignedLoads() async {
    final sessionUserId = _gateway.currentUserId;
    if (sessionUserId == null) return const OwnAssignedLoadSnapshot.empty();

    try {
      final response = await _gateway.invoke('get_own_driver_assigned_loads');
      if (!_hasSameSession(sessionUserId)) {
        return const OwnAssignedLoadSnapshot.empty();
      }
      final loads = _asList(response)
          .map(_toAssignedLoad)
          .whereType<DriverAssignedLoad>();
      return OwnAssignedLoadSnapshot.partition(loads);
    } on Object {
      if (!_hasSameSession(sessionUserId)) {
        return const OwnAssignedLoadSnapshot.empty();
      }
      rethrow;
    }
  }

  @override
  Future<AuthorizedDriverTrackingContext>
  fetchOwnDriverTrackingContext() async {
    const inactive = AuthorizedDriverTrackingContext(
      isOnDuty: false,
      hasActiveLoad: false,
    );
    final sessionUserId = _gateway.currentUserId;
    if (sessionUserId == null) return inactive;

    try {
      final response = await _gateway.invoke(
        'get_own_driver_tracking_context',
      );
      if (!_hasSameSession(sessionUserId)) return inactive;
      final context = _asMap(response);
      final isOnDuty = context?['isOnDuty'];
      final hasActiveLoad = context?['hasActiveLoad'];
      if (isOnDuty is! bool || hasActiveLoad is! bool) return inactive;
      return AuthorizedDriverTrackingContext(
        isOnDuty: isOnDuty,
        hasActiveLoad: hasActiveLoad,
      );
    } on Object {
      if (!_hasSameSession(sessionUserId)) return inactive;
      rethrow;
    }
  }

  @override
  Future<DriverLoadExecutionSnapshot?> fetchOwnCurrentLoadExecution() async {
    final sessionUserId = _gateway.currentUserId;
    if (sessionUserId == null) return null;

    try {
      final response = await _gateway.invoke(
        'get_own_driver_execution_snapshot',
      );
      if (!_hasSameSession(sessionUserId)) return null;
      return _toExecutionSnapshot(response);
    } on Object {
      if (!_hasSameSession(sessionUserId)) return null;
      rethrow;
    }
  }

  bool _hasSameSession(String userId) => _gateway.currentUserId == userId;

  DriverAssignedLoad? _toAssignedLoad(Object? raw) {
    final row = _asMap(raw);
    if (row == null) return null;
    final loadId = row['loadId'];
    final loadNumber = row['loadNumber'];
    final pickupLabel = row['pickupLabel'];
    final deliveryLabel = row['deliveryLabel'];
    final status = DriverLoadOperationalStatus.fromWire(
      row['operationalStatus'],
    );
    if (loadId is! String ||
        loadNumber is! String ||
        pickupLabel is! String ||
        deliveryLabel is! String ||
        status == null) {
      return null;
    }
    return DriverAssignedLoad(
      loadId: loadId,
      loadNumber: loadNumber,
      pickupLabel: pickupLabel,
      deliveryLabel: deliveryLabel,
      operationalStatus: status,
    );
  }

  DriverLoadExecutionSnapshot? _toExecutionSnapshot(Object? raw) {
    final row = _asMap(raw);
    if (row == null) return null;
    final loadId = row['loadId'];
    final loadNumber = row['loadNumber'];
    final pickupLabel = row['pickupLabel'];
    final deliveryLabel = row['deliveryLabel'];
    final status = DriverLoadOperationalStatus.fromWire(
      row['operationalStatus'],
    );
    final nextStatusValue = row['serverDefinedNextStatus'];
    final nextStatus = nextStatusValue == null
        ? null
        : DriverLoadOperationalStatus.fromWire(nextStatusValue);
    if (loadId is! String ||
        loadNumber is! String ||
        pickupLabel is! String ||
        deliveryLabel is! String ||
        status == null ||
        (nextStatusValue != null && nextStatus == null)) {
      return null;
    }

    final requirements = _asList(row['requiredDeliveryEvidence'])
        .map(DriverEvidenceType.fromWire)
        .whereType<DriverEvidenceType>()
        .toList(growable: false);
    final evidence = _asList(row['recordedEvidence'])
        .map(_toServerEvidence)
        .whereType<DriverEvidenceCapture>()
        .toList(growable: false);
    return DriverLoadExecutionSnapshot(
      loadId: loadId,
      loadNumber: loadNumber,
      pickupLabel: pickupLabel,
      deliveryLabel: deliveryLabel,
      operationalStatus: status,
      serverDefinedNextStatus: nextStatus,
      requiredDeliveryEvidence: requirements,
      recordedEvidence: evidence,
      actions: SupabaseDriverAuthorizedLoadActions(
        gateway: _gateway,
        repository: this,
        outbox: _outbox,
        flushPendingSync: _flushPendingSync,
      ),
    );
  }

  DriverEvidenceCapture? _toServerEvidence(Object? raw) {
    final row = _asMap(raw);
    if (row == null) return null;
    final type = DriverEvidenceType.fromWire(row['type']);
    final recordedAtValue = row['recordedAt'];
    final recordedAt = recordedAtValue is String
        ? DateTime.tryParse(recordedAtValue)?.toUtc()
        : null;
    if (type == null || recordedAt == null) return null;
    return DriverEvidenceCapture.serverRecorded(
      type: type,
      capturedAt: recordedAt,
    );
  }
}

/// Bound action capability with no client-selectable identity or target state.
/// Every successful mutation refreshes the complete snapshot from PostgreSQL.
final class SupabaseDriverAuthorizedLoadActions
    implements DriverAuthorizedLoadActions {
  SupabaseDriverAuthorizedLoadActions({
    required DriverExecutionRpcGateway gateway,
    required OwnLoadExecutionRepository repository,
    required DriverSyncOutbox outbox,
    required Future<SyncFlushReport> Function() flushPendingSync,
  }) : _gateway = gateway,
       _repository = repository,
       _outbox = outbox,
       _flushPendingSync = flushPendingSync;

  final DriverExecutionRpcGateway _gateway;
  final OwnLoadExecutionRepository _repository;
  final DriverSyncOutbox _outbox;
  final Future<SyncFlushReport> Function() _flushPendingSync;

  @override
  Future<DriverLoadActionResult> requestServerDefinedNextTransition() async {
    final initiatingUserId = _gateway.currentUserId;
    if (initiatingUserId == null) {
      return const DriverLoadActionRejected(DriverExecutionFailure.denied);
    }
    try {
      final record = await _outbox.enqueueStateTransition(
        actorSessionId: initiatingUserId,
      );
      return await _syncAndRefresh(record, initiatingUserId: initiatingUserId);
    } on Object {
      return const DriverLoadActionRejected(DriverExecutionFailure.unavailable);
    }
  }

  @override
  Future<DriverLoadActionResult> recordEvidence(
    DriverEvidenceCapture evidence,
  ) async {
    final content = evidence.toOwnLoadRpcContent();
    final initiatingUserId = _gateway.currentUserId;
    if (content == null || initiatingUserId == null) {
      return const DriverLoadActionRejected(DriverExecutionFailure.denied);
    }
    try {
      final record = await _outbox.enqueueEvidence(
        actorSessionId: initiatingUserId,
        evidenceType: evidence.type.wireValue,
        evidenceContent: content,
      );
      return await _syncAndRefresh(record, initiatingUserId: initiatingUserId);
    } on Object {
      return const DriverLoadActionRejected(DriverExecutionFailure.unavailable);
    }
  }

  @override
  Future<DriverIncidentQueueResult> enqueueIncident(
    DriverIncidentReport incident,
  ) async {
    final initiatingUserId = _gateway.currentUserId;
    if (initiatingUserId == null) {
      return const DriverIncidentQueueRejected(DriverExecutionFailure.denied);
    }
    try {
      final record = await _outbox.enqueueIncident(
        actorSessionId: initiatingUserId,
        clientMutationId: incident.clientMutationId,
        incidentType: incident.type.wireValue,
        description: incident.description,
        attachments: incident.attachments
            .map((attachment) => attachment.localReceiptKey)
            .toList(growable: false),
        location: incident.location == null
            ? null
            : <String, Object?>{
                'latitude': incident.location!.latitude,
                'longitude': incident.location!.longitude,
              },
      );
      if (!_hasSameSession(initiatingUserId)) {
        return const DriverIncidentQueueRejected(DriverExecutionFailure.denied);
      }
      final flush = await _flush(record);
      if (!_hasSameSession(initiatingUserId)) {
        return const DriverIncidentQueueRejected(DriverExecutionFailure.denied);
      }
      if (flush.retryState == SyncRetryState.succeeded) {
        return const DriverIncidentAcknowledged();
      }
      if (flush.retryState == SyncRetryState.blocked) {
        return const DriverIncidentQueueRejected(DriverExecutionFailure.denied);
      }
      return DriverIncidentQueued(
        DriverIncidentQueueReceipt(clientMutationId: incident.clientMutationId),
      );
    } on Object catch (error) {
      if (!_hasSameSession(initiatingUserId)) {
        return const DriverIncidentQueueRejected(DriverExecutionFailure.denied);
      }
      return DriverIncidentQueueRejected(_failureFor(error));
    }
  }

  Future<DriverLoadActionResult> _syncAndRefresh(
    SyncOutboxRecord record, {
    required String initiatingUserId,
  }) async {
    try {
      final flush = await _flush(record);
      final replayState = flush.retryState;
      if (!_hasSameSession(initiatingUserId)) {
        return const DriverLoadActionRejected(DriverExecutionFailure.denied);
      }
      if (replayState == SyncRetryState.pending ||
          replayState == SyncRetryState.retryable ||
          replayState == null) {
        return DriverLoadActionQueued(
          DriverLoadActionQueueReceipt(
            clientMutationId: record.clientMutationId,
          ),
        );
      }
      if (replayState == SyncRetryState.blocked) {
        return const DriverLoadActionRejected(
          DriverExecutionFailure.denied,
        );
      }
      final terminalStatus = _terminalStatusFor(record, flush.report);
      DriverLoadExecutionSnapshot? refreshed;
      try {
        refreshed = await _repository.fetchOwnCurrentLoadExecution();
      } on Object {
        if (terminalStatus != null) {
          return DriverLoadActionTerminal(terminalStatus);
        }
        rethrow;
      }
      if (!_hasSameSession(initiatingUserId)) {
        return const DriverLoadActionRejected(DriverExecutionFailure.denied);
      }
      if (refreshed == null && terminalStatus != null) {
        return DriverLoadActionTerminal(terminalStatus);
      }
      return refreshed == null
          ? const DriverLoadActionRejected(DriverExecutionFailure.unavailable)
          : DriverLoadActionUpdated(refreshed);
    } on Object catch (error) {
      if (!_hasSameSession(initiatingUserId)) {
        return const DriverLoadActionRejected(DriverExecutionFailure.denied);
      }
      return DriverLoadActionRejected(_failureFor(error));
    }
  }

  Future<_DriverFlushResult> _flush(SyncOutboxRecord record) async {
    final report = await _flushPendingSync();
    final updated = (await _outbox.allRecords())
        .where(
          (candidate) => candidate.clientMutationId == record.clientMutationId,
        )
        .toList(growable: false);
    return _DriverFlushResult(
      retryState: updated.length == 1 ? updated.single.retryState : null,
      report: report,
    );
  }

  DriverLoadOperationalStatus? _terminalStatusFor(
    SyncOutboxRecord record,
    SyncFlushReport report,
  ) {
    for (final acknowledgement in report.succeededMutations) {
      if (acknowledgement.clientMutationId != record.clientMutationId) {
        continue;
      }
      final status = DriverLoadOperationalStatus.fromWire(
        acknowledgement.operationalStatus,
      );
      if (status == DriverLoadOperationalStatus.delivered ||
          status == DriverLoadOperationalStatus.closed ||
          status == DriverLoadOperationalStatus.cancelled) {
        return status;
      }
    }
    return null;
  }

  bool _hasSameSession(String userId) => _gateway.currentUserId == userId;

  DriverExecutionFailure _failureFor(Object error) {
    if (error is PostgrestException) {
      return switch (error.code) {
        '42501' => DriverExecutionFailure.denied,
        '22023' => DriverExecutionFailure.evidenceIncomplete,
        _ => DriverExecutionFailure.unavailable,
      };
    }
    return DriverExecutionFailure.unavailable;
  }
}

final class _DriverFlushResult {
  const _DriverFlushResult({required this.retryState, required this.report});

  final SyncRetryState? retryState;
  final SyncFlushReport report;
}

final class GatewaySyncMutationTransport implements SyncMutationTransport {
  const GatewaySyncMutationTransport(this._gateway);

  final DriverExecutionRpcGateway _gateway;

  @override
  Future<SyncTransportResult> send(SyncOutboxRecord record) async {
    if (_gateway.currentUserId != record.actorSessionId) {
      return const SyncTransportTransientFailure();
    }
    try {
      final response = await _gateway.invoke(
        record.functionName,
        arguments: Map<String, dynamic>.from(record.arguments),
      );
      return SyncTransportSucceeded(
        operationalStatus: _acknowledgedOperationalStatus(response),
      );
    } on PostgrestException catch (error) {
      return _isKnownPermanentMutationError(error)
          ? const SyncTransportBlocked()
          : const SyncTransportTransientFailure();
    } on Object {
      return const SyncTransportTransientFailure();
    }
  }
}

bool _isKnownPermanentMutationError(PostgrestException error) {
  final code = error.code;
  return code == '42501' ||
      (code?.startsWith('22') ?? false) || // invalid data or validated precondition
      (code?.startsWith('23') ?? false); // integrity constraint violation
}

String? _acknowledgedOperationalStatus(Object? response) {
  final body = _asMap(response);
  final status = body?['operationalStatus'] ?? body?['operational_status'];
  return status is String ? status : null;
}

List<Object?> _asList(Object? value) => value is List<Object?>
    ? value
    : value is List
    ? List<Object?>.from(value)
    : const <Object?>[];

Map<String, Object?>? _asMap(Object? value) =>
    value is Map ? Map<String, Object?>.from(value) : null;

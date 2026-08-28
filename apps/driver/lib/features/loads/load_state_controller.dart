import 'dart:math';

import 'package:carrierflow_driver/features/evidence/evidence_capture.dart';
import 'package:carrierflow_driver/core/sync/sync_worker.dart';
import 'package:carrierflow_driver/features/loads/driver_load_status.dart';
import 'package:flutter/foundation.dart';

/// Typed failures are safe to render. Raw RPC/network messages and any tenant
/// information stay behind the server-authorized action boundary.
enum DriverExecutionFailure {
  transitionUnavailable,
  evidenceIncomplete,
  denied,
  unavailable,
  invalidIncident,
}

/// Driver actions are bound by the repository to an authenticated, authorized
/// load. Callers never provide a driver ID, company ID, or selected target
/// state. Implementations must persist an incident before scheduling network
/// replay; E3-T1 supplies the concrete durable outbox.
abstract interface class DriverAuthorizedLoadActions {
  Future<DriverLoadActionResult> requestServerDefinedNextTransition();

  Future<DriverLoadActionResult> recordEvidence(DriverEvidenceCapture evidence);

  Future<DriverIncidentQueueResult> enqueueIncident(
    DriverIncidentReport incident,
  );
}

/// Fetches a detail capability that the server already scoped to the active
/// authenticated driver. There is intentionally no load, company, or driver
/// argument for a page route to tamper with.
abstract interface class OwnLoadExecutionRepository {
  Future<DriverLoadExecutionSnapshot?> fetchOwnCurrentLoadExecution();
}

/// A typed, server-authorized detail snapshot. It contains only the currently
/// permitted driver load and an action capability already tied to that scope.
class DriverLoadExecutionSnapshot {
  DriverLoadExecutionSnapshot({
    required this.loadId,
    required this.loadNumber,
    required this.pickupLabel,
    required this.deliveryLabel,
    required this.operationalStatus,
    required this.serverDefinedNextStatus,
    required Iterable<DriverEvidenceType> requiredDeliveryEvidence,
    Iterable<DriverEvidenceCapture> recordedEvidence =
        const <DriverEvidenceCapture>[],
    required this.actions,
  }) : requiredDeliveryEvidence = List<DriverEvidenceType>.unmodifiable(
         requiredDeliveryEvidence,
       ),
       recordedEvidence = List<DriverEvidenceCapture>.unmodifiable(
         recordedEvidence,
       );

  final String loadId;
  final String loadNumber;
  final String pickupLabel;
  final String deliveryLabel;
  final DriverLoadOperationalStatus operationalStatus;
  final DriverLoadOperationalStatus? serverDefinedNextStatus;
  final List<DriverEvidenceType> requiredDeliveryEvidence;
  final List<DriverEvidenceCapture> recordedEvidence;
  final DriverAuthorizedLoadActions actions;

  DriverLoadExecutionSnapshot copyWith({
    DriverLoadOperationalStatus? operationalStatus,
    Object? serverDefinedNextStatus = _unset,
    Iterable<DriverEvidenceType>? requiredDeliveryEvidence,
    Iterable<DriverEvidenceCapture>? recordedEvidence,
  }) {
    return DriverLoadExecutionSnapshot(
      loadId: loadId,
      loadNumber: loadNumber,
      pickupLabel: pickupLabel,
      deliveryLabel: deliveryLabel,
      operationalStatus: operationalStatus ?? this.operationalStatus,
      serverDefinedNextStatus: identical(serverDefinedNextStatus, _unset)
          ? this.serverDefinedNextStatus
          : serverDefinedNextStatus as DriverLoadOperationalStatus?,
      requiredDeliveryEvidence:
          requiredDeliveryEvidence ?? this.requiredDeliveryEvidence,
      recordedEvidence: recordedEvidence ?? this.recordedEvidence,
      actions: actions,
    );
  }
}

const _unset = Object();

sealed class DriverLoadActionResult {
  const DriverLoadActionResult();
}

final class DriverLoadActionUpdated extends DriverLoadActionResult {
  const DriverLoadActionUpdated(this.snapshot);

  final DriverLoadExecutionSnapshot snapshot;
}

/// A successful state transition can remove the active execution capability
/// (for example unloading -> delivered). This is a server acknowledgement,
/// not a client-generated snapshot.
final class DriverLoadActionTerminal extends DriverLoadActionResult {
  const DriverLoadActionTerminal(this.status);

  final DriverLoadOperationalStatus status;
}

final class DriverLoadActionRejected extends DriverLoadActionResult {
  const DriverLoadActionRejected(this.failure);

  final DriverExecutionFailure failure;
}

class DriverLoadActionQueueReceipt {
  const DriverLoadActionQueueReceipt({required this.clientMutationId});

  final String clientMutationId;
}

/// The operation is durably recorded locally but does not yet have a server
/// acknowledgement. It is not an error and must retain its immutable id.
final class DriverLoadActionQueued extends DriverLoadActionResult {
  const DriverLoadActionQueued(this.receipt);

  final DriverLoadActionQueueReceipt receipt;
}

enum DriverIncidentType {
  pickupIssue('pickup_issue'),
  deliveryIssue('delivery_issue'),
  breakdown('breakdown'),
  badAddress('bad_address'),
  customerUnavailable('customer_unavailable'),
  siteRejectedLoad('site_rejected_load'),
  accidentEmergency('accident_emergency'),
  awaitingInstruction('awaiting_instruction');

  const DriverIncidentType(this.wireValue);

  final String wireValue;
}

class DriverIncidentLocation {
  const DriverIncidentLocation({
    required this.latitude,
    required this.longitude,
  }) : assert(latitude >= -90 && latitude <= 90),
       assert(longitude >= -180 && longitude <= 180);

  final double latitude;
  final double longitude;
}

/// The payload contains no load/company/driver identifier. Its authorized
/// action capability owns that scope and persists it before server replay.
class DriverIncidentReport {
  DriverIncidentReport({
    required this.clientMutationId,
    required this.type,
    required String description,
    required this.location,
    required Iterable<PrivateEvidenceReference> attachments,
  }) : description = description.trim(),
       attachments = List<PrivateEvidenceReference>.unmodifiable(attachments) {
    if (clientMutationId.trim().isEmpty ||
        this.description.isEmpty ||
        this.description.length > 2000) {
      throw ArgumentError('An incident requires a valid id and description.');
    }
  }

  final String clientMutationId;
  final DriverIncidentType type;
  final String description;
  final DriverIncidentLocation? location;
  final List<PrivateEvidenceReference> attachments;
}

class DriverIncidentQueueReceipt {
  const DriverIncidentQueueReceipt({required this.clientMutationId});

  final String clientMutationId;
}

sealed class DriverIncidentQueueResult {
  const DriverIncidentQueueResult();
}

final class DriverIncidentQueued extends DriverIncidentQueueResult {
  const DriverIncidentQueued(this.receipt);

  final DriverIncidentQueueReceipt receipt;
}

/// The incident's idempotent RPC has acknowledged the same opaque mutation
/// id. It is no longer pending local sync and another incident may be filed.
final class DriverIncidentAcknowledged extends DriverIncidentQueueResult {
  const DriverIncidentAcknowledged();
}

final class DriverIncidentQueueRejected extends DriverIncidentQueueResult {
  const DriverIncidentQueueRejected(this.failure);

  final DriverExecutionFailure failure;
}

abstract interface class DriverMutationIdFactory {
  String create();
}

final class UuidV4DriverMutationIdFactory implements DriverMutationIdFactory {
  UuidV4DriverMutationIdFactory({Random? random})
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

/// Owns only driver-side execution feedback. The server is still the source
/// of truth: a successful action must return a replacement authorized snapshot.
class DriverLoadStateController extends ChangeNotifier {
  DriverLoadStateController(this._snapshot);

  DriverLoadExecutionSnapshot _snapshot;
  DriverExecutionFailure? _failure;
  DriverLoadActionQueueReceipt? _queuedAction;
  DriverLoadOperationalStatus? _terminalStatus;
  final Map<DriverEvidenceType, DriverLoadActionQueueReceipt>
  _queuedEvidence = <DriverEvidenceType, DriverLoadActionQueueReceipt>{};
  DriverIncidentQueueReceipt? _queuedIncident;
  bool _isAdvancing = false;
  final Set<DriverEvidenceType> _recordingEvidenceTypes =
      <DriverEvidenceType>{};
  bool _isReportingIncident = false;

  DriverLoadExecutionSnapshot get snapshot => _snapshot;
  DriverExecutionFailure? get failure => _failure;
  DriverLoadActionQueueReceipt? get queuedAction => _queuedAction;
  DriverLoadOperationalStatus? get terminalStatus => _terminalStatus;
  DriverIncidentQueueReceipt? get queuedIncident => _queuedIncident;
  bool get isAdvancing => _isAdvancing;
  bool get isRecordingEvidence => _recordingEvidenceTypes.isNotEmpty;
  bool get isReportingIncident => _isReportingIncident;
  bool get isActionQueued => _queuedAction != null;

  DriverLoadActionQueueReceipt? queuedEvidenceFor(DriverEvidenceType type) =>
      _queuedEvidence[type];

  bool isEvidenceQueued(DriverEvidenceType type) =>
      _queuedEvidence.containsKey(type);

  bool isRecordingEvidenceFor(DriverEvidenceType type) =>
      _recordingEvidenceTypes.contains(type);

  bool isEvidenceActionBusy(DriverEvidenceType type) =>
      isRecordingEvidenceFor(type) || isEvidenceQueued(type);

  List<DriverEvidenceType> get missingRequiredDeliveryEvidence =>
      EvidenceRequirements.missingRequiredDeliveryEvidence(
        requiredEvidence: _snapshot.requiredDeliveryEvidence,
        recordedEvidence: _snapshot.recordedEvidence,
      );

  bool get isDeliveryBlocked =>
      _snapshot.serverDefinedNextStatus ==
          DriverLoadOperationalStatus.delivered &&
      missingRequiredDeliveryEvidence.isNotEmpty;

  Future<void> advanceServerDefinedStep() async {
    if (_isAdvancing || isActionQueued) return;

    if (_isTerminalDriverStatus(_snapshot.operationalStatus) ||
        _snapshot.serverDefinedNextStatus == null) {
      _setFailure(DriverExecutionFailure.transitionUnavailable);
      return;
    }
    if (isDeliveryBlocked) {
      _setFailure(DriverExecutionFailure.evidenceIncomplete);
      return;
    }

    _isAdvancing = true;
    _failure = null;
    notifyListeners();
    try {
      final result = await _snapshot.actions
          .requestServerDefinedNextTransition();
      switch (result) {
        case DriverLoadActionUpdated(:final snapshot):
          _snapshot = snapshot;
          _queuedAction = null;
          _terminalStatus = null;
        case DriverLoadActionTerminal(:final status):
          _terminalStatus = status;
          _queuedAction = null;
        case DriverLoadActionRejected(:final failure):
          _failure = failure;
          _queuedAction = null;
        case DriverLoadActionQueued(:final receipt):
          _queuedAction = receipt;
      }
    } on Object {
      _failure = DriverExecutionFailure.unavailable;
    } finally {
      _isAdvancing = false;
      notifyListeners();
    }
  }

  Future<void> recordEvidence(DriverEvidenceCapture evidence) async {
    if (isEvidenceActionBusy(evidence.type)) return;

    _recordingEvidenceTypes.add(evidence.type);
    _failure = null;
    notifyListeners();
    try {
      final result = await _snapshot.actions.recordEvidence(evidence);
      switch (result) {
        case DriverLoadActionUpdated(:final snapshot):
          _snapshot = snapshot;
          _queuedEvidence.remove(evidence.type);
          _terminalStatus = null;
        case DriverLoadActionTerminal(:final status):
          _terminalStatus = status;
          _queuedEvidence.remove(evidence.type);
        case DriverLoadActionRejected(:final failure):
          _failure = failure;
          _queuedEvidence.remove(evidence.type);
        case DriverLoadActionQueued(:final receipt):
          _queuedEvidence[evidence.type] = receipt;
      }
    } on Object {
      _failure = DriverExecutionFailure.unavailable;
    } finally {
      _recordingEvidenceTypes.remove(evidence.type);
      notifyListeners();
    }
  }

  /// Replaces the displayed capability only after the sync worker records an
  /// RPC acknowledgement. Pending entries not in [acknowledgedMutationIds]
  /// remain locally visible and deduplicated.
  void reconcileServerSnapshot(
    DriverLoadExecutionSnapshot snapshot, {
    required Iterable<String> acknowledgedMutationIds,
  }) {
    final acknowledged = acknowledgedMutationIds.toSet();
    final queuedAction = _queuedAction;
    if (queuedAction != null &&
        acknowledged.contains(queuedAction.clientMutationId)) {
      _queuedAction = null;
    }
    _queuedEvidence.removeWhere(
      (_, receipt) => acknowledged.contains(receipt.clientMutationId),
    );
    final queuedIncident = _queuedIncident;
    if (queuedIncident != null &&
        acknowledged.contains(queuedIncident.clientMutationId)) {
      _queuedIncident = null;
    }
    _snapshot = snapshot;
    _terminalStatus = null;
    _failure = null;
    notifyListeners();
  }

  /// The server already acknowledged a terminal state but the load is no
  /// longer active, so no replacement capability can be fetched. Preserve the
  /// last display metadata and show the acknowledgement as a non-mutable
  /// terminal view instead of inventing a new snapshot.
  void reconcileTerminalAcknowledgements(
    Iterable<SyncMutationAcknowledgement> acknowledgements,
  ) {
    final queuedAction = _queuedAction;
    if (queuedAction == null) return;
    for (final acknowledgement in acknowledgements) {
      if (acknowledgement.clientMutationId != queuedAction.clientMutationId) {
        continue;
      }
      final status = DriverLoadOperationalStatus.fromWire(
        acknowledgement.operationalStatus,
      );
      if (status == null || !_isTerminalDriverStatus(status)) continue;
      _terminalStatus = status;
      _queuedAction = null;
      _failure = null;
      notifyListeners();
      return;
    }
  }

  /// An idempotent incident acknowledgement may arrive even if refreshing the
  /// active snapshot is temporarily unavailable. Only the matching local
  /// incident is cleared; different/new reports remain independent.
  void reconcileAcknowledgedIncident(Iterable<String> mutationIds) {
    final receipt = _queuedIncident;
    if (receipt == null || !mutationIds.contains(receipt.clientMutationId)) {
      return;
    }
    _queuedIncident = null;
    _failure = null;
    notifyListeners();
  }

  /// A device adapter failed before an evidence action was queued. The current
  /// server-authorized snapshot remains intact and the UI gets a safe retryable
  /// failure instead of an adapter exception.
  void reportLocalCaptureUnavailable() {
    _setFailure(DriverExecutionFailure.unavailable);
  }

  Future<void> reportIncident({
    required DriverIncidentType type,
    required String description,
    DriverIncidentLocation? location,
    Iterable<PrivateEvidenceReference> attachments =
        const <PrivateEvidenceReference>[],
    DriverMutationIdFactory? mutationIdFactory,
  }) async {
    if (_isReportingIncident || _queuedIncident != null) return;

    final DriverIncidentReport report;
    try {
      report = DriverIncidentReport(
        clientMutationId: (mutationIdFactory ?? UuidV4DriverMutationIdFactory())
            .create(),
        type: type,
        description: description,
        location: location,
        attachments: attachments,
      );
    } on ArgumentError {
      _setFailure(DriverExecutionFailure.invalidIncident);
      return;
    }

    _isReportingIncident = true;
    _failure = null;
    _queuedIncident = null;
    notifyListeners();
    try {
      final result = await _snapshot.actions.enqueueIncident(report);
      switch (result) {
        case DriverIncidentQueued(:final receipt):
          _queuedIncident = receipt;
        case DriverIncidentAcknowledged():
          _queuedIncident = null;
        case DriverIncidentQueueRejected(:final failure):
          _failure = failure;
      }
    } on Object {
      _failure = DriverExecutionFailure.unavailable;
    } finally {
      _isReportingIncident = false;
      notifyListeners();
    }
  }

  void _setFailure(DriverExecutionFailure failure) {
    _failure = failure;
    notifyListeners();
  }
}

/// Binds at most one visible own-load controller to successful replay. The
/// repository remains the server-scoped source of the replacement snapshot;
/// an app lifecycle signal never clears pending UI state by itself.
final class DriverLoadStateSyncReconciler {
  DriverLoadStateSyncReconciler(
    this._repository, {
    required String? Function() currentActorId,
  }) : _currentActorId = currentActorId;

  final OwnLoadExecutionRepository _repository;
  final String? Function() _currentActorId;
  DriverLoadStateController? _activeController;
  String? _activeActorSessionId;

  void attach(
    DriverLoadStateController controller, {
    required String actorSessionId,
  }) {
    _activeController = controller;
    _activeActorSessionId = actorSessionId;
  }

  void detach(DriverLoadStateController controller) {
    if (identical(_activeController, controller)) {
      _activeController = null;
      _activeActorSessionId = null;
    }
  }

  Future<void> reconcile(SyncFlushReport report) async {
    if (report.succeededMutationIds.isEmpty) return;
    final controller = _activeController;
    final actorSessionId = _activeActorSessionId;
    if (controller == null ||
        actorSessionId == null ||
        actorSessionId != _currentActorId()) {
      return;
    }
    controller.reconcileAcknowledgedIncident(report.succeededMutationIds);
    DriverLoadExecutionSnapshot? snapshot;
    try {
      snapshot = await _repository.fetchOwnCurrentLoadExecution();
    } on Object {
      _reconcileTerminalAcknowledgement(controller, actorSessionId, report);
      return;
    }
    if (snapshot == null) {
      _reconcileTerminalAcknowledgement(controller, actorSessionId, report);
      return;
    }
    if (!identical(_activeController, controller) ||
        actorSessionId != _currentActorId()) {
      return;
    }
    controller.reconcileServerSnapshot(
      snapshot,
      acknowledgedMutationIds: report.succeededMutationIds,
    );
  }

  void _reconcileTerminalAcknowledgement(
    DriverLoadStateController controller,
    String actorSessionId,
    SyncFlushReport report,
  ) {
    if (identical(_activeController, controller) &&
        actorSessionId == _currentActorId()) {
      controller.reconcileTerminalAcknowledgements(report.succeededMutations);
    }
  }
}

bool _isTerminalDriverStatus(DriverLoadOperationalStatus status) {
  return switch (status) {
    DriverLoadOperationalStatus.delivered ||
    DriverLoadOperationalStatus.closed ||
    DriverLoadOperationalStatus.cancelled => true,
    _ => false,
  };
}

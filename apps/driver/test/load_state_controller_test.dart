import 'package:carrierflow_driver/features/evidence/evidence_capture.dart';
import 'package:carrierflow_driver/features/loads/driver_load_status.dart';
import 'package:carrierflow_driver/features/loads/load_state_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAuthorizedActions implements DriverAuthorizedLoadActions {
  DriverLoadActionResult? transitionResult;
  DriverLoadActionResult? evidenceResult;
  DriverIncidentQueueResult? incidentResult;

  var transitionRequests = 0;
  final recordedEvidence = <DriverEvidenceCapture>[];
  final queuedIncidents = <DriverIncidentReport>[];

  @override
  Future<DriverLoadActionResult> recordEvidence(
    DriverEvidenceCapture evidence,
  ) async {
    recordedEvidence.add(evidence);
    return evidenceResult ??
        const DriverLoadActionRejected(DriverExecutionFailure.unavailable);
  }

  @override
  Future<DriverIncidentQueueResult> enqueueIncident(
    DriverIncidentReport incident,
  ) async {
    queuedIncidents.add(incident);
    return incidentResult ??
        const DriverIncidentQueueRejected(DriverExecutionFailure.unavailable);
  }

  @override
  Future<DriverLoadActionResult> requestServerDefinedNextTransition() async {
    transitionRequests += 1;
    return transitionResult ??
        const DriverLoadActionRejected(DriverExecutionFailure.unavailable);
  }
}

DriverLoadExecutionSnapshot _snapshot(
  _FakeAuthorizedActions actions, {
  DriverLoadOperationalStatus status =
      DriverLoadOperationalStatus.enRouteToPickup,
  DriverLoadOperationalStatus? serverDefinedNextStatus =
      DriverLoadOperationalStatus.arrivedPickup,
  List<DriverEvidenceType> requirements = const <DriverEvidenceType>[],
  List<DriverEvidenceCapture> evidence = const <DriverEvidenceCapture>[],
}) {
  return DriverLoadExecutionSnapshot(
    loadId: '11111111-1111-1111-1111-111111111111',
    loadNumber: 'CF-201',
    pickupLabel: 'Austin, TX',
    deliveryLabel: 'Dallas, TX',
    operationalStatus: status,
    serverDefinedNextStatus: serverDefinedNextStatus,
    requiredDeliveryEvidence: requirements,
    recordedEvidence: evidence,
    actions: actions,
  );
}

void main() {
  group('driver load state controller', () {
    test(
      'does not request a transition when the server authorizes no next state',
      () async {
        final actions = _FakeAuthorizedActions();
        final controller = DriverLoadStateController(
          _snapshot(actions, serverDefinedNextStatus: null),
        );
        addTearDown(controller.dispose);

        await controller.advanceServerDefinedStep();

        expect(actions.transitionRequests, 0);
        expect(
          controller.failure,
          DriverExecutionFailure.transitionUnavailable,
        );
        expect(
          controller.snapshot.operationalStatus,
          DriverLoadOperationalStatus.enRouteToPickup,
        );
      },
    );

    test('fails closed for delivered, closed, or cancelled snapshots even if a next step is present', () async {
      for (final status in <DriverLoadOperationalStatus>[
        DriverLoadOperationalStatus.delivered,
        DriverLoadOperationalStatus.closed,
        DriverLoadOperationalStatus.cancelled,
      ]) {
        final actions = _FakeAuthorizedActions();
        final controller = DriverLoadStateController(
          _snapshot(
            actions,
            status: status,
            serverDefinedNextStatus: DriverLoadOperationalStatus.assigned,
          ),
        );
        addTearDown(controller.dispose);

        await controller.advanceServerDefinedStep();

        expect(actions.transitionRequests, 0, reason: '$status is terminal');
        expect(
          controller.failure,
          DriverExecutionFailure.transitionUnavailable,
        );
      }
    });

    test(
      'blocks delivery while required non-photo evidence is missing',
      () async {
        final actions = _FakeAuthorizedActions();
        final controller = DriverLoadStateController(
          _snapshot(
            actions,
            status: DriverLoadOperationalStatus.unloading,
            serverDefinedNextStatus: DriverLoadOperationalStatus.delivered,
            requirements: const <DriverEvidenceType>[
              DriverEvidenceType.photo,
              DriverEvidenceType.signature,
              DriverEvidenceType.billOfLading,
              DriverEvidenceType.pod,
              DriverEvidenceType.deliveryGps,
            ],
          ),
        );
        addTearDown(controller.dispose);

        await controller.advanceServerDefinedStep();

        expect(actions.transitionRequests, 0);
        expect(controller.isDeliveryBlocked, isTrue);
        expect(
          controller.missingRequiredDeliveryEvidence,
          const <DriverEvidenceType>[
            DriverEvidenceType.signature,
            DriverEvidenceType.billOfLading,
            DriverEvidenceType.pod,
            DriverEvidenceType.deliveryGps,
          ],
        );
        expect(controller.failure, DriverExecutionFailure.evidenceIncomplete);
      },
    );

    test('does not make a photo requirement block delivery', () async {
      final actions = _FakeAuthorizedActions();
      final initial = _snapshot(
        actions,
        status: DriverLoadOperationalStatus.unloading,
        serverDefinedNextStatus: DriverLoadOperationalStatus.delivered,
        requirements: const <DriverEvidenceType>[DriverEvidenceType.photo],
      );
      actions.transitionResult = DriverLoadActionUpdated(
        initial.copyWith(
          operationalStatus: DriverLoadOperationalStatus.delivered,
          serverDefinedNextStatus: null,
        ),
      );
      final controller = DriverLoadStateController(initial);
      addTearDown(controller.dispose);

      await controller.advanceServerDefinedStep();

      expect(actions.transitionRequests, 1);
      expect(controller.isDeliveryBlocked, isFalse);
      expect(
        controller.snapshot.operationalStatus,
        DriverLoadOperationalStatus.delivered,
      );
    });

    test('queues an incident without changing the active load state', () async {
      final actions = _FakeAuthorizedActions()
        ..incidentResult = const DriverIncidentQueued(
          DriverIncidentQueueReceipt(
            clientMutationId: 'b4f5a799-3dbe-4016-b9c9-a15c48131550',
          ),
        );
      final controller = DriverLoadStateController(_snapshot(actions));
      addTearDown(controller.dispose);

      await controller.reportIncident(
        type: DriverIncidentType.breakdown,
        description: 'Engine warning light is on.',
        location: const DriverIncidentLocation(
          latitude: 30.2672,
          longitude: -97.7431,
        ),
        attachments: <PrivateEvidenceReference>[
          PrivateEvidenceReference.localReceiptKey('engine-photo'),
        ],
        mutationIdFactory: const _FixedMutationIdFactory(
          'b4f5a799-3dbe-4016-b9c9-a15c48131550',
        ),
      );

      expect(actions.queuedIncidents, hasLength(1));
      expect(actions.queuedIncidents.single.type, DriverIncidentType.breakdown);
      expect(
        actions.queuedIncidents.single.description,
        'Engine warning light is on.',
      );
      expect(actions.queuedIncidents.single.location?.latitude, 30.2672);
      expect(
        actions.queuedIncidents.single.attachments.single.localReceiptKey,
        'engine-photo',
      );
      expect(
        controller.queuedIncident?.clientMutationId,
        'b4f5a799-3dbe-4016-b9c9-a15c48131550',
      );
      expect(
        controller.snapshot.operationalStatus,
        DriverLoadOperationalStatus.enRouteToPickup,
      );
    });

    test(
      'keeps the server-authorized snapshot after a typed rejection',
      () async {
        final actions = _FakeAuthorizedActions()
          ..transitionResult = const DriverLoadActionRejected(
            DriverExecutionFailure.denied,
          );
        final controller = DriverLoadStateController(_snapshot(actions));
        addTearDown(controller.dispose);

        await controller.advanceServerDefinedStep();

        expect(controller.failure, DriverExecutionFailure.denied);
        expect(
          controller.snapshot.operationalStatus,
          DriverLoadOperationalStatus.enRouteToPickup,
        );
      },
    );

    test('holds an operation queued without treating it as unavailable or creating a second request', () async {
      final actions = _FakeAuthorizedActions()
        ..transitionResult = const DriverLoadActionQueued(
          DriverLoadActionQueueReceipt(
            clientMutationId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
          ),
        );
      final controller = DriverLoadStateController(_snapshot(actions));
      addTearDown(controller.dispose);

      await controller.advanceServerDefinedStep();
      await controller.advanceServerDefinedStep();

      expect(actions.transitionRequests, 1);
      expect(controller.failure, isNull);
      expect(controller.isActionQueued, isTrue);
      expect(
        controller.queuedAction?.clientMutationId,
        'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      );
    });
  });
}

class _FixedMutationIdFactory implements DriverMutationIdFactory {
  const _FixedMutationIdFactory(this.value);

  final String value;

  @override
  String create() => value;
}

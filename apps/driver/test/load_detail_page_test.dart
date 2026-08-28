import 'package:carrierflow_driver/core/localization/driver_localizations.dart';
import 'package:carrierflow_driver/features/evidence/evidence_capture.dart';
import 'package:carrierflow_driver/features/loads/driver_load_status.dart';
import 'package:carrierflow_driver/features/loads/load_detail_page.dart';
import 'package:carrierflow_driver/features/loads/load_state_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

class _DetailActions implements DriverAuthorizedLoadActions {
  final incidents = <DriverIncidentReport>[];
  final recordedEvidence = <DriverEvidenceCapture>[];
  DriverLoadExecutionSnapshot? _latestSnapshot;
  DriverLoadActionResult? transitionResult;

  void bindSnapshot(DriverLoadExecutionSnapshot snapshot) {
    _latestSnapshot = snapshot;
  }

  @override
  Future<DriverIncidentQueueResult> enqueueIncident(
    DriverIncidentReport incident,
  ) async {
    incidents.add(incident);
    return DriverIncidentQueued(
      DriverIncidentQueueReceipt(clientMutationId: incident.clientMutationId),
    );
  }

  @override
  Future<DriverLoadActionResult> recordEvidence(
    DriverEvidenceCapture evidence,
  ) async {
    recordedEvidence.add(evidence);
    final current = _latestSnapshot;
    if (current == null) {
      return const DriverLoadActionRejected(DriverExecutionFailure.unavailable);
    }
    final updated = current.copyWith(
      recordedEvidence: <DriverEvidenceCapture>[
        ...current.recordedEvidence,
        evidence,
      ],
    );
    _latestSnapshot = updated;
    return DriverLoadActionUpdated(updated);
  }

  @override
  Future<DriverLoadActionResult> requestServerDefinedNextTransition() async =>
      transitionResult ??
      const DriverLoadActionRejected(DriverExecutionFailure.unavailable);
}

DriverLoadExecutionSnapshot _detailSnapshot(
  _DetailActions actions, {
  DriverLoadOperationalStatus status =
      DriverLoadOperationalStatus.enRouteToPickup,
  DriverLoadOperationalStatus? next = DriverLoadOperationalStatus.arrivedPickup,
  List<DriverEvidenceType> requirements = const <DriverEvidenceType>[],
}) {
  final snapshot = DriverLoadExecutionSnapshot(
    loadId: '11111111-1111-1111-1111-111111111111',
    loadNumber: 'CF-201',
    pickupLabel: 'Austin, TX',
    deliveryLabel: 'Dallas, TX',
    operationalStatus: status,
    serverDefinedNextStatus: next,
    requiredDeliveryEvidence: requirements,
    actions: actions,
  );
  actions.bindSnapshot(snapshot);
  return snapshot;
}

class _PrivateEvidenceCaptureAdapter
    implements DriverLocalEvidenceCaptureAdapter {
  final capturedTypes = <DriverEvidenceType>[];

  @override
  Future<DriverEvidenceCapture?> capturePrivateEvidence(
    DriverEvidenceType type,
  ) async {
    capturedTypes.add(type);
    final capturedAt = DateTime.utc(2026, 8, 28);
    return switch (type) {
      DriverEvidenceType.signature ||
      DriverEvidenceType.receiverName ||
      DriverEvidenceType.referenceNumber => DriverEvidenceCapture.textValue(
        receiptId: 'receipt-${type.wireValue}',
        type: type,
        capturedAt: capturedAt,
        value: 'Recorded ${type.wireValue}',
      ),
      DriverEvidenceType.deliveryTimestamp =>
        DriverEvidenceCapture.timestampValue(
          receiptId: 'receipt-${type.wireValue}',
          capturedAt: capturedAt,
          value: capturedAt,
        ),
      DriverEvidenceType.deliveryGps => DriverEvidenceCapture.locationValue(
        receiptId: 'receipt-${type.wireValue}',
        capturedAt: capturedAt,
        value: const DriverEvidenceLocation(
          latitude: 30.2672,
          longitude: -97.7431,
        ),
      ),
      DriverEvidenceType.photo ||
      DriverEvidenceType.billOfLading ||
      DriverEvidenceType.pod => DriverEvidenceCapture(
        receiptId: 'receipt-${type.wireValue}',
        type: type,
        capturedAt: capturedAt,
        summary: 'Private local ${type.wireValue} receipt',
        attachment: PrivateEvidenceReference.localReceiptKey(
          'receipt-${type.wireValue}',
        ),
        metadata: const EvidenceCaptureMetadata(
          mimeType: 'application/pdf',
          byteLength: 1024,
        ),
      ),
    };
  }
}

Widget _subject({
  required Locale locale,
  required DriverLoadExecutionSnapshot snapshot,
  DriverLocalEvidenceCaptureAdapter? captureAdapter,
  DriverLoadStateController? controller,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  return MaterialApp(
    locale: locale,
    supportedLocales: const <Locale>[Locale('en'), Locale('es')],
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      DriverStrings.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      child: child!,
    ),
    home: LoadDetailPage(
      snapshot: snapshot,
      captureAdapter: captureAdapter ?? _PrivateEvidenceCaptureAdapter(),
      controller: controller,
    ),
  );
}

void main() {
  group('driver load detail page', () {
    testWidgets(
      'uses a semantic 48dp action for the server-defined next step',
      (tester) async {
        final actions = _DetailActions();
        await tester.pumpWidget(
          _subject(
            locale: const Locale('en'),
            snapshot: _detailSnapshot(actions),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Next step'), findsOneWidget);
        expect(find.text('Mark as Arrived at pickup'), findsOneWidget);
        expect(find.text('Evidence'), findsOneWidget);
        expect(find.text('Report a problem'), findsOneWidget);
        expect(find.text('Cancel'), findsNothing);
        expect(find.text('Accept'), findsNothing);
        expect(
          tester.getSize(find.byKey(LoadDetailPage.advanceButtonKey)).height,
          greaterThanOrEqualTo(48),
        );
        expect(
          tester
              .getSemantics(find.byKey(LoadDetailPage.advanceButtonKey))
              .flagsCollection
              .isButton,
          isTrue,
        );
      },
    );

    testWidgets(
      'explains missing delivery evidence in Spanish and disables delivery',
      (tester) async {
        final actions = _DetailActions();
        await tester.pumpWidget(
          _subject(
            locale: const Locale('es'),
            snapshot: _detailSnapshot(
              actions,
              status: DriverLoadOperationalStatus.unloading,
              next: DriverLoadOperationalStatus.delivered,
              requirements: const <DriverEvidenceType>[
                DriverEvidenceType.photo,
                DriverEvidenceType.signature,
                DriverEvidenceType.receiverName,
              ],
            ),
            textScaler: const TextScaler.linear(2),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Entrega bloqueada'), findsOneWidget);
        expect(find.text('Firma'), findsOneWidget);
        expect(find.text('Nombre del receptor'), findsOneWidget);
        expect(find.text('Marcar como Entregada'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(find.byKey(LoadDetailPage.advanceButtonKey))
              .onPressed,
          isNull,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'announces a queued operation in English and Spanish while disabling another tap',
      (tester) async {
        final englishActions = _DetailActions()
          ..transitionResult = const DriverLoadActionQueued(
            DriverLoadActionQueueReceipt(
              clientMutationId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
            ),
          );
        await tester.pumpWidget(
          _subject(
            locale: const Locale('en'),
            snapshot: _detailSnapshot(englishActions),
          ),
        );
        await tester.pumpAndSettle();
        final englishAdvance = find.byKey(LoadDetailPage.advanceButtonKey);
        await tester.ensureVisible(englishAdvance);
        await tester.tap(englishAdvance);
        await tester.pumpAndSettle();

        expect(
          find.bySemanticsLabel(
            'Update queued. CarrierFlow will sync it after service connection is restored.',
          ),
          findsAtLeastNWidgets(1),
        );
        expect(
          tester
              .widget<FilledButton>(find.byKey(LoadDetailPage.advanceButtonKey))
              .onPressed,
          isNull,
        );

        final spanishActions = _DetailActions()
          ..transitionResult = const DriverLoadActionQueued(
            DriverLoadActionQueueReceipt(
              clientMutationId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
            ),
          );
        await tester.pumpWidget(
          _subject(
            locale: const Locale('es'),
            snapshot: _detailSnapshot(spanishActions),
          ),
        );
        await tester.pumpAndSettle();
        final spanishAdvance = find.byKey(LoadDetailPage.advanceButtonKey);
        await tester.ensureVisible(spanishAdvance);
        await tester.tap(spanishAdvance);
        await tester.pumpAndSettle();

        expect(
          find.bySemanticsLabel(
            'Actualización en cola. CarrierFlow la sincronizará cuando se restablezca la conexión con el servicio.',
          ),
          findsAtLeastNWidgets(1),
        );
      },
    );

    testWidgets(
      'queues a bilingual incident report without cancelling the load',
      (tester) async {
        final actions = _DetailActions();
        final snapshot = _detailSnapshot(actions);
        final controller = DriverLoadStateController(snapshot);
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          _subject(
            locale: const Locale('en'),
            snapshot: snapshot,
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();

        final reportButton = find.byKey(LoadDetailPage.reportIncidentButtonKey);
        await tester.ensureVisible(reportButton);
        await tester.tap(reportButton);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(LoadDetailPage.incidentDescriptionFieldKey),
          'Loading dock is closed.',
        );
        await tester.tap(find.byKey(LoadDetailPage.submitIncidentButtonKey));
        await tester.pumpAndSettle();

        expect(actions.incidents, hasLength(1));
        expect(actions.incidents.single.description, 'Loading dock is closed.');
        expect(find.text('Incident queued for dispatch'), findsOneWidget);
        expect(
          tester
              .widget<OutlinedButton>(reportButton)
              .onPressed,
          isNull,
        );
        expect(
          find.bySemanticsLabel('Incident queued for dispatch'),
          findsAtLeastNWidgets(1),
        );
        expect(find.text('Cancel load'), findsNothing);

        controller.reconcileAcknowledgedIncident(<String>[
          controller.queuedIncident!.clientMutationId,
        ]);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<OutlinedButton>(reportButton)
              .onPressed,
          isNotNull,
        );
      },
    );

    testWidgets(
      'announces a queued incident and disables its duplicate report action in Spanish',
      (tester) async {
        final actions = _DetailActions();
        final snapshot = _detailSnapshot(actions);
        final controller = DriverLoadStateController(snapshot);
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          _subject(
            locale: const Locale('es'),
            snapshot: snapshot,
            controller: controller,
          ),
        );
        await tester.pumpAndSettle();
        final reportButton = find.byKey(LoadDetailPage.reportIncidentButtonKey);
        await tester.ensureVisible(reportButton);
        await tester.tap(reportButton);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(LoadDetailPage.incidentDescriptionFieldKey),
          'El muelle está cerrado.',
        );
        await tester.tap(find.byKey(LoadDetailPage.submitIncidentButtonKey));
        await tester.pumpAndSettle();

        expect(find.text('Problema en cola para despacho'), findsOneWidget);
        expect(
          tester.widget<OutlinedButton>(reportButton).onPressed,
          isNull,
        );
        expect(
          find.bySemanticsLabel('Problema en cola para despacho'),
          findsAtLeastNWidgets(1),
        );
      },
    );

    testWidgets(
      'records private required evidence and enables delivery only after the server refresh',
      (tester) async {
        final actions = _DetailActions();
        final captureAdapter = _PrivateEvidenceCaptureAdapter();
        await tester.pumpWidget(
          _subject(
            locale: const Locale('en'),
            captureAdapter: captureAdapter,
            snapshot: _detailSnapshot(
              actions,
              status: DriverLoadOperationalStatus.unloading,
              next: DriverLoadOperationalStatus.delivered,
              requirements: const <DriverEvidenceType>[
                DriverEvidenceType.photo,
                DriverEvidenceType.signature,
                DriverEvidenceType.billOfLading,
                DriverEvidenceType.pod,
                DriverEvidenceType.deliveryGps,
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          tester
              .widget<FilledButton>(find.byKey(LoadDetailPage.advanceButtonKey))
              .onPressed,
          isNull,
        );

        for (final type in <DriverEvidenceType>[
          DriverEvidenceType.signature,
          DriverEvidenceType.billOfLading,
          DriverEvidenceType.pod,
          DriverEvidenceType.deliveryGps,
        ]) {
          final captureButton = find.byKey(
            LoadDetailPage.recordEvidenceButtonKey(type),
          );
          await tester.ensureVisible(captureButton);
          await tester.tap(captureButton);
          await tester.pumpAndSettle();
        }

        expect(captureAdapter.capturedTypes, <DriverEvidenceType>[
          DriverEvidenceType.signature,
          DriverEvidenceType.billOfLading,
          DriverEvidenceType.pod,
          DriverEvidenceType.deliveryGps,
        ]);
        expect(actions.recordedEvidence, hasLength(4));
        expect(
          tester
              .widget<FilledButton>(find.byKey(LoadDetailPage.advanceButtonKey))
              .onPressed,
          isNotNull,
        );
      },
    );

    testWidgets(
      'offers a visible localized close action for the incident form',
      (tester) async {
        final actions = _DetailActions();
        await tester.pumpWidget(
          _subject(
            locale: const Locale('es'),
            snapshot: _detailSnapshot(actions),
          ),
        );
        await tester.pumpAndSettle();

        final reportButton = find.byKey(LoadDetailPage.reportIncidentButtonKey);
        await tester.ensureVisible(reportButton);
        await tester.tap(reportButton);
        await tester.pumpAndSettle();

        expect(find.text('Cerrar'), findsOneWidget);
        expect(
          tester
              .getSize(find.byKey(LoadDetailPage.closeIncidentButtonKey))
              .height,
          greaterThanOrEqualTo(48),
        );
        await tester.tap(find.byKey(LoadDetailPage.closeIncidentButtonKey));
        await tester.pumpAndSettle();

        expect(find.text('Categoría del problema'), findsNothing);
      },
    );
  });
}

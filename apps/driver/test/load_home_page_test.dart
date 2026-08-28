import 'dart:async';

import 'package:carrierflow_driver/features/evidence/evidence_capture.dart';
import 'package:carrierflow_driver/features/auth/auth_gate.dart';
import 'package:carrierflow_driver/features/loads/load_home_page.dart';
import 'package:carrierflow_driver/features/loads/load_state_controller.dart';
import 'package:carrierflow_driver/core/push/push_service.dart';
import 'package:carrierflow_driver/features/tracking/tracking_permission_state.dart';
import 'package:carrierflow_driver/features/tracking/tracking_runtime_coordinator.dart';
import 'package:carrierflow_driver/core/localization/driver_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

const _currentLoad = DriverAssignedLoad(
  loadId: '11111111-1111-1111-1111-111111111111',
  loadNumber: 'CF-101',
  pickupLabel: 'Austin, TX',
  deliveryLabel: 'Dallas, TX',
  operationalStatus: DriverLoadOperationalStatus.enRouteToPickup,
);

const _nextLoad = DriverAssignedLoad(
  loadId: '22222222-2222-2222-2222-222222222222',
  loadNumber: 'CF-102',
  pickupLabel: 'Dallas, TX',
  deliveryLabel: 'Houston, TX',
  operationalStatus: DriverLoadOperationalStatus.assigned,
);

const _accountBLoad = DriverAssignedLoad(
  loadId: '33333333-3333-3333-3333-333333333333',
  loadNumber: 'CF-B-301',
  pickupLabel: 'Phoenix, AZ',
  deliveryLabel: 'Tucson, AZ',
  operationalStatus: DriverLoadOperationalStatus.enRouteToPickup,
);

class _FakeOwnAssignedLoadRepository implements OwnAssignedLoadRepository {
  const _FakeOwnAssignedLoadRepository(this.snapshot);

  final OwnAssignedLoadSnapshot snapshot;

  @override
  Future<OwnAssignedLoadSnapshot> fetchOwnAssignedLoads() =>
      Future<OwnAssignedLoadSnapshot>.value(snapshot);
}

class _RetryingOwnAssignedLoadRepository implements OwnAssignedLoadRepository {
  _RetryingOwnAssignedLoadRepository(this.result);

  final OwnAssignedLoadSnapshot result;
  int calls = 0;

  @override
  Future<OwnAssignedLoadSnapshot> fetchOwnAssignedLoads() {
    calls += 1;
    if (calls == 1) {
      return Future<OwnAssignedLoadSnapshot>.error(StateError('offline'));
    }

    return Future<OwnAssignedLoadSnapshot>.value(result);
  }
}

class _CountingOwnAssignedLoadRepository implements OwnAssignedLoadRepository {
  _CountingOwnAssignedLoadRepository(this.snapshot);

  final OwnAssignedLoadSnapshot snapshot;
  var calls = 0;

  @override
  Future<OwnAssignedLoadSnapshot> fetchOwnAssignedLoads() async {
    calls += 1;
    return snapshot;
  }
}

class _SessionSwitchingOwnAssignedLoadRepository
    implements OwnAssignedLoadRepository {
  final first = Completer<OwnAssignedLoadSnapshot>();
  var calls = 0;

  @override
  Future<OwnAssignedLoadSnapshot> fetchOwnAssignedLoads() {
    calls += 1;
    if (calls == 1) return first.future;
    return Future<OwnAssignedLoadSnapshot>.value(
      const OwnAssignedLoadSnapshot(
        currentLoad: DriverAssignedLoad(
          loadId: '33333333-3333-3333-3333-333333333333',
          loadNumber: 'CF-B-301',
          pickupLabel: 'Phoenix, AZ',
          deliveryLabel: 'Tucson, AZ',
          operationalStatus: DriverLoadOperationalStatus.enRouteToPickup,
        ),
      ),
    );
  }
}

class _SequentialOwnAssignedLoadRepository
    implements OwnAssignedLoadRepository {
  _SequentialOwnAssignedLoadRepository(this._snapshots);

  final List<OwnAssignedLoadSnapshot> _snapshots;
  var _calls = 0;

  @override
  Future<OwnAssignedLoadSnapshot> fetchOwnAssignedLoads() {
    final snapshot = _snapshots[_calls];
    _calls += 1;
    return Future<OwnAssignedLoadSnapshot>.value(snapshot);
  }
}

class _NoopAuthorizedLoadActions implements DriverAuthorizedLoadActions {
  const _NoopAuthorizedLoadActions();

  @override
  Future<DriverIncidentQueueResult> enqueueIncident(
    DriverIncidentReport incident,
  ) async =>
      const DriverIncidentQueueRejected(DriverExecutionFailure.unavailable);

  @override
  Future<DriverLoadActionResult> recordEvidence(
    DriverEvidenceCapture evidence,
  ) async => const DriverLoadActionRejected(DriverExecutionFailure.unavailable);

  @override
  Future<DriverLoadActionResult> requestServerDefinedNextTransition() async =>
      const DriverLoadActionRejected(DriverExecutionFailure.unavailable);
}

class _FakeOwnLoadExecutionRepository implements OwnLoadExecutionRepository {
  _FakeOwnLoadExecutionRepository(this.snapshot);

  final DriverLoadExecutionSnapshot? snapshot;
  int calls = 0;

  @override
  Future<DriverLoadExecutionSnapshot?> fetchOwnCurrentLoadExecution() async {
    calls += 1;
    return snapshot;
  }
}

final class _FakeTrackingLifecycle implements DriverTrackingLifecycle {
  _FakeTrackingLifecycle(TrackingPermissionState? initialState)
    : permissionState = ValueNotifier<TrackingPermissionState?>(initialState);

  @override
  final ValueNotifier<TrackingPermissionState?> permissionState;
  var authorizedContextRefreshes = 0;
  var stops = 0;

  @override
  void dispose() => permissionState.dispose();

  @override
  void stop() => stops += 1;

  @override
  void stopForForceQuit() => stops += 1;

  @override
  Future<void> updateAppVisibility(bool appVisible) async {}

  Future<void> refreshAuthorizedTrackingContext() async {
    authorizedContextRefreshes += 1;
  }

}

final class _FakeDriverPushMessageSource implements DriverPushMessageSource {
  final messages = StreamController<Map<String, Object?>>.broadcast();

  @override
  Stream<Map<String, Object?>> get foregroundMessages => messages.stream;

  @override
  Stream<Map<String, Object?>> get openedAppMessages => Stream.empty();
}

final class _MemoryPendingPushStore implements DriverPendingPushStore {
  String? notificationId;
  var clearCalls = 0;

  @override
  Future<void> clear() async {
    clearCalls += 1;
    notificationId = null;
  }

  @override
  Future<void> remember(String value) async {
    notificationId = value;
  }

  @override
  Future<String?> take() async {
    final pending = notificationId;
    notificationId = null;
    return pending;
  }
}

final class _DelayedClearPendingPushStore implements DriverPendingPushStore {
  String? notificationId;
  final clearStarted = Completer<void>();
  final allowClear = Completer<void>();

  @override
  Future<void> clear() async {
    if (!clearStarted.isCompleted) clearStarted.complete();
    await allowClear.future;
    notificationId = null;
  }

  @override
  Future<void> remember(String value) async {
    notificationId = value;
  }

  @override
  Future<String?> take() async {
    final pending = notificationId;
    notificationId = null;
    return pending;
  }
}

Widget _subject({
  required Locale locale,
  DriverSessionState sessionState = const DriverSessionLoading(),
  Stream<DriverSessionState>? authStateChanges,
  required OwnAssignedLoadSnapshot snapshot,
  OwnAssignedLoadRepository? ownAssignedLoadRepository,
  OwnLoadExecutionRepository? ownLoadExecutionRepository,
  DriverTrackingLifecycle? trackingLifecycle,
  DriverPushRefreshService? pushRefreshService,
  TextScaler textScaler = TextScaler.noScaling,
  bool disableAnimations = false,
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
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: textScaler, disableAnimations: disableAnimations),
      child: child!,
    ),
    home: AuthGate(
      authStateChanges:
          authStateChanges ?? Stream<DriverSessionState>.value(sessionState),
      ownAssignedLoadRepository:
          ownAssignedLoadRepository ?? _FakeOwnAssignedLoadRepository(snapshot),
      ownLoadExecutionRepository: ownLoadExecutionRepository,
      trackingLifecycle: trackingLifecycle,
      pushRefreshService: pushRefreshService,
    ),
  );
}

void main() {
  group('driver load home', () {
    testWidgets(
      'shows a bilingual semantic notification-consent state with a 48dp explicit action',
      (tester) async {
        final state = ValueNotifier<PushNotificationState>(
          const PushNotificationState(PushNotificationStatus.permissionRequired),
        );
        var enabled = 0;
        addTearDown(state.dispose);

        for (final expectation in <({Locale locale, String title, String action, String semantics})>[
          (
            locale: const Locale('en'),
            title: 'Notifications need permission',
            action: 'Enable notifications',
            semantics: 'Notifications: Permission required. Enable notifications to receive load updates.',
          ),
          (
            locale: const Locale('es'),
            title: 'Las notificaciones necesitan permiso',
            action: 'Activar notificaciones',
            semantics: 'Notificaciones: Se requiere permiso. Activa las notificaciones para recibir actualizaciones de carga.',
          ),
        ]) {
          await tester.pumpWidget(
            MaterialApp(
              locale: expectation.locale,
              supportedLocales: const <Locale>[Locale('en'), Locale('es')],
              localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
                DriverStrings.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              home: LoadHomePage(
                loads: const OwnAssignedLoadSnapshot(currentLoad: _currentLoad),
                pushNotificationState: state,
                onEnableNotifications: () async => enabled += 1,
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text(expectation.title), findsOneWidget);
          expect(find.bySemanticsLabel(expectation.semantics), findsOneWidget);
          expect(find.text(expectation.action), findsOneWidget);
          final action = find.byKey(LoadHomePage.enableNotificationsButtonKey);
          expect(action, findsOneWidget);
          expect(tester.getSize(action).height, greaterThanOrEqualTo(44));
          await tester.tap(action);
          await tester.pump();
        }
        expect(enabled, 2);
      },
    );

    testWidgets(
      'keeps notification consent visible for an authenticated driver with no assigned load',
      (tester) async {
        final state = ValueNotifier<PushNotificationState>(
          const PushNotificationState(PushNotificationStatus.permissionRequired),
        );
        addTearDown(state.dispose);

        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
              DriverStrings.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: LoadHomePage(
              loads: const OwnAssignedLoadSnapshot.empty(),
              pushNotificationState: state,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('No assigned loads'), findsOneWidget);
        expect(find.text('Notifications need permission'), findsOneWidget);
      },
    );

    testWidgets(
      'names denied and unavailable notification states in English and Spanish without a false enable action',
      (tester) async {
        final state = ValueNotifier<PushNotificationState>(
          const PushNotificationState(PushNotificationStatus.denied),
        );
        addTearDown(state.dispose);

        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('es'),
            supportedLocales: const <Locale>[Locale('en'), Locale('es')],
            localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
              DriverStrings.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: LoadHomePage(
              loads: const OwnAssignedLoadSnapshot(currentLoad: _currentLoad),
              pushNotificationState: state,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Las notificaciones están desactivadas'), findsOneWidget);
        expect(find.byKey(LoadHomePage.enableNotificationsButtonKey), findsNothing);

        state.value = const PushNotificationState(
          PushNotificationStatus.unavailable,
        );
        await tester.pumpAndSettle();
        expect(find.text('Las notificaciones no están disponibles'), findsOneWidget);
        expect(
          find.bySemanticsLabel(
            'Notificaciones: Las notificaciones no están disponibles. Este servidor de CarrierFlow no está configurado para entregar actualizaciones push. Puedes seguir trabajando sin notificaciones.',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'names server delivery configuration unavailable in English and Spanish',
      (tester) async {
        final state = ValueNotifier<PushNotificationState>(
          const PushNotificationState(
            PushNotificationStatus.registrationUnavailable,
          ),
        );
        addTearDown(state.dispose);

        for (final expectation
            in <({Locale locale, String title, String semantics})>[
              (
                locale: const Locale('en'),
                title: 'Notifications are unavailable',
                semantics:
                    'Notifications: Notifications are unavailable. This CarrierFlow server is not configured to deliver push updates. You can keep working without notifications.',
              ),
              (
                locale: const Locale('es'),
                title: 'Las notificaciones no están disponibles',
                semantics:
                    'Notificaciones: Las notificaciones no están disponibles. Este servidor de CarrierFlow no está configurado para entregar actualizaciones push. Puedes seguir trabajando sin notificaciones.',
              ),
            ]) {
          await tester.pumpWidget(
            MaterialApp(
              locale: expectation.locale,
              supportedLocales: const <Locale>[Locale('en'), Locale('es')],
              localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
                DriverStrings.delegate,
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              home: LoadHomePage(
                loads: const OwnAssignedLoadSnapshot.empty(),
                pushNotificationState: state,
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text(expectation.title), findsOneWidget);
          expect(find.bySemanticsLabel(expectation.semantics), findsOneWidget);
          expect(
            find.byKey(LoadHomePage.enableNotificationsButtonKey),
            findsNothing,
          );
        }
      },
    );

    testWidgets(
      'shows the current load before a next assigned load in English',
      (tester) async {
        await tester.pumpWidget(
          _subject(
            locale: const Locale('en'),
            sessionState: const DriverSessionAuthenticated(userId: 'driver-test'),
            snapshot: const OwnAssignedLoadSnapshot(
              currentLoad: _currentLoad,
              nextLoad: _nextLoad,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Current load'), findsOneWidget);
        expect(find.text('Next assigned load'), findsOneWidget);
        expect(find.text('CF-101'), findsOneWidget);
        expect(find.text('CF-102'), findsOneWidget);
        expect(
          tester.getTopLeft(find.text('Current load')).dy,
          lessThan(tester.getTopLeft(find.text('Next assigned load')).dy),
        );
        expect(find.text('View load'), findsNothing);
      },
    );

    testWidgets(
      'starts tracking from the authorized current load and names degraded state in English and Spanish',
      (tester) async {
        final englishState = TrackingPermissionState.assess(
          accuracy: TrackingAccuracy.precise,
          batteryRestricted: false,
          now: DateTime.utc(2026, 8, 28, 12),
          permission: TrackingPlatformPermission.denied,
          processWasForceQuit: false,
          serviceEnabled: true,
        );
        final tracking = _FakeTrackingLifecycle(englishState);
        addTearDown(tracking.dispose);

        await tester.pumpWidget(
          _subject(
            locale: const Locale('en'),
            sessionState: const DriverSessionAuthenticated(userId: 'driver-test'),
            snapshot: const OwnAssignedLoadSnapshot(currentLoad: _currentLoad),
            trackingLifecycle: tracking,
          ),
        );
        await tester.pumpAndSettle();

        expect(tracking.authorizedContextRefreshes, 1);
        expect(
          find.bySemanticsLabel(
            'Location tracking: Location permission denied. Background updates during an active load are best effort and controlled by your device.',
          ),
          findsOneWidget,
        );
        expect(find.byIcon(Icons.location_off_outlined), findsOneWidget);
        expect(
          find.text('Background updates during an active load are best effort and controlled by your device.'),
          findsOneWidget,
        );

        tracking.permissionState.value = TrackingPermissionState.assess(
          accuracy: TrackingAccuracy.precise,
          batteryRestricted: false,
          now: DateTime.utc(2026, 8, 28, 12),
          permission: TrackingPlatformPermission.always,
          processWasForceQuit: true,
          serviceEnabled: true,
        );
        await tester.pump();
        expect(
          find.text('The app was force-quit; tracking resumes when it is opened'),
          findsOneWidget,
        );

        await tester.pumpWidget(
          _subject(
            locale: const Locale('es'),
            sessionState: const DriverSessionAuthenticated(userId: 'driver-test'),
            snapshot: const OwnAssignedLoadSnapshot(currentLoad: _currentLoad),
            trackingLifecycle: tracking,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.bySemanticsLabel(
            'Seguimiento de ubicación: La app se cerró por completo; el seguimiento se reanuda al abrirla. Las actualizaciones en segundo plano durante una carga activa son de mejor esfuerzo y las controla tu dispositivo.',
          ),
          findsOneWidget,
        );
        expect(
          find.text('Las actualizaciones en segundo plano durante una carga activa son de mejor esfuerzo y las controla tu dispositivo.'),
          findsOneWidget,
        );
      },
    );

    testWidgets('uses Spanish locale resources for driver-facing labels', (
      tester,
    ) async {
      await tester.pumpWidget(
        _subject(
          locale: const Locale('es'),
          sessionState: const DriverSessionAuthenticated(userId: 'driver-test'),
          snapshot: const OwnAssignedLoadSnapshot(currentLoad: _currentLoad),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Carga actual'), findsOneWidget);
      expect(find.text('Ver carga'), findsNothing);
      expect(find.text('Next assigned load'), findsNothing);
    });

    testWidgets('localizes the raw server state enum in Spanish', (
      tester,
    ) async {
      const deliveryBoundLoad = DriverAssignedLoad(
        loadId: '33333333-3333-3333-3333-333333333333',
        loadNumber: 'CF-103',
        pickupLabel: 'El Paso, TX',
        deliveryLabel: 'Phoenix, AZ',
        operationalStatus: DriverLoadOperationalStatus.enRouteToDelivery,
      );
      await tester.pumpWidget(
        _subject(
          locale: const Locale('es'),
          sessionState: const DriverSessionAuthenticated(userId: 'driver-test'),
          snapshot: const OwnAssignedLoadSnapshot(
            currentLoad: deliveryBoundLoad,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Estado: En camino a entrega', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.text('en_route_to_delivery', findRichText: true),
        findsNothing,
      );
    });

    testWidgets(
      'does not render a next section when only a current load exists',
      (tester) async {
        await tester.pumpWidget(
          _subject(
            locale: const Locale('en'),
            sessionState: const DriverSessionAuthenticated(userId: 'driver-test'),
            snapshot: const OwnAssignedLoadSnapshot(currentLoad: _currentLoad),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Current load'), findsOneWidget);
        expect(find.text('Next assigned load'), findsNothing);
      },
    );

    testWidgets(
      'shows a safe empty state for an authenticated driver with no loads',
      (tester) async {
        await tester.pumpWidget(
          _subject(
            locale: const Locale('en'),
            sessionState: const DriverSessionAuthenticated(userId: 'driver-test'),
            snapshot: const OwnAssignedLoadSnapshot.empty(),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('No assigned loads'), findsOneWidget);
        expect(find.text('CF-101'), findsNothing);
        expect(find.text('CF-102'), findsNothing);
      },
    );

    testWidgets('fails closed to a safe signed-out state', (tester) async {
      await tester.pumpWidget(
        _subject(
          locale: const Locale('en'),
          sessionState: const DriverSessionSignedOut(),
          snapshot: const OwnAssignedLoadSnapshot(
            currentLoad: _currentLoad,
            nextLoad: _nextLoad,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Sign in to view your assigned loads'), findsOneWidget);
      expect(find.text('CF-101'), findsNothing);
      expect(find.text('CF-102'), findsNothing);
    });

    testWidgets('queries own loads only after the authenticated auth state', (
      tester,
    ) async {
      final authStateChanges = StreamController<DriverSessionState>();
      final repository = _RetryingOwnAssignedLoadRepository(
        const OwnAssignedLoadSnapshot(currentLoad: _currentLoad),
      );
      addTearDown(authStateChanges.close);

      await tester.pumpWidget(
        _subject(
          locale: const Locale('en'),
          authStateChanges: authStateChanges.stream,
          snapshot: const OwnAssignedLoadSnapshot.empty(),
          ownAssignedLoadRepository: repository,
        ),
      );

      authStateChanges.add(const DriverSessionSignedOut());
      await tester.pumpAndSettle();
      expect(repository.calls, 0);

      authStateChanges.add(
        const DriverSessionAuthenticated(userId: 'driver-test'),
      );
      await tester.pumpAndSettle();
      expect(repository.calls, 1);
      expect(
        find.text('Your assigned loads are unavailable right now'),
        findsOneWidget,
      );
    });

    testWidgets(
      'refreshes the authenticated driver own view from an opaque notification hint only',
      (tester) async {
        final source = _FakeDriverPushMessageSource();
        final pushRefreshService = DriverPushRefreshService(source: source);
        final repository = _CountingOwnAssignedLoadRepository(
          const OwnAssignedLoadSnapshot(currentLoad: _currentLoad),
        );
        final authStateChanges = StreamController<DriverSessionState>();
        addTearDown(() async {
          pushRefreshService.dispose();
          await source.messages.close();
          await authStateChanges.close();
        });

        await tester.pumpWidget(
          _subject(
            locale: const Locale('en'),
            authStateChanges: authStateChanges.stream,
            snapshot: const OwnAssignedLoadSnapshot.empty(),
            ownAssignedLoadRepository: repository,
            pushRefreshService: pushRefreshService,
          ),
        );
        authStateChanges.add(
          const DriverSessionAuthenticated(userId: 'driver-test'),
        );
        await tester.pumpAndSettle();
        expect(find.text('CF-101'), findsOneWidget);
        expect(repository.calls, 1);

        source.messages.add(<String, Object?>{
          'notificationId': '11111111-1111-4111-8111-111111111111',
          'loadId': 'ignored-by-the-mobile-boundary',
        });
        await tester.pumpAndSettle();

        // The refresh reuses the zero-scope own-load repository; the push
        // hint is never interpreted as a load, driver, or company scope.
        expect(find.text('CF-101'), findsOneWidget);
        expect(repository.calls, 2);
      },
    );

    testWidgets(
      'consumes a persisted opaque background hint when an authenticated app resumes',
      (tester) async {
        final source = _FakeDriverPushMessageSource();
        final pendingPushStore = _MemoryPendingPushStore();
        final pushRefreshService = DriverPushRefreshService(
          source: source,
          pendingPushStore: pendingPushStore,
        );
        final repository = _CountingOwnAssignedLoadRepository(
          const OwnAssignedLoadSnapshot(currentLoad: _currentLoad),
        );
        final authStateChanges = StreamController<DriverSessionState>();
        addTearDown(() async {
          pushRefreshService.dispose();
          await source.messages.close();
          await authStateChanges.close();
        });

        await tester.pumpWidget(
          _subject(
            locale: const Locale('en'),
            authStateChanges: authStateChanges.stream,
            snapshot: const OwnAssignedLoadSnapshot.empty(),
            ownAssignedLoadRepository: repository,
            pushRefreshService: pushRefreshService,
          ),
        );
        authStateChanges.add(
          const DriverSessionAuthenticated(userId: 'driver-a'),
        );
        await tester.pumpAndSettle();
        expect(repository.calls, 1);

        await persistDriverPushBackgroundHint(
          <String, Object?>{
            'notificationId': '11111111-1111-4111-8111-111111111111',
            'loadId': 'not-a-client-scope',
          },
          store: pendingPushStore,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();

        expect(repository.calls, 2);
        expect(pendingPushStore.notificationId, isNull);
      },
    );

    testWidgets(
      'clears a pending background hint before a signed-out session can refresh',
      (tester) async {
        final source = _FakeDriverPushMessageSource();
        final pendingPushStore = _MemoryPendingPushStore()
          ..notificationId = '11111111-1111-4111-8111-111111111111';
        final pushRefreshService = DriverPushRefreshService(
          source: source,
          pendingPushStore: pendingPushStore,
        );
        final repository = _CountingOwnAssignedLoadRepository(
          const OwnAssignedLoadSnapshot(currentLoad: _currentLoad),
        );
        final authStateChanges = StreamController<DriverSessionState>();
        addTearDown(() async {
          pushRefreshService.dispose();
          await source.messages.close();
          await authStateChanges.close();
        });

        await tester.pumpWidget(
          _subject(
            locale: const Locale('en'),
            authStateChanges: authStateChanges.stream,
            snapshot: const OwnAssignedLoadSnapshot.empty(),
            ownAssignedLoadRepository: repository,
            pushRefreshService: pushRefreshService,
          ),
        );
        authStateChanges.add(
          const DriverSessionAuthenticated(userId: 'driver-a'),
        );
        await tester.pumpAndSettle();
        authStateChanges.add(const DriverSessionSignedOut());
        await tester.pumpAndSettle();
        expect(pendingPushStore.notificationId, isNull);

        pendingPushStore.notificationId =
            '11111111-1111-4111-8111-111111111111';
        authStateChanges.add(
          const DriverSessionAuthenticated(userId: 'driver-b'),
        );
        await tester.pumpAndSettle();
        expect(pendingPushStore.notificationId, isNull);

        final callsBeforeResume = repository.calls;
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(repository.calls, callsBeforeResume);
      },
    );

    testWidgets(
      'drops A background hints before a direct A-to-B session can refresh B',
      (tester) async {
        final source = _FakeDriverPushMessageSource();
        final pendingPushStore = _MemoryPendingPushStore();
        final pushRefreshService = DriverPushRefreshService(
          source: source,
          pendingPushStore: pendingPushStore,
        );
        final repository = _CountingOwnAssignedLoadRepository(
          const OwnAssignedLoadSnapshot(currentLoad: _currentLoad),
        );
        final authStateChanges = StreamController<DriverSessionState>();
        addTearDown(() async {
          pushRefreshService.dispose();
          await source.messages.close();
          await authStateChanges.close();
        });

        await tester.pumpWidget(
          _subject(
            locale: const Locale('en'),
            authStateChanges: authStateChanges.stream,
            snapshot: const OwnAssignedLoadSnapshot.empty(),
            ownAssignedLoadRepository: repository,
            pushRefreshService: pushRefreshService,
          ),
        );
        authStateChanges.add(
          const DriverSessionAuthenticated(userId: 'driver-a'),
        );
        await tester.pumpAndSettle();
        expect(repository.calls, 1);

        pendingPushStore.notificationId =
            '11111111-1111-4111-8111-111111111111';
        authStateChanges.add(
          const DriverSessionAuthenticated(userId: 'driver-b'),
        );
        await tester.pumpAndSettle();

        // B's own initial read is permitted. The pending hint was for A and
        // must not cause a second B read or remain for a later resume.
        expect(repository.calls, 2);
        expect(pendingPushStore.notificationId, isNull);
        expect(pendingPushStore.clearCalls, 1);

        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(repository.calls, 2);
      },
    );

    testWidgets(
      'waits for a delayed A-to-B pending-hint clear before B can refresh',
      (tester) async {
        final source = _FakeDriverPushMessageSource();
        final pendingPushStore = _DelayedClearPendingPushStore();
        final pushRefreshService = DriverPushRefreshService(
          source: source,
          pendingPushStore: pendingPushStore,
        );
        final repository = _CountingOwnAssignedLoadRepository(
          const OwnAssignedLoadSnapshot(currentLoad: _currentLoad),
        );
        final authStateChanges = StreamController<DriverSessionState>();
        addTearDown(() async {
          pushRefreshService.dispose();
          await source.messages.close();
          await authStateChanges.close();
        });

        await tester.pumpWidget(
          _subject(
            locale: const Locale('en'),
            authStateChanges: authStateChanges.stream,
            snapshot: const OwnAssignedLoadSnapshot.empty(),
            ownAssignedLoadRepository: repository,
            pushRefreshService: pushRefreshService,
          ),
        );
        authStateChanges.add(
          const DriverSessionAuthenticated(userId: 'driver-a'),
        );
        await tester.pumpAndSettle();
        expect(repository.calls, 1);

        pendingPushStore.notificationId =
            '11111111-1111-4111-8111-111111111111';
        authStateChanges.add(
          const DriverSessionAuthenticated(userId: 'driver-b'),
        );
        await tester.pump();
        await tester.pump();
        await pendingPushStore.clearStarted.future;

        // B's initial own-read is permitted; A's pending UUID must remain
        // behind the clear barrier rather than causing a second B read.
        expect(repository.calls, 2);
        pendingPushStore.allowClear.complete();
        await tester.pumpAndSettle();
        expect(repository.calls, 2);
        expect(pendingPushStore.notificationId, isNull);
      },
    );

    testWidgets(
      'recreates the authenticated load subtree on a direct A-to-B session switch so A data cannot render for B',
      (tester) async {
        final authStateChanges = StreamController<DriverSessionState>();
        final repository = _SessionSwitchingOwnAssignedLoadRepository();
        addTearDown(authStateChanges.close);

        await tester.pumpWidget(
          _subject(
            locale: const Locale('en'),
            authStateChanges: authStateChanges.stream,
            snapshot: const OwnAssignedLoadSnapshot.empty(),
            ownAssignedLoadRepository: repository,
          ),
        );
        authStateChanges.add(
          const DriverSessionAuthenticated(userId: 'driver-session-a'),
        );
        // StreamController delivers its event asynchronously. Two frames start
        // the fetch, without waiting for the intentionally pending A response
        // (whose loading indicator keeps `pumpAndSettle` active).
        await tester.pump();
        await tester.pump();
        expect(repository.calls, 1);

        authStateChanges.add(
          const DriverSessionAuthenticated(userId: 'driver-session-b'),
        );
        await tester.pumpAndSettle();
        expect(repository.calls, 2);
        expect(find.text('CF-B-301'), findsOneWidget);

        repository.first.complete(
          const OwnAssignedLoadSnapshot(currentLoad: _currentLoad),
        );
        await tester.pumpAndSettle();
        expect(find.text('CF-B-301'), findsOneWidget);
        expect(find.text('CF-101'), findsNothing);
      },
    );

    testWidgets(
      'closes A detail before a signed-out to B session transition can expose A data',
      (tester) async {
        final authStateChanges = StreamController<DriverSessionState>();
        final repository = _SequentialOwnAssignedLoadRepository(
          const <OwnAssignedLoadSnapshot>[
            OwnAssignedLoadSnapshot(currentLoad: _currentLoad),
            OwnAssignedLoadSnapshot(currentLoad: _accountBLoad),
          ],
        );
        final executionRepository = _FakeOwnLoadExecutionRepository(
          DriverLoadExecutionSnapshot(
            loadId: _currentLoad.loadId,
            loadNumber: _currentLoad.loadNumber,
            pickupLabel: _currentLoad.pickupLabel,
            deliveryLabel: _currentLoad.deliveryLabel,
            operationalStatus: _currentLoad.operationalStatus,
            serverDefinedNextStatus: DriverLoadOperationalStatus.arrivedPickup,
            requiredDeliveryEvidence: const <DriverEvidenceType>[],
            actions: const _NoopAuthorizedLoadActions(),
          ),
        );
        addTearDown(authStateChanges.close);

        await tester.pumpWidget(
          _subject(
            locale: const Locale('en'),
            authStateChanges: authStateChanges.stream,
            snapshot: const OwnAssignedLoadSnapshot.empty(),
            ownAssignedLoadRepository: repository,
            ownLoadExecutionRepository: executionRepository,
          ),
        );
        authStateChanges.add(
          const DriverSessionAuthenticated(userId: 'driver-session-a'),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('View load'));
        await tester.pumpAndSettle();
        expect(find.text('Load details'), findsOneWidget);
        expect(find.text('CF-101'), findsOneWidget);

        authStateChanges.add(const DriverSessionSignedOut());
        await tester.pumpAndSettle();
        expect(find.text('Load details'), findsNothing);
        expect(find.text('CF-101'), findsNothing);
        expect(find.text('Sign in to view your assigned loads'), findsOneWidget);

        authStateChanges.add(
          const DriverSessionAuthenticated(userId: 'driver-session-b'),
        );
        await tester.pumpAndSettle();
        expect(find.text('Load details'), findsNothing);
        expect(find.text('CF-101'), findsNothing);
        expect(find.text('CF-B-301'), findsOneWidget);
      },
    );

    testWidgets(
      'does not activate tracking from a load query that resolves after sign-out',
      (tester) async {
        final authStateChanges = StreamController<DriverSessionState>();
        final repository = _SessionSwitchingOwnAssignedLoadRepository();
        final tracking = _FakeTrackingLifecycle(null);
        addTearDown(authStateChanges.close);
        addTearDown(tracking.dispose);

        await tester.pumpWidget(
          _subject(
            locale: const Locale('en'),
            authStateChanges: authStateChanges.stream,
            snapshot: const OwnAssignedLoadSnapshot.empty(),
            ownAssignedLoadRepository: repository,
            trackingLifecycle: tracking,
          ),
        );
        authStateChanges.add(
          const DriverSessionAuthenticated(userId: 'driver-session-a'),
        );
        await tester.pump();
        await tester.pump();
        expect(repository.calls, 1);
        authStateChanges.add(const DriverSessionSignedOut());
        await tester.pump();
        repository.first.complete(
          const OwnAssignedLoadSnapshot(currentLoad: _currentLoad),
        );
        await tester.pumpAndSettle();

        expect(tracking.authorizedContextRefreshes, 0);
        expect(tracking.stops, greaterThan(0));
      },
    );

    testWidgets('retries an unavailable own-load query through a real action', (
      tester,
    ) async {
      final repository = _RetryingOwnAssignedLoadRepository(
        const OwnAssignedLoadSnapshot(currentLoad: _currentLoad),
      );
      await tester.pumpWidget(
        _subject(
          locale: const Locale('en'),
          sessionState: const DriverSessionAuthenticated(userId: 'driver-test'),
          snapshot: const OwnAssignedLoadSnapshot.empty(),
          ownAssignedLoadRepository: repository,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Your assigned loads are unavailable right now'),
        findsOneWidget,
      );
      expect(find.text('Try again'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(LoadHomePage.retryButtonKey)).height,
        greaterThanOrEqualTo(48),
      );

      await tester.tap(find.byKey(LoadHomePage.retryButtonKey));
      await tester.pumpAndSettle();

      expect(repository.calls, 2);
      expect(find.text('Current load'), findsOneWidget);
      expect(find.text('CF-101'), findsOneWidget);
    });

    testWidgets(
      'uses a static loading indicator when reduced motion is enabled',
      (tester) async {
        await tester.pumpWidget(
          _subject(
            locale: const Locale('en'),
            sessionState: const DriverSessionLoading(),
            snapshot: const OwnAssignedLoadSnapshot.empty(),
            disableAnimations: true,
          ),
        );
        await tester.pump();

        final loadingIndicator = tester.widget<CircularProgressIndicator>(
          find.byType(CircularProgressIndicator),
        );
        expect(loadingIndicator.value, 0.5);
      },
    );

    testWidgets('keeps an authenticated load home usable at large text sizes', (
      tester,
    ) async {
      await tester.pumpWidget(
        _subject(
          locale: const Locale('en'),
          sessionState: const DriverSessionAuthenticated(userId: 'driver-test'),
          snapshot: const OwnAssignedLoadSnapshot(
            currentLoad: _currentLoad,
            nextLoad: _nextLoad,
          ),
          textScaler: const TextScaler.linear(2),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Current load'), findsOneWidget);
    });

    testWidgets(
      'routes the authenticated current load to its own detail snapshot',
      (tester) async {
        final executionRepository = _FakeOwnLoadExecutionRepository(
          DriverLoadExecutionSnapshot(
            loadId: _currentLoad.loadId,
            loadNumber: _currentLoad.loadNumber,
            pickupLabel: _currentLoad.pickupLabel,
            deliveryLabel: _currentLoad.deliveryLabel,
            operationalStatus: _currentLoad.operationalStatus,
            serverDefinedNextStatus: DriverLoadOperationalStatus.arrivedPickup,
            requiredDeliveryEvidence: const <DriverEvidenceType>[],
            actions: const _NoopAuthorizedLoadActions(),
          ),
        );
        await tester.pumpWidget(
          _subject(
            locale: const Locale('en'),
            sessionState: const DriverSessionAuthenticated(userId: 'driver-test'),
            snapshot: const OwnAssignedLoadSnapshot(currentLoad: _currentLoad),
            ownLoadExecutionRepository: executionRepository,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('View load'), findsOneWidget);
        expect(
          tester
              .getSize(
                find.ancestor(
                  of: find.text('View load'),
                  matching: find.byType(FilledButton),
                ),
              )
              .height,
          greaterThanOrEqualTo(48),
        );
        await tester.tap(find.text('View load'));
        await tester.pumpAndSettle();

        expect(executionRepository.calls, 1);
        expect(find.text('Load details'), findsOneWidget);
        expect(find.text('CF-101'), findsOneWidget);
        expect(find.text('Cancel'), findsNothing);
        expect(find.text('Accept'), findsNothing);
      },
    );
  });
}

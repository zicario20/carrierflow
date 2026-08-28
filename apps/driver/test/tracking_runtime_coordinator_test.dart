import 'dart:async';

import 'package:carrierflow_driver/features/tracking/tracking_authorization.dart';
import 'package:carrierflow_driver/features/tracking/tracking_background_work.dart';
import 'package:carrierflow_driver/features/tracking/tracking_permission_state.dart';
import 'package:carrierflow_driver/features/tracking/tracking_runtime_coordinator.dart';
import 'package:carrierflow_driver/features/tracking/tracking_service.dart';
import 'package:flutter_test/flutter_test.dart';

final class _RecordingGateway implements TrackingGateway {
  final List<TrackingLocationSample> samples = <TrackingLocationSample>[];

  @override
  Future<TrackingSubmissionReceipt> recordOwnLocation(
    TrackingLocationSample sample,
  ) async {
    samples.add(sample);
    return TrackingSubmissionReceipt(recordedAt: sample.recordedAt);
  }
}

final class _FakeLocationPlatform implements TrackingLocationPlatform {
  _FakeLocationPlatform({
    required this.permissionSnapshot,
    required this.samples,
  });

  TrackingPlatformSnapshot permissionSnapshot;
  final List<Future<TrackingLocationSample>> samples;
  var captureCalls = 0;
  var permissionCalls = 0;
  final List<bool> requestedForeground = <bool>[];

  @override
  Future<TrackingLocationSample> captureCurrentLocation() {
    final next = samples[captureCalls];
    captureCalls += 1;
    return next;
  }

  @override
  Future<TrackingPlatformSnapshot> requestPermissionState({
    required bool requestForeground,
  }) async {
    permissionCalls += 1;
    requestedForeground.add(requestForeground);
    return permissionSnapshot;
  }
}

final class _FakeTrackingContextRepository
    implements OwnDriverTrackingContextRepository {
  _FakeTrackingContextRepository(this.context);

  AuthorizedDriverTrackingContext context;
  var calls = 0;

  @override
  Future<AuthorizedDriverTrackingContext>
  fetchOwnDriverTrackingContext() async {
    calls += 1;
    return context;
  }
}

final class _FakeTimer implements TrackingTimer {
  _FakeTimer(this.interval, this._callback);

  final Duration interval;
  final void Function() _callback;
  var cancelled = false;

  void fire() {
    if (!cancelled) _callback();
  }

  @override
  void cancel() => cancelled = true;
}

final class _FakeTimerFactory implements TrackingTimerFactory {
  final List<_FakeTimer> timers = <_FakeTimer>[];

  @override
  TrackingTimer every(Duration interval, void Function() callback) {
    final timer = _FakeTimer(interval, callback);
    timers.add(timer);
    return timer;
  }
}

final class _FakeBackgroundWorkScheduler implements TrackingBackgroundWorkScheduler {
  final List<TrackingContext> scheduledContexts = <TrackingContext>[];
  var cancellations = 0;

  @override
  Future<void> cancel() async {
    cancellations += 1;
  }

  @override
  Future<void> scheduleForActiveLoad({
    required TrackingContext context,
    required TrackingPermissionState permission,
  }) async {
    scheduledContexts.add(context);
  }
}

const _alwaysPrecise = TrackingPlatformSnapshot(
  accuracy: TrackingAccuracy.precise,
  batteryRestricted: false,
  permission: TrackingPlatformPermission.always,
  serviceEnabled: true,
);

const _activeTrackingContext = AuthorizedDriverTrackingContext(
  isOnDuty: true,
  hasActiveLoad: true,
);

const _onDutyTrackingContext = AuthorizedDriverTrackingContext(
  isOnDuty: true,
  hasActiveLoad: false,
);

const _inactiveTrackingContext = AuthorizedDriverTrackingContext(
  isOnDuty: false,
  hasActiveLoad: false,
);

TrackingLocationSample _sample({double speed = 12}) => TrackingLocationSample(
  accuracyMeters: 8,
  latitude: 41.8781,
  longitude: -87.6298,
  recordedAt: DateTime.utc(2026, 8, 28, 12),
  speedMetersPerSecond: speed,
);

void main() {
  test('starts an eligible active load and adapts foreground cadence to motion', () async {
    final gateway = _RecordingGateway();
    final platform = _FakeLocationPlatform(
      permissionSnapshot: _alwaysPrecise,
      samples: <Future<TrackingLocationSample>>[
        Future<TrackingLocationSample>.value(_sample()),
      ],
    );
    final timers = _FakeTimerFactory();
    final context = _FakeTrackingContextRepository(_activeTrackingContext);
    final coordinator = DriverTrackingRuntimeCoordinator(
      clock: () => DateTime.utc(2026, 8, 28, 12),
      locationPlatform: platform,
      service: TrackingService(gateway: gateway),
      timerFactory: timers,
      trackingContextRepository: context,
    );
    addTearDown(coordinator.dispose);

    await coordinator.refreshAuthorizedTrackingContext();

    expect(platform.permissionCalls, 1);
    expect(platform.captureCalls, 1);
    expect(gateway.samples, hasLength(1));
    expect(timers.timers.single.interval, const Duration(seconds: 15));
    expect(coordinator.permissionState.value?.kind, TrackingPermissionKind.ready);
  });

  test('does not capture without an active authorized load or after force-quit', () async {
    final platform = _FakeLocationPlatform(
      permissionSnapshot: _alwaysPrecise,
      samples: <Future<TrackingLocationSample>>[
        Future<TrackingLocationSample>.value(_sample()),
      ],
    );
    final context = _FakeTrackingContextRepository(_inactiveTrackingContext);
    final coordinator = DriverTrackingRuntimeCoordinator(
      clock: () => DateTime.utc(2026, 8, 28, 12),
      locationPlatform: platform,
      service: TrackingService(gateway: _RecordingGateway()),
      timerFactory: _FakeTimerFactory(),
      trackingContextRepository: context,
    );
    addTearDown(coordinator.dispose);

    await coordinator.refreshAuthorizedTrackingContext();
    expect(platform.permissionCalls, 0);
    expect(platform.captureCalls, 0);

    coordinator.stopForForceQuit();
    context.context = _activeTrackingContext;
    await coordinator.refreshAuthorizedTrackingContext();
    expect(platform.permissionCalls, 0);
    expect(platform.captureCalls, 0);
    expect(
      coordinator.permissionState.value?.kind,
      TrackingPermissionKind.forceQuit,
    );
  });

  test('starts visible foreground tracking for an on-duty driver without a load', () async {
    final platform = _FakeLocationPlatform(
      permissionSnapshot: _alwaysPrecise,
      samples: <Future<TrackingLocationSample>>[
        Future<TrackingLocationSample>.value(_sample()),
      ],
    );
    final context = _FakeTrackingContextRepository(_onDutyTrackingContext);
    final gateway = _RecordingGateway();
    final coordinator = DriverTrackingRuntimeCoordinator(
      clock: () => DateTime.utc(2026, 8, 28, 12),
      locationPlatform: platform,
      service: TrackingService(gateway: gateway),
      timerFactory: _FakeTimerFactory(),
      trackingContextRepository: context,
    );
    addTearDown(coordinator.dispose);

    await coordinator.refreshAuthorizedTrackingContext();

    expect(platform.permissionCalls, 1);
    expect(platform.captureCalls, 1);
    expect(gateway.samples, hasLength(1));
  });

  test('never continues background tracking for an on-duty driver without an active load', () async {
    final gateway = _RecordingGateway();
    final platform = _FakeLocationPlatform(
      permissionSnapshot: _alwaysPrecise,
      samples: <Future<TrackingLocationSample>>[
        Future<TrackingLocationSample>.value(_sample()),
      ],
    );
    final timers = _FakeTimerFactory();
    final coordinator = DriverTrackingRuntimeCoordinator(
      clock: () => DateTime.utc(2026, 8, 28, 12),
      locationPlatform: platform,
      service: TrackingService(gateway: gateway),
      timerFactory: timers,
      trackingContextRepository: _FakeTrackingContextRepository(
        _onDutyTrackingContext,
      ),
    );
    addTearDown(coordinator.dispose);

    await coordinator.refreshAuthorizedTrackingContext();
    await coordinator.updateAppVisibility(false);

    expect(gateway.samples, hasLength(1));
    expect(timers.timers.single.cancelled, isTrue);
  });

  test('uses OS-scheduled best-effort work instead of a Dart timer for a background active load', () async {
    final gateway = _RecordingGateway();
    final platform = _FakeLocationPlatform(
      permissionSnapshot: _alwaysPrecise,
      samples: <Future<TrackingLocationSample>>[
        Future<TrackingLocationSample>.value(_sample()),
      ],
    );
    final timers = _FakeTimerFactory();
    final backgroundWork = _FakeBackgroundWorkScheduler();
    final coordinator = DriverTrackingRuntimeCoordinator(
      backgroundWorkScheduler: backgroundWork,
      clock: () => DateTime.utc(2026, 8, 28, 12),
      locationPlatform: platform,
      service: TrackingService(gateway: gateway),
      timerFactory: timers,
      trackingContextRepository: _FakeTrackingContextRepository(_activeTrackingContext),
    );
    addTearDown(coordinator.dispose);

    await coordinator.refreshAuthorizedTrackingContext();
    await coordinator.updateAppVisibility(false);

    expect(gateway.samples, hasLength(1));
    expect(timers.timers.single.cancelled, isTrue);
    expect(backgroundWork.scheduledContexts, hasLength(1));
    expect(backgroundWork.scheduledContexts.single.hasActiveLoad, isTrue);

    coordinator.stopForForceQuit();
    expect(backgroundWork.cancellations, greaterThanOrEqualTo(1));
  });

  test(
    'does not send while backgrounded with while-in-use permission and resumes in the foreground',
    () async {
      final gateway = _RecordingGateway();
      final platform = _FakeLocationPlatform(
        permissionSnapshot: const TrackingPlatformSnapshot(
          accuracy: TrackingAccuracy.precise,
          batteryRestricted: false,
          permission: TrackingPlatformPermission.whileInUse,
          serviceEnabled: true,
        ),
        samples: <Future<TrackingLocationSample>>[
          Future<TrackingLocationSample>.value(_sample()),
          Future<TrackingLocationSample>.value(_sample()),
        ],
      );
      final context = _FakeTrackingContextRepository(_activeTrackingContext);
      final coordinator = DriverTrackingRuntimeCoordinator(
        clock: () => DateTime.utc(2026, 8, 28, 12),
        locationPlatform: platform,
        service: TrackingService(gateway: gateway),
        timerFactory: _FakeTimerFactory(),
        trackingContextRepository: context,
      );
      addTearDown(coordinator.dispose);

      await coordinator.refreshAuthorizedTrackingContext();
      expect(gateway.samples, hasLength(1));

      await coordinator.updateAppVisibility(false);
      expect(gateway.samples, hasLength(1));
      expect(
        coordinator.permissionState.value?.kind,
        TrackingPermissionKind.backgroundLimited,
      );

      await coordinator.updateAppVisibility(true);
      expect(gateway.samples, hasLength(2));
      expect(platform.requestedForeground, <bool>[true, false, true]);
    },
  );

  test('does not overlap timer captures and uses a sixty-second stopped cadence', () async {
    final delayed = Completer<TrackingLocationSample>();
    final gateway = _RecordingGateway();
    final platform = _FakeLocationPlatform(
      permissionSnapshot: _alwaysPrecise,
      samples: <Future<TrackingLocationSample>>[
        Future<TrackingLocationSample>.value(_sample(speed: 0)),
        delayed.future,
      ],
    );
    final timers = _FakeTimerFactory();
    final context = _FakeTrackingContextRepository(_activeTrackingContext);
    final coordinator = DriverTrackingRuntimeCoordinator(
      clock: () => DateTime.utc(2026, 8, 28, 12),
      locationPlatform: platform,
      service: TrackingService(gateway: gateway),
      timerFactory: timers,
      trackingContextRepository: context,
    );
    addTearDown(coordinator.dispose);

    await coordinator.refreshAuthorizedTrackingContext();
    expect(timers.timers.single.interval, const Duration(seconds: 60));

    timers.timers.single.fire();
    await Future<void>.delayed(Duration.zero);
    timers.timers.single.fire();
    await Future<void>.delayed(Duration.zero);
    expect(platform.captureCalls, 2);

    delayed.complete(_sample(speed: 0));
    await Future<void>.delayed(Duration.zero);
    expect(gateway.samples, hasLength(2));
  });

  test(
    'restarts the latest eligible plan after a stale capture releases during lifecycle reconfiguration',
    () async {
      final heldSample = Completer<TrackingLocationSample>();
      final gateway = _RecordingGateway();
      final context = _FakeTrackingContextRepository(_onDutyTrackingContext);
      final platform = _FakeLocationPlatform(
        permissionSnapshot: _alwaysPrecise,
        samples: <Future<TrackingLocationSample>>[
          heldSample.future,
          Future<TrackingLocationSample>.value(
            TrackingLocationSample(
              accuracyMeters: 8,
              latitude: 41.9,
              longitude: -87.7,
              recordedAt: DateTime.utc(2026, 8, 28, 12, 1),
              speedMetersPerSecond: 12,
            ),
          ),
        ],
      );
      final timers = _FakeTimerFactory();
      final backgroundWork = _FakeBackgroundWorkScheduler();
      final coordinator = DriverTrackingRuntimeCoordinator(
        backgroundWorkScheduler: backgroundWork,
        clock: () => DateTime.utc(2026, 8, 28, 12),
        locationPlatform: platform,
        service: TrackingService(gateway: gateway),
        timerFactory: timers,
        trackingContextRepository: context,
      );
      addTearDown(coordinator.dispose);

      final initial = coordinator.refreshAuthorizedTrackingContext();
      await Future<void>.delayed(Duration.zero);
      expect(platform.captureCalls, 1);

      final visibilityUpdate = coordinator.updateAppVisibility(false);
      context.context = _activeTrackingContext;
      final contextUpdate = coordinator.refreshAuthorizedTrackingContext();
      heldSample.complete(_sample());

      await Future.wait<void>(<Future<void>>[
        initial,
        visibilityUpdate,
        contextUpdate,
      ]);

      expect(platform.captureCalls, 1);
      expect(gateway.samples, isEmpty);
      expect(timers.timers, isEmpty);
      expect(backgroundWork.scheduledContexts, hasLength(1));
      expect(backgroundWork.scheduledContexts.single.hasActiveLoad, isTrue);
    },
  );
}

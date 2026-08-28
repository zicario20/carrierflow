import 'package:carrierflow_driver/features/tracking/tracking_authorization.dart';
import 'package:carrierflow_driver/features/tracking/tracking_background_work.dart';
import 'package:carrierflow_driver/features/tracking/tracking_permission_state.dart';
import 'package:carrierflow_driver/features/tracking/tracking_runtime_coordinator.dart';
import 'package:carrierflow_driver/features/tracking/tracking_service.dart';
import 'package:flutter_test/flutter_test.dart';

final class _BackgroundGateway implements TrackingGateway {
  final List<TrackingLocationSample> samples = <TrackingLocationSample>[];

  @override
  Future<TrackingSubmissionReceipt> recordOwnLocation(
    TrackingLocationSample sample,
  ) async {
    samples.add(sample);
    return TrackingSubmissionReceipt(recordedAt: sample.recordedAt);
  }
}

final class _BackgroundContextRepository
    implements OwnDriverTrackingContextRepository {
  _BackgroundContextRepository(this.context);

  AuthorizedDriverTrackingContext context;
  var calls = 0;

  @override
  Future<AuthorizedDriverTrackingContext>
  fetchOwnDriverTrackingContext() async {
    calls += 1;
    return context;
  }
}

final class _BackgroundLocationPlatform implements TrackingLocationPlatform {
  _BackgroundLocationPlatform(this.snapshot);

  TrackingPlatformSnapshot snapshot;
  var captureCalls = 0;
  final List<bool> foregroundRequests = <bool>[];

  @override
  Future<TrackingLocationSample> captureCurrentLocation() async {
    captureCalls += 1;
    return TrackingLocationSample(
      accuracyMeters: 8,
      latitude: 41.8781,
      longitude: -87.6298,
      recordedAt: DateTime.utc(2026, 8, 28, 12),
    );
  }

  @override
  Future<TrackingPlatformSnapshot> requestPermissionState({
    required bool requestForeground,
  }) async {
    foregroundRequests.add(requestForeground);
    return snapshot;
  }
}

final class _BackgroundScheduler implements TrackingBackgroundWorkScheduler {
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

final class _NativeWorkClient implements NativeBackgroundWorkClient {
  final List<({Duration delay, String taskName, String uniqueName})> requests =
      <({Duration delay, String taskName, String uniqueName})>[];
  var cancellations = 0;

  @override
  Future<void> cancelByUniqueName(String uniqueName) async {
    cancellations += 1;
  }

  @override
  Future<void> registerOneOff({
    required Duration initialDelay,
    required String taskName,
    required String uniqueName,
  }) async {
    requests.add((
      delay: initialDelay,
      taskName: taskName,
      uniqueName: uniqueName,
    ));
  }
}

const _alwaysPrecise = TrackingPlatformSnapshot(
  accuracy: TrackingAccuracy.precise,
  batteryRestricted: false,
  permission: TrackingPlatformPermission.always,
  serviceEnabled: true,
);

void main() {
  test('native scheduler receives only fixed task metadata after active-load and Always checks', () async {
    final native = _NativeWorkClient();
    final scheduler = WorkmanagerTrackingBackgroundWorkScheduler(client: native);
    final permission = TrackingPermissionState.assess(
      accuracy: TrackingAccuracy.precise,
      batteryRestricted: false,
      now: DateTime.utc(2026, 8, 28, 12),
      permission: TrackingPlatformPermission.always,
      processWasForceQuit: false,
      serviceEnabled: true,
    );

    await scheduler.scheduleForActiveLoad(
      context: const TrackingContext(
        appVisible: false,
        hasActiveLoad: true,
        isOnDuty: false,
      ),
      permission: permission,
    );

    expect(native.requests, <({Duration delay, String taskName, String uniqueName})>[
      (
        delay: const Duration(minutes: 1),
        taskName: carrierFlowTrackingBackgroundWorkName,
        uniqueName: carrierFlowTrackingBackgroundWorkUniqueName,
      ),
    ]);
    expect(native.cancellations, 0);
  });

  test('background work reacquires zero-scope eligibility before sampling and rescheduling', () async {
    final gateway = _BackgroundGateway();
    final context = _BackgroundContextRepository(
      const AuthorizedDriverTrackingContext(isOnDuty: false, hasActiveLoad: true),
    );
    final platform = _BackgroundLocationPlatform(_alwaysPrecise);
    final scheduler = _BackgroundScheduler();
    final work = DriverTrackingBackgroundTask(
      clock: () => DateTime.utc(2026, 8, 28, 12),
      locationPlatform: platform,
      scheduler: scheduler,
      service: TrackingService(gateway: gateway),
      trackingContextRepository: context,
    );

    expect(await work.run(), isTrue);

    expect(context.calls, 1);
    expect(platform.foregroundRequests, <bool>[false]);
    expect(platform.captureCalls, 1);
    expect(gateway.samples, hasLength(1));
    expect(scheduler.scheduledContexts, hasLength(1));
    expect(scheduler.scheduledContexts.single.hasActiveLoad, isTrue);
  });

  test('background work cancels rather than sampling or scheduling without an active load and always permission', () async {
    final gateway = _BackgroundGateway();
    final context = _BackgroundContextRepository(
      const AuthorizedDriverTrackingContext(isOnDuty: true, hasActiveLoad: false),
    );
    final platform = _BackgroundLocationPlatform(_alwaysPrecise);
    final scheduler = _BackgroundScheduler();
    final work = DriverTrackingBackgroundTask(
      clock: () => DateTime.utc(2026, 8, 28, 12),
      locationPlatform: platform,
      scheduler: scheduler,
      service: TrackingService(gateway: gateway),
      trackingContextRepository: context,
    );

    expect(await work.run(), isTrue);

    expect(platform.foregroundRequests, isEmpty);
    expect(platform.captureCalls, 0);
    expect(gateway.samples, isEmpty);
    expect(scheduler.scheduledContexts, isEmpty);
    expect(scheduler.cancellations, 1);
  });

  test('background work cancels an active load when Always permission is no longer granted', () async {
    final gateway = _BackgroundGateway();
    final context = _BackgroundContextRepository(
      const AuthorizedDriverTrackingContext(isOnDuty: false, hasActiveLoad: true),
    );
    final platform = _BackgroundLocationPlatform(
      const TrackingPlatformSnapshot(
        accuracy: TrackingAccuracy.precise,
        batteryRestricted: false,
        permission: TrackingPlatformPermission.whileInUse,
        serviceEnabled: true,
      ),
    );
    final scheduler = _BackgroundScheduler();
    final work = DriverTrackingBackgroundTask(
      clock: () => DateTime.utc(2026, 8, 28, 12),
      locationPlatform: platform,
      scheduler: scheduler,
      service: TrackingService(gateway: gateway),
      trackingContextRepository: context,
    );

    expect(await work.run(), isTrue);

    expect(platform.foregroundRequests, <bool>[false]);
    expect(platform.captureCalls, 0);
    expect(gateway.samples, isEmpty);
    expect(scheduler.scheduledContexts, isEmpty);
    expect(scheduler.cancellations, 1);
  });
}

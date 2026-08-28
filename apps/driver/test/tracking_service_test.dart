import 'package:carrierflow_driver/features/tracking/tracking_permission_state.dart';
import 'package:carrierflow_driver/features/tracking/tracking_service.dart';
import 'package:carrierflow_driver/core/bootstrap/driver_execution_repository.dart';
import 'package:flutter_test/flutter_test.dart';

final class _RecordingTrackingGateway implements TrackingGateway {
  final List<TrackingLocationSample> submitted = <TrackingLocationSample>[];

  @override
  Future<TrackingSubmissionReceipt> recordOwnLocation(
    TrackingLocationSample sample,
  ) async {
    submitted.add(sample);
    return TrackingSubmissionReceipt(recordedAt: sample.recordedAt);
  }
}

final class _FakeDriverRpcGateway implements DriverExecutionRpcGateway {
  String? currentUserId = 'driver-session';
  String? invokedName;
  Map<String, dynamic>? invokedArguments;
  void Function()? onInvoke;

  @override
  Future<Object?> invoke(
    String functionName, {
    Map<String, dynamic> arguments = const <String, dynamic>{},
  }) async {
    invokedName = functionName;
    invokedArguments = arguments;
    onInvoke?.call();
    return <String, Object?>{'recordedAt': '2026-08-28T12:00:00.000Z'};
  }
}

void main() {
  final now = DateTime.utc(2026, 8, 28, 12);
  final preciseBackgroundPermission = TrackingPermissionState.assess(
    accuracy: TrackingAccuracy.precise,
    batteryRestricted: false,
    now: now,
    permission: TrackingPlatformPermission.always,
    processWasForceQuit: false,
    serviceEnabled: true,
  );

  test('uses adaptive intervals for visible on-duty and active-load tracking', () {
    final service = TrackingService(gateway: _RecordingTrackingGateway());

    expect(
      service.plan(
        context: const TrackingContext(
          appVisible: true,
          hasActiveLoad: false,
          isOnDuty: true,
        ),
        permission: preciseBackgroundPermission,
        isMoving: true,
      ),
      const TrackingPlan.foreground(interval: Duration(seconds: 15)),
    );
    expect(
      service.plan(
        context: const TrackingContext(
          appVisible: false,
          hasActiveLoad: true,
          isOnDuty: false,
        ),
        permission: preciseBackgroundPermission,
        isMoving: false,
      ),
      const TrackingPlan.backgroundBestEffort(interval: Duration(seconds: 60)),
    );
  });

  test('reports denied, approximate, stale, and background-limited states without overpromising', () {
    expect(
      TrackingPermissionState.assess(
        accuracy: TrackingAccuracy.precise,
        batteryRestricted: false,
        now: now,
        permission: TrackingPlatformPermission.denied,
        processWasForceQuit: false,
        serviceEnabled: true,
      ).kind,
      TrackingPermissionKind.denied,
    );
    expect(
      TrackingPermissionState.assess(
        accuracy: TrackingAccuracy.reduced,
        batteryRestricted: false,
        now: now,
        permission: TrackingPlatformPermission.whileInUse,
        processWasForceQuit: false,
        serviceEnabled: true,
      ).kind,
      TrackingPermissionKind.approximate,
    );
    expect(
      TrackingPermissionState.assess(
        accuracy: TrackingAccuracy.precise,
        batteryRestricted: true,
        now: now,
        permission: TrackingPlatformPermission.always,
        processWasForceQuit: false,
        serviceEnabled: true,
      ).kind,
      TrackingPermissionKind.batteryRestricted,
    );
    expect(
      TrackingPermissionState.assess(
        accuracy: TrackingAccuracy.precise,
        batteryRestricted: false,
        lastSampleAt: now.subtract(const Duration(minutes: 6)),
        now: now,
        permission: TrackingPlatformPermission.always,
        processWasForceQuit: false,
        serviceEnabled: true,
      ).kind,
      TrackingPermissionKind.stale,
    );
  });

  test('does not claim background tracking after a force-quit', () {
    final service = TrackingService(gateway: _RecordingTrackingGateway());
    final forceQuit = TrackingPermissionState.assess(
      accuracy: TrackingAccuracy.precise,
      batteryRestricted: false,
      now: now,
      permission: TrackingPlatformPermission.always,
      processWasForceQuit: true,
      serviceEnabled: true,
    );

    expect(forceQuit.kind, TrackingPermissionKind.forceQuit);
    expect(
      service.plan(
        context: const TrackingContext(
          appVisible: false,
          hasActiveLoad: true,
          isOnDuty: true,
        ),
        permission: forceQuit,
        isMoving: true,
      ),
      const TrackingPlan.inactive(),
    );
  });

  test('submits only finite in-bounds authorized samples through the RPC gateway', () async {
    final gateway = _RecordingTrackingGateway();
    final service = TrackingService(gateway: gateway);
    final context = const TrackingContext(
      appVisible: true,
      hasActiveLoad: true,
      isOnDuty: true,
    );
    final valid = TrackingLocationSample(
      accuracyMeters: 9,
      headingDegrees: 90,
      latitude: 41.8781,
      longitude: -87.6298,
      recordedAt: now,
      speedMetersPerSecond: 12,
    );

    expect(
      await service.recordIfEligible(
        context: context,
        permission: preciseBackgroundPermission,
        sample: valid,
      ),
      isA<TrackingSubmissionRecorded>(),
    );
    expect(gateway.submitted, <TrackingLocationSample>[valid]);

    final invalid = TrackingLocationSample(
      accuracyMeters: 9,
      latitude: 91,
      longitude: -87.6298,
      recordedAt: now,
    );
    expect(
      await service.recordIfEligible(
        context: context,
        permission: preciseBackgroundPermission,
        sample: invalid,
      ),
      isA<TrackingSubmissionRejected>(),
    );
    expect(gateway.submitted, <TrackingLocationSample>[valid]);
  });

  test(
    'does not submit a background sample without an active load and always permission',
    () async {
      final gateway = _RecordingTrackingGateway();
      final service = TrackingService(gateway: gateway);
      final whileInUse = TrackingPermissionState.assess(
        accuracy: TrackingAccuracy.precise,
        batteryRestricted: false,
        now: now,
        permission: TrackingPlatformPermission.whileInUse,
        processWasForceQuit: false,
        serviceEnabled: true,
      );
      final sample = TrackingLocationSample(
        accuracyMeters: 9,
        latitude: 41.8781,
        longitude: -87.6298,
        recordedAt: now,
      );

      expect(
        await service.recordIfEligible(
          context: const TrackingContext(
            appVisible: false,
            hasActiveLoad: true,
            isOnDuty: true,
          ),
          permission: whileInUse,
          sample: sample,
        ),
        isA<TrackingSubmissionRejected>(),
      );
      expect(gateway.submitted, isEmpty);
    },
  );

  test('uses the authenticated zero-scope RPC without a company, driver, or load id', () async {
    final rpc = _FakeDriverRpcGateway();
    final gateway = SupabaseTrackingGateway(rpc);
    final sample = TrackingLocationSample(
      accuracyMeters: 9,
      headingDegrees: 90,
      latitude: 41.8781,
      longitude: -87.6298,
      recordedAt: now,
      speedMetersPerSecond: 12,
    );

    await gateway.recordOwnLocation(sample);

    expect(rpc.invokedName, 'record_own_driver_location_sample');
    expect(rpc.invokedArguments, <String, dynamic>{
      'accuracy_meters_value': 9,
      'heading_degrees_value': 90,
      'latitude_value': 41.8781,
      'longitude_value': -87.6298,
      'recorded_at_value': now.toIso8601String(),
      'speed_meters_per_second_value': 12,
    });
    expect(rpc.invokedArguments!.keys, isNot(contains(anyOf('company_id', 'driver_id', 'load_id'))));
  });

  test('rejects a location acknowledgement when the initiating driver session changes', () async {
    final rpc = _FakeDriverRpcGateway();
    rpc.onInvoke = () => rpc.currentUserId = 'different-driver-session';
    final gateway = SupabaseTrackingGateway(rpc);
    final sample = TrackingLocationSample(
      accuracyMeters: 9,
      latitude: 41.8781,
      longitude: -87.6298,
      recordedAt: now,
    );

    await expectLater(gateway.recordOwnLocation(sample), throwsA(isA<StateError>()));
  });
}

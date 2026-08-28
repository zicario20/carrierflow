import 'package:carrierflow_driver/features/tracking/tracking_authorization.dart';
import 'package:carrierflow_driver/features/tracking/tracking_permission_state.dart';
import 'package:carrierflow_driver/features/tracking/tracking_runtime_coordinator.dart';
import 'package:carrierflow_driver/features/tracking/tracking_service.dart';
import 'package:workmanager/workmanager.dart';

const carrierFlowTrackingBackgroundWorkName =
    'carrierflow.driver.active-load-location';
const carrierFlowTrackingBackgroundWorkUniqueName =
    'carrierflow.driver.active-load-location.unique';

/// Platform scheduling has no tenant, user, driver, vehicle, or load inputs.
/// The background isolate must reacquire its eligibility through the zero-scope
/// repository before it can read GPS or send an own-location RPC.
abstract interface class TrackingBackgroundWorkScheduler {
  Future<void> cancel();

  Future<void> scheduleForActiveLoad({
    required TrackingContext context,
    required TrackingPermissionState permission,
  });
}

/// Narrow adapter around the native scheduler. Its fixed metadata-only shape
/// makes it impossible for a caller to serialize a tenant, user, driver, or
/// load identifier into an Android/iOS work request.
abstract interface class NativeBackgroundWorkClient {
  Future<void> cancelByUniqueName(String uniqueName);

  Future<void> registerOneOff({
    required Duration initialDelay,
    required String taskName,
    required String uniqueName,
  });
}

final class WorkmanagerNativeBackgroundWorkClient
    implements NativeBackgroundWorkClient {
  WorkmanagerNativeBackgroundWorkClient({Workmanager? workmanager})
    : _workmanager = workmanager ?? Workmanager();

  final Workmanager _workmanager;

  @override
  Future<void> cancelByUniqueName(String uniqueName) =>
      _workmanager.cancelByUniqueName(uniqueName);

  @override
  Future<void> registerOneOff({
    required Duration initialDelay,
    required String taskName,
    required String uniqueName,
  }) => _workmanager.registerOneOffTask(
    uniqueName,
    taskName,
    initialDelay: initialDelay,
  );
}

/// Test/default-safe scheduler. The application bootstrap injects the
/// Workmanager-backed implementation on Android and iOS.
final class NoopTrackingBackgroundWorkScheduler
    implements TrackingBackgroundWorkScheduler {
  const NoopTrackingBackgroundWorkScheduler();

  @override
  Future<void> cancel() => Future<void>.value();

  @override
  Future<void> scheduleForActiveLoad({
    required TrackingContext context,
    required TrackingPermissionState permission,
  }) => Future<void>.value();
}

/// A one-off native work request rather than a Dart timer. Android WorkManager
/// and iOS BGTask scheduling remain OS-controlled: this queues an opportunity,
/// never a guarantee of timing or execution after a force-quit.
final class WorkmanagerTrackingBackgroundWorkScheduler
    implements TrackingBackgroundWorkScheduler {
  WorkmanagerTrackingBackgroundWorkScheduler({NativeBackgroundWorkClient? client})
    : _client = client ?? WorkmanagerNativeBackgroundWorkClient();

  final NativeBackgroundWorkClient _client;

  @override
  Future<void> cancel() =>
      _client.cancelByUniqueName(carrierFlowTrackingBackgroundWorkUniqueName);

  @override
  Future<void> scheduleForActiveLoad({
    required TrackingContext context,
    required TrackingPermissionState permission,
  }) async {
    if (!context.hasActiveLoad || !permission.canRequestBackground) {
      await cancel();
      return;
    }

    // No inputData: every identity and operational fact is reacquired from
    // the authenticated client session inside the background task.
    await _client.registerOneOff(
      initialDelay: const Duration(minutes: 1),
      taskName: carrierFlowTrackingBackgroundWorkName,
      uniqueName: carrierFlowTrackingBackgroundWorkUniqueName,
    );
  }
}

/// Runs in a native background isolate only after the OS chooses to execute a
/// task. It fails closed: no active load, non-Always permission, unavailable
/// service, or any error produces no capture and cancels the pending request.
final class DriverTrackingBackgroundTask {
  DriverTrackingBackgroundTask({
    required DateTime Function() clock,
    required TrackingLocationPlatform locationPlatform,
    required TrackingBackgroundWorkScheduler scheduler,
    required TrackingService service,
    required OwnDriverTrackingContextRepository trackingContextRepository,
  }) : _clock = clock,
       _locationPlatform = locationPlatform,
       _scheduler = scheduler,
       _service = service,
       _trackingContextRepository = trackingContextRepository;

  final DateTime Function() _clock;
  final TrackingLocationPlatform _locationPlatform;
  final TrackingBackgroundWorkScheduler _scheduler;
  final TrackingService _service;
  final OwnDriverTrackingContextRepository _trackingContextRepository;

  Future<bool> run() async {
    try {
      final authorized = await _trackingContextRepository
          .fetchOwnDriverTrackingContext();
      if (!authorized.hasActiveLoad) {
        await _scheduler.cancel();
        return true;
      }

      final snapshot = await _locationPlatform.requestPermissionState(
        requestForeground: false,
      );
      final permission = TrackingPermissionState.assess(
        accuracy: snapshot.accuracy,
        batteryRestricted: snapshot.batteryRestricted,
        now: _clock().toUtc(),
        permission: snapshot.permission,
        processWasForceQuit: false,
        serviceEnabled: snapshot.serviceEnabled,
      );
      final context = TrackingContext(
        appVisible: false,
        hasActiveLoad: authorized.hasActiveLoad,
        isOnDuty: authorized.isOnDuty,
      );
      if (!permission.canRequestBackground) {
        await _scheduler.cancel();
        return true;
      }

      // Queue only after the background isolate independently proves active
      // load + Always permission; it remains an OS-controlled opportunity.
      await _scheduler.scheduleForActiveLoad(
        context: context,
        permission: permission,
      );
      final sample = await _locationPlatform.captureCurrentLocation();
      await _service.recordIfEligible(
        context: context,
        permission: permission,
        sample: sample,
      );
      return true;
    } on Object {
      await _cancelSafely();
      return false;
    }
  }

  Future<void> _cancelSafely() async {
    try {
      await _scheduler.cancel();
    } on Object {
      // The OS may already have removed work. There is no retry claim here.
    }
  }
}

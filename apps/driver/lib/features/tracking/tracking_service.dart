import 'package:carrierflow_driver/core/bootstrap/driver_execution_repository.dart';
import 'package:carrierflow_driver/features/tracking/tracking_permission_state.dart';

enum TrackingCollectionMode { inactive, foreground, backgroundBestEffort }

final class TrackingContext {
  const TrackingContext({
    required this.appVisible,
    required this.hasActiveLoad,
    required this.isOnDuty,
  });

  final bool appVisible;
  final bool hasActiveLoad;
  final bool isOnDuty;

  bool get isEligible => (isOnDuty && appVisible) || hasActiveLoad;
}

final class TrackingPlan {
  const TrackingPlan._({required this.interval, required this.mode});

  const TrackingPlan.backgroundBestEffort({required Duration interval})
    : this._(
        interval: interval,
        mode: TrackingCollectionMode.backgroundBestEffort,
      );

  const TrackingPlan.foreground({required Duration interval})
    : this._(interval: interval, mode: TrackingCollectionMode.foreground);

  const TrackingPlan.inactive()
    : this._(interval: null, mode: TrackingCollectionMode.inactive);

  final Duration? interval;
  final TrackingCollectionMode mode;

  @override
  bool operator ==(Object other) =>
      other is TrackingPlan && other.interval == interval && other.mode == mode;

  @override
  int get hashCode => Object.hash(interval, mode);
}

final class TrackingLocationSample {
  const TrackingLocationSample({
    required this.accuracyMeters,
    required this.latitude,
    required this.longitude,
    required this.recordedAt,
    this.headingDegrees,
    this.speedMetersPerSecond,
  });

  final double accuracyMeters;
  final double? headingDegrees;
  final double latitude;
  final double longitude;
  final DateTime recordedAt;
  final double? speedMetersPerSecond;

  bool get isValid =>
      _isFinite(latitude) &&
      _isFinite(longitude) &&
      _isFinite(accuracyMeters) &&
      accuracyMeters >= 0 &&
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180 &&
      (headingDegrees == null ||
          (_isFinite(headingDegrees!) &&
              headingDegrees! >= 0 &&
              headingDegrees! < 360)) &&
      (speedMetersPerSecond == null ||
          (_isFinite(speedMetersPerSecond!) && speedMetersPerSecond! >= 0));

  static bool _isFinite(double value) => value.isFinite && !value.isNaN;
}

final class TrackingSubmissionReceipt {
  const TrackingSubmissionReceipt({required this.recordedAt});

  final DateTime recordedAt;
}

/// This is intentionally a narrow, zero-scope RPC capability. The transport
/// never receives a company, driver, vehicle, or load identifier.
abstract interface class TrackingGateway {
  Future<TrackingSubmissionReceipt> recordOwnLocation(
    TrackingLocationSample sample,
  );
}

/// Production transport remains session-bound and invokes only the database's
/// own-driver location RPC. It cannot name a company, driver, vehicle, or
/// load, and it does not use table DML or a service credential.
final class SupabaseTrackingGateway implements TrackingGateway {
  SupabaseTrackingGateway(this._gateway);

  final DriverExecutionRpcGateway _gateway;

  @override
  Future<TrackingSubmissionReceipt> recordOwnLocation(
    TrackingLocationSample sample,
  ) async {
    final initiatingUserId = _gateway.currentUserId;
    if (initiatingUserId == null) {
      throw StateError('an authenticated driver session is required');
    }
    if (_gateway.currentUserId != initiatingUserId) {
      throw StateError('the driver session changed while recording location');
    }
    final response = await _gateway.invoke(
      'record_own_driver_location_sample',
      arguments: <String, dynamic>{
        'accuracy_meters_value': sample.accuracyMeters,
        'heading_degrees_value': sample.headingDegrees,
        'latitude_value': sample.latitude,
        'longitude_value': sample.longitude,
        'recorded_at_value': sample.recordedAt.toUtc().toIso8601String(),
        'speed_meters_per_second_value': sample.speedMetersPerSecond,
      },
    );
    if (_gateway.currentUserId != initiatingUserId) {
      throw StateError('the driver session changed while recording location');
    }
    final map = response is Map<Object?, Object?> ? response : null;
    final recordedAtValue = map?['recordedAt'];
    final recordedAt = recordedAtValue is String
        ? DateTime.tryParse(recordedAtValue)?.toUtc()
        : null;
    if (recordedAt == null) {
      throw StateError('the location acknowledgement was invalid');
    }
    return TrackingSubmissionReceipt(recordedAt: recordedAt);
  }
}

sealed class TrackingSubmission {
  const TrackingSubmission();
}

final class TrackingSubmissionRecorded extends TrackingSubmission {
  const TrackingSubmissionRecorded(this.receipt);

  final TrackingSubmissionReceipt receipt;
}

final class TrackingSubmissionRejected extends TrackingSubmission {
  const TrackingSubmissionRejected({required this.reason});

  final TrackingSubmissionRejection reason;
}

enum TrackingSubmissionRejection { invalidSample, notEligible, permission }

/// Plans conservative samples and ensures invalid/degraded readings never
/// reach transport. Background is explicitly best effort: the OS can stop it
/// at any time and a force-quit never creates a background plan.
final class TrackingService {
  TrackingService({required TrackingGateway gateway}) : _gateway = gateway;

  final TrackingGateway _gateway;

  TrackingPlan plan({
    required TrackingContext context,
    required TrackingPermissionState permission,
    required bool isMoving,
  }) {
    if (!context.isEligible || !permission.canCollectForeground) {
      return const TrackingPlan.inactive();
    }

    if (!context.appVisible) {
      return context.hasActiveLoad && permission.canRequestBackground
          ? const TrackingPlan.backgroundBestEffort(
              interval: Duration(seconds: 60),
            )
          : const TrackingPlan.inactive();
    }

    return TrackingPlan.foreground(
      interval: isMoving
          ? const Duration(seconds: 15)
          : const Duration(seconds: 60),
    );
  }

  Future<TrackingSubmission> recordIfEligible({
    required TrackingContext context,
    required TrackingPermissionState permission,
    required TrackingLocationSample sample,
  }) async {
    if (!sample.isValid) {
      return const TrackingSubmissionRejected(
        reason: TrackingSubmissionRejection.invalidSample,
      );
    }
    if (!context.isEligible) {
      return const TrackingSubmissionRejected(
        reason: TrackingSubmissionRejection.notEligible,
      );
    }
    if (!context.appVisible &&
        (!context.hasActiveLoad || !permission.canRequestBackground)) {
      return const TrackingSubmissionRejected(
        reason: TrackingSubmissionRejection.permission,
      );
    }
    if (!permission.canCollectForeground) {
      return const TrackingSubmissionRejected(
        reason: TrackingSubmissionRejection.permission,
      );
    }

    final receipt = await _gateway.recordOwnLocation(sample);
    return TrackingSubmissionRecorded(receipt);
  }
}

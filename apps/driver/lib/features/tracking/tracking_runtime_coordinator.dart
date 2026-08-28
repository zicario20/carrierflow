import 'dart:async';

import 'package:carrierflow_driver/features/tracking/tracking_authorization.dart';
import 'package:carrierflow_driver/features/tracking/tracking_background_work.dart';
import 'package:carrierflow_driver/features/tracking/tracking_permission_state.dart';
import 'package:carrierflow_driver/features/tracking/tracking_service.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// Lifecycle surface consumed by the app shell. It reads only a server-derived
/// eligibility context; it never accepts a tenant, driver, or load ID.
abstract interface class DriverTrackingLifecycle {
  ValueListenable<TrackingPermissionState?> get permissionState;

  void dispose();
  void stop();
  void stopForForceQuit();
  Future<void> updateAppVisibility(bool appVisible);
  Future<void> refreshAuthorizedTrackingContext();
}

final class TrackingPlatformSnapshot {
  const TrackingPlatformSnapshot({
    required this.accuracy,
    required this.batteryRestricted,
    required this.permission,
    required this.serviceEnabled,
  });

  final TrackingAccuracy accuracy;
  final bool batteryRestricted;
  final TrackingPlatformPermission permission;
  final bool serviceEnabled;
}

/// The only hardware boundary. Implementations receive neither tenant nor load
/// data, and the coordinator calls it only after server-authorized eligibility.
abstract interface class TrackingLocationPlatform {
  Future<TrackingLocationSample> captureCurrentLocation();

  Future<TrackingPlatformSnapshot> requestPermissionState({
    required bool requestForeground,
  });
}

/// Uses the already-pinned Geolocator package. It requests the foreground
/// prompt only while the eligible UI is visible; Android/iOS background work is
/// still best effort and is not represented as a force-quit guarantee.
final class GeolocatorTrackingLocationPlatform
    implements TrackingLocationPlatform {
  @override
  Future<TrackingLocationSample> captureCurrentLocation() async {
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 30),
      ),
    );
    final heading = position.heading;
    final speed = position.speed;
    return TrackingLocationSample(
      accuracyMeters: position.accuracy,
      headingDegrees: heading >= 0 && heading < 360 ? heading : null,
      latitude: position.latitude,
      longitude: position.longitude,
      recordedAt: position.timestamp.toUtc(),
      speedMetersPerSecond: speed >= 0 ? speed : null,
    );
  }

  @override
  Future<TrackingPlatformSnapshot> requestPermissionState({
    required bool requestForeground,
  }) async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    var permission = await Geolocator.checkPermission();
    if (requestForeground && permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    final accuracy = serviceEnabled &&
            permission != LocationPermission.denied &&
            permission != LocationPermission.deniedForever
        ? await Geolocator.getLocationAccuracy()
        : LocationAccuracyStatus.unknown;

    return TrackingPlatformSnapshot(
      accuracy: switch (accuracy) {
        LocationAccuracyStatus.precise => TrackingAccuracy.precise,
        // Unknown precision must not be displayed as precise location.
        LocationAccuracyStatus.reduced || LocationAccuracyStatus.unknown =>
          TrackingAccuracy.reduced,
      },
      batteryRestricted: false,
      permission: switch (permission) {
        LocationPermission.always => TrackingPlatformPermission.always,
        LocationPermission.whileInUse => TrackingPlatformPermission.whileInUse,
        LocationPermission.deniedForever =>
          TrackingPlatformPermission.deniedForever,
        LocationPermission.denied || LocationPermission.unableToDetermine =>
          TrackingPlatformPermission.denied,
      },
      serviceEnabled: serviceEnabled,
    );
  }
}

abstract interface class TrackingTimer {
  void cancel();
}

abstract interface class TrackingTimerFactory {
  TrackingTimer every(Duration interval, void Function() callback);
}

final class DartTrackingTimerFactory implements TrackingTimerFactory {
  const DartTrackingTimerFactory();

  @override
  TrackingTimer every(Duration interval, void Function() callback) =>
      _DartTrackingTimer(Timer.periodic(interval, (_) => callback()));
}

final class _DartTrackingTimer implements TrackingTimer {
  const _DartTrackingTimer(this._timer);

  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}

/// Coordinates server-authorized driver eligibility, platform state, and
/// adaptive sampling. The timer/reconcile drain serializes slow hardware reads
/// so a lifecycle change cannot emit a stale sample or lose the latest timer.
final class DriverTrackingRuntimeCoordinator
    implements DriverTrackingLifecycle {
  DriverTrackingRuntimeCoordinator({
    required TrackingLocationPlatform locationPlatform,
    required TrackingService service,
    required OwnDriverTrackingContextRepository trackingContextRepository,
    TrackingBackgroundWorkScheduler? backgroundWorkScheduler,
    DateTime Function()? clock,
    TrackingTimerFactory? timerFactory,
  }) : _clock = clock ?? DateTime.now,
       _locationPlatform = locationPlatform,
       _service = service,
       _trackingContextRepository = trackingContextRepository,
       _backgroundWorkScheduler =
           backgroundWorkScheduler ?? const NoopTrackingBackgroundWorkScheduler(),
       _timerFactory = timerFactory ?? const DartTrackingTimerFactory();

  final DateTime Function() _clock;
  final TrackingLocationPlatform _locationPlatform;
  final TrackingBackgroundWorkScheduler _backgroundWorkScheduler;
  final TrackingService _service;
  final OwnDriverTrackingContextRepository _trackingContextRepository;
  final TrackingTimerFactory _timerFactory;
  final ValueNotifier<TrackingPermissionState?> _permissionState =
      ValueNotifier<TrackingPermissionState?>(null);

  TrackingTimer? _timer;
  Future<void>? _captureInFlight;
  Future<void>? _reconcileFuture;
  TrackingPlan _plan = const TrackingPlan.inactive();
  DateTime? _lastSampleAt;
  TrackingPlatformSnapshot? _lastPlatformSnapshot;
  var _appVisible = true;
  var _disposed = false;
  var _forceQuit = false;
  var _hasActiveLoad = false;
  var _isOnDuty = false;
  var _reconcilePending = false;
  var _generation = 0;

  @override
  ValueListenable<TrackingPermissionState?> get permissionState =>
      _permissionState;

  @override
  Future<void> refreshAuthorizedTrackingContext() async {
    try {
      final context = await _trackingContextRepository
          .fetchOwnDriverTrackingContext();
      if (_disposed || _forceQuit) return;
      _hasActiveLoad = context.hasActiveLoad;
      _isOnDuty = context.isOnDuty;
      await _requestReconcile();
    } on Object {
      if (_disposed || _forceQuit) return;
      // Context reads fail closed: never retain a client-assumed eligibility
      // state after the authenticated server boundary becomes unavailable.
      _hasActiveLoad = false;
      _isOnDuty = false;
      _generation += 1;
      _reconcilePending = false;
      _cancelTimer();
      unawaited(_cancelBackgroundWork());
      _permissionState.value = TrackingPermissionState.assess(
        accuracy: TrackingAccuracy.reduced,
        batteryRestricted: false,
        now: _clock().toUtc(),
        permission: TrackingPlatformPermission.denied,
        processWasForceQuit: false,
        serviceEnabled: false,
        lastSampleAt: _lastSampleAt,
      );
    }
  }

  @override
  Future<void> updateAppVisibility(bool appVisible) {
    _appVisible = appVisible;
    return _requestReconcile();
  }

  @override
  void stop() {
    _hasActiveLoad = false;
    _isOnDuty = false;
    _generation += 1;
    _reconcilePending = false;
    _cancelTimer();
    unawaited(_cancelBackgroundWork());
    _plan = const TrackingPlan.inactive();
    _lastSampleAt = null;
    _permissionState.value = null;
  }

  @override
  void stopForForceQuit() {
    _forceQuit = true;
    _hasActiveLoad = false;
    _isOnDuty = false;
    _generation += 1;
    _reconcilePending = false;
    _cancelTimer();
    unawaited(_cancelBackgroundWork());
    _plan = const TrackingPlan.inactive();
    _publishPermissionState(_lastPlatformSnapshot);
  }

  @override
  void dispose() {
    _disposed = true;
    _hasActiveLoad = false;
    _isOnDuty = false;
    _generation += 1;
    _reconcilePending = false;
    _cancelTimer();
    unawaited(_cancelBackgroundWork());
    _permissionState.dispose();
  }

  Future<void> _requestReconcile() {
    _generation += 1;
    _cancelTimer();
    _plan = const TrackingPlan.inactive();
    if (_disposed || _forceQuit) return Future<void>.value();

    _reconcilePending = true;
    final existing = _reconcileFuture;
    if (existing != null) return existing;

    final scheduled = _drainReconciles();
    _reconcileFuture = scheduled;
    return scheduled;
  }

  Future<void> _drainReconciles() async {
    try {
      while (!_disposed && !_forceQuit && _reconcilePending) {
        _reconcilePending = false;
        final capture = _captureInFlight;
        if (capture != null) {
          // A reconfiguration invalidates the in-flight generation. Wait for
          // it to release, then calculate the latest plan so an eligible
          // context never ends with no timer and stale samples never send.
          _reconcilePending = true;
          await capture;
          continue;
        }
        await _reconcileOnce(_generation);
      }
    } finally {
      _reconcileFuture = null;
      if (!_disposed && !_forceQuit && _reconcilePending) {
        unawaited(_requestReconcile());
      }
    }
  }

  Future<void> _reconcileOnce(int generation) async {
    await _cancelBackgroundWork();
    if (!_isCurrent(generation) || !_hasEligibleContext) return;

    try {
      final platformSnapshot = await _locationPlatform.requestPermissionState(
        requestForeground: _appVisible,
      );
      if (!_isCurrent(generation)) return;
      _lastPlatformSnapshot = platformSnapshot;
      final permission = _publishPermissionState(platformSnapshot);
      final plan = _service.plan(
        context: _context,
        permission: permission,
        isMoving: false,
      );
      _plan = plan;
      if (plan.mode == TrackingCollectionMode.inactive) return;
      if (plan.mode == TrackingCollectionMode.backgroundBestEffort) {
        await _scheduleBackgroundWork(plan, generation);
        return;
      }
      await _captureAndReschedule(generation);
    } on Object {
      if (!_isCurrent(generation)) return;
      _permissionState.value = TrackingPermissionState.assess(
        accuracy: TrackingAccuracy.reduced,
        batteryRestricted: false,
        now: _clock().toUtc(),
        permission: TrackingPlatformPermission.denied,
        processWasForceQuit: false,
        serviceEnabled: false,
        lastSampleAt: _lastSampleAt,
      );
    }
  }

  Future<void> _captureAndReschedule(int generation) async {
    if (!_isCurrent(generation) || _plan.mode == TrackingCollectionMode.inactive) {
      return;
    }
    if (_captureInFlight != null) return;

    final capture = _captureCurrentPlan(generation);
    _captureInFlight = capture;
    try {
      await capture;
    } finally {
      if (identical(_captureInFlight, capture)) {
        _captureInFlight = null;
      }
    }
  }

  Future<void> _captureCurrentPlan(int generation) async {
    try {
      final sample = await _locationPlatform.captureCurrentLocation();
      if (!_isCurrent(generation)) return;
      final permission = _permissionState.value;
      if (permission == null) return;
      final result = await _service.recordIfEligible(
        context: _context,
        permission: permission,
        sample: sample,
      );
      if (!_isCurrent(generation)) return;
      if (result is TrackingSubmissionRecorded) {
        _lastSampleAt = result.receipt.recordedAt;
      }
      final refreshedPermission = _publishPermissionState(_lastPlatformSnapshot);
      final nextPlan = _service.plan(
        context: _context,
        permission: refreshedPermission,
        isMoving: (sample.speedMetersPerSecond ?? 0) >= 1,
      );
      _plan = nextPlan;
      if (nextPlan.mode == TrackingCollectionMode.backgroundBestEffort) {
        await _scheduleBackgroundWork(nextPlan, generation);
      } else {
        _schedule(nextPlan, generation);
      }
    } on Object {
      if (!_isCurrent(generation)) return;
      _permissionState.value = TrackingPermissionState.assess(
        accuracy: TrackingAccuracy.reduced,
        batteryRestricted: false,
        now: _clock().toUtc(),
        permission: TrackingPlatformPermission.denied,
        processWasForceQuit: false,
        serviceEnabled: false,
        lastSampleAt: _lastSampleAt,
      );
    }
  }

  TrackingPermissionState _publishPermissionState(
    TrackingPlatformSnapshot? platformSnapshot,
  ) {
    final snapshot = platformSnapshot ??
        const TrackingPlatformSnapshot(
          accuracy: TrackingAccuracy.reduced,
          batteryRestricted: false,
          permission: TrackingPlatformPermission.denied,
          serviceEnabled: false,
        );
    final state = TrackingPermissionState.assess(
      accuracy: snapshot.accuracy,
      batteryRestricted: snapshot.batteryRestricted,
      now: _clock().toUtc(),
      permission: snapshot.permission,
      processWasForceQuit: _forceQuit,
      serviceEnabled: snapshot.serviceEnabled,
      lastSampleAt: _lastSampleAt,
    );
    _permissionState.value = state;
    return state;
  }

  void _schedule(TrackingPlan plan, int generation) {
    _cancelTimer();
    if (!_isCurrent(generation) ||
        plan.mode != TrackingCollectionMode.foreground ||
        plan.interval == null) {
      return;
    }
    _timer = _timerFactory.every(
      plan.interval!,
      () => unawaited(_captureAndReschedule(generation)),
    );
  }

  TrackingContext get _context => TrackingContext(
    appVisible: _appVisible,
    hasActiveLoad: _hasActiveLoad,
    isOnDuty: _isOnDuty,
  );

  bool get _hasEligibleContext =>
      (_appVisible && _isOnDuty) || _hasActiveLoad;

  bool _isCurrent(int generation) =>
      !_disposed &&
      !_forceQuit &&
      _hasEligibleContext &&
      generation == _generation;

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _scheduleBackgroundWork(
    TrackingPlan plan,
    int generation,
  ) async {
    if (!_isCurrent(generation) ||
        plan.mode != TrackingCollectionMode.backgroundBestEffort) {
      return;
    }
    final permission = _permissionState.value;
    if (permission == null) return;
    try {
      await _backgroundWorkScheduler.scheduleForActiveLoad(
        context: _context,
        permission: permission,
      );
    } on Object {
      // OS scheduling is best effort. The visible disclosure avoids claiming
      // timing or survival after force-quit when a platform refuses a task.
    }
  }

  Future<void> _cancelBackgroundWork() async {
    try {
      await _backgroundWorkScheduler.cancel();
    } on Object {
      // The OS can drop pending work independently; cancellation is best
      // effort and must not keep the authenticated driver UI from running.
    }
  }
}

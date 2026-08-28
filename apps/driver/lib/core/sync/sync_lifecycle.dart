import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import 'sync_worker.dart';

/// Owns only replay scheduling. A connectivity signal can start a replay but
/// never confirms it; [DriverSyncResumer] records success from RPC responses.
abstract interface class DriverSyncResumer {
  Future<SyncFlushReport> resumePendingSync();
}

abstract interface class SyncConnectivityEvents {
  Stream<bool> get availabilityChanges;
}

final class ConnectivityPlusSyncConnectivityEvents
    implements SyncConnectivityEvents {
  ConnectivityPlusSyncConnectivityEvents({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  @override
  Stream<bool> get availabilityChanges => _connectivity.onConnectivityChanged
      .map((results) => results.any((item) => item != ConnectivityResult.none));
}

final class DriverSyncLifecycleCoordinator {
  DriverSyncLifecycleCoordinator({
    required DriverSyncResumer resumer,
    SyncConnectivityEvents? connectivityEvents,
    Future<void> Function(SyncFlushReport report)? onSuccessfulReplay,
  }) : _resumer = resumer,
       _connectivityEvents =
           connectivityEvents ?? ConnectivityPlusSyncConnectivityEvents(),
       _onSuccessfulReplay = onSuccessfulReplay {
    _subscription = _connectivityEvents.availabilityChanges.listen(
      _onAvailabilityChanged,
    );
  }

  final DriverSyncResumer _resumer;
  final SyncConnectivityEvents _connectivityEvents;
  final Future<void> Function(SyncFlushReport report)? _onSuccessfulReplay;
  late final StreamSubscription<bool> _subscription;
  Future<void>? _inFlight;
  var _rerunRequested = false;
  var _wasAvailable = false;

  Future<void> resume() {
    final inFlight = _inFlight;
    if (inFlight != null) {
      _rerunRequested = true;
      return inFlight;
    }
    final scheduled = _runUntilIdle();
    _inFlight = scheduled;
    scheduled.whenComplete(() => _inFlight = null);
    return scheduled;
  }

  void dispose() {
    unawaited(_subscription.cancel());
  }

  void _onAvailabilityChanged(bool available) {
    final recovered = available && !_wasAvailable;
    _wasAvailable = available;
    if (recovered) unawaited(resume());
  }

  Future<void> _runUntilIdle() async {
    do {
      _rerunRequested = false;
      try {
        final report = await _resumer.resumePendingSync();
        if (report.succeededMutationIds.isNotEmpty) {
          await _onSuccessfulReplay?.call(report);
        }
      } on Object {
        // The durable outbox retains replayable work; lifecycle scheduling
        // must never surface raw transport data or crash the app shell.
      }
    } while (_rerunRequested);
  }
}

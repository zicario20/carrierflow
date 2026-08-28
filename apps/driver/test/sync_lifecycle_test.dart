import 'dart:async';

import 'package:carrierflow_driver/core/sync/sync_lifecycle.dart';
import 'package:carrierflow_driver/core/sync/sync_worker.dart';
import 'package:flutter_test/flutter_test.dart';

final class _FakeSyncResumer implements DriverSyncResumer {
  var resumes = 0;
  Completer<void>? gate;

  @override
  Future<SyncFlushReport> resumePendingSync() async {
    resumes += 1;
    await gate?.future;
    return const SyncFlushReport(
      sent: 0,
      transientFailures: 0,
      blocked: 0,
    );
  }
}

final class _FakeConnectivityEvents implements SyncConnectivityEvents {
  final StreamController<bool> _controller = StreamController<bool>();

  @override
  Stream<bool> get availabilityChanges => _controller.stream;

  void emit(bool available) => _controller.add(available);

  Future<void> dispose() => _controller.close();
}

void main() {
  test('resumes pending sync on app start, reopen, and recovered connectivity without parallel flushes', () async {
    final resumer = _FakeSyncResumer()..gate = Completer<void>();
    final connectivity = _FakeConnectivityEvents();
    final lifecycle = DriverSyncLifecycleCoordinator(
      resumer: resumer,
      connectivityEvents: connectivity,
    );
    addTearDown(() async {
      lifecycle.dispose();
      await connectivity.dispose();
    });

    final startup = lifecycle.resume();
    final reopen = lifecycle.resume();
    connectivity.emit(false);
    connectivity.emit(true);
    await Future<void>.delayed(Duration.zero);

    expect(resumer.resumes, 1);

    resumer.gate!.complete();
    await Future.wait(<Future<void>>[startup, reopen]);
    await Future<void>.delayed(Duration.zero);
    expect(resumer.resumes, 2);

    await lifecycle.resume();
    expect(resumer.resumes, 3);
  });
}

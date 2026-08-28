import 'outbox.dart';

import 'package:connectivity_plus/connectivity_plus.dart';

abstract interface class SyncNetworkAvailability {
  Future<bool> get isAvailable;
}

final class AlwaysAvailableSyncNetwork implements SyncNetworkAvailability {
  const AlwaysAvailableSyncNetwork();

  @override
  Future<bool> get isAvailable async => true;
}

/// Connectivity is only a no-network optimization. A positive signal is not
/// an acknowledgement: an operation succeeds solely after the RPC returns.
final class ConnectivityPlusSyncNetwork implements SyncNetworkAvailability {
  ConnectivityPlusSyncNetwork({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  @override
  Future<bool> get isAvailable async =>
      (await _connectivity.checkConnectivity()).any(
        (result) => result != ConnectivityResult.none,
      );
}

sealed class SyncTransportResult {
  const SyncTransportResult();
}

final class SyncTransportSucceeded extends SyncTransportResult {
  const SyncTransportSucceeded({this.operationalStatus});

  /// A minimal, server-confirmed status used only if a terminal load no
  /// longer has an active snapshot to fetch. It contains no scope or load data.
  final String? operationalStatus;
}

/// The server did not acknowledge the operation. Keeping the immutable
/// client mutation id makes the next replay safe if the server did commit.
final class SyncTransportTransientFailure extends SyncTransportResult {
  const SyncTransportTransientFailure();
}

/// A typed server denial, malformed payload, or revoked driver session must
/// never spin indefinitely. The record remains inspectable as blocked rather
/// than being silently discarded.
final class SyncTransportBlocked extends SyncTransportResult {
  const SyncTransportBlocked();
}

abstract interface class SyncMutationTransport {
  Future<SyncTransportResult> send(SyncOutboxRecord record);
}

class SyncFlushReport {
  const SyncFlushReport({
    required this.sent,
    required this.transientFailures,
    required this.blocked,
    this.succeededMutationIds = const <String>[],
    this.succeededMutations = const <SyncMutationAcknowledgement>[],
  });

  final int sent;
  final int transientFailures;
  final int blocked;

  /// IDs are reported only after their RPC has acknowledged success. UI
  /// reconciliation must never infer completion merely from connectivity.
  final List<String> succeededMutationIds;

  final List<SyncMutationAcknowledgement> succeededMutations;
}

final class SyncMutationAcknowledgement {
  const SyncMutationAcknowledgement({
    required this.clientMutationId,
    this.operationalStatus,
  });

  final String clientMutationId;
  final String? operationalStatus;
}

/// Flushes operations serially. A dependent operation waits until its parent
/// receipt is locally acknowledged, preserving causal order after reconnect.
final class SyncWorker {
  SyncWorker({
    required DriverSyncOutbox outbox,
    required this.transport,
    required String? Function() currentActorId,
    SyncNetworkAvailability? networkAvailability,
  }) : _outbox = outbox,
       _networkAvailability =
           networkAvailability ?? const AlwaysAvailableSyncNetwork(),
       _currentActorId = currentActorId;

  final DriverSyncOutbox _outbox;
  final SyncMutationTransport transport;
  final SyncNetworkAvailability _networkAvailability;
  final String? Function() _currentActorId;

  Future<SyncFlushReport> flush() async {
    var sent = 0;
    var transientFailures = 0;
    var blocked = 0;
    final succeededMutationIds = <String>[];
    final succeededMutations = <SyncMutationAcknowledgement>[];
    final actorAtFlushStart = _currentActorId();
    if (actorAtFlushStart == null) {
      return const SyncFlushReport(sent: 0, transientFailures: 0, blocked: 0);
    }
    if (!await _networkAvailability.isAvailable) {
      return const SyncFlushReport(sent: 0, transientFailures: 0, blocked: 0);
    }
    final allRecords = await _outbox.allRecords();
    final recordsById = <String, SyncOutboxRecord>{
      for (final record in allRecords) record.clientMutationId: record,
    };

    for (final record in allRecords) {
      if (record.retryState != SyncRetryState.pending &&
          record.retryState != SyncRetryState.retryable) {
        continue;
      }
      final actorBeforeSend = _currentActorId();
      if (!_belongsToCurrentActor(record, actorBeforeSend)) {
        continue;
      }
      if (!_dependencyIsSatisfied(record, recordsById)) {
        continue;
      }

      final result = await transport.send(record);
      if (!_belongsToCurrentActor(record, _currentActorId())) {
        continue;
      }
      switch (result) {
        case SyncTransportSucceeded(:final operationalStatus):
          await _outbox.markSucceeded(record);
          recordsById[record.clientMutationId] = record.copyWith(
            retryState: SyncRetryState.succeeded,
            attempts: record.attempts + 1,
          );
          sent += 1;
          succeededMutationIds.add(record.clientMutationId);
          succeededMutations.add(
            SyncMutationAcknowledgement(
              clientMutationId: record.clientMutationId,
              operationalStatus: operationalStatus,
            ),
          );
        case SyncTransportTransientFailure():
          await _outbox.markTransientFailure(record);
          recordsById[record.clientMutationId] = record.copyWith(
            retryState: SyncRetryState.retryable,
            attempts: record.attempts + 1,
          );
          transientFailures += 1;
        case SyncTransportBlocked():
          await _outbox.markBlocked(record);
          recordsById[record.clientMutationId] = record.copyWith(
            retryState: SyncRetryState.blocked,
            attempts: record.attempts + 1,
          );
          blocked += 1;
      }
    }
    return SyncFlushReport(
      sent: sent,
      transientFailures: transientFailures,
      blocked: blocked,
      succeededMutationIds: succeededMutationIds,
      succeededMutations: succeededMutations,
    );
  }

  bool _dependencyIsSatisfied(
    SyncOutboxRecord record,
    Map<String, SyncOutboxRecord> recordsById,
  ) {
    final dependsOn = record.dependsOn;
    if (dependsOn == null) return true;
    return recordsById[dependsOn]?.retryState == SyncRetryState.succeeded;
  }

  bool _belongsToCurrentActor(
    SyncOutboxRecord record,
    String? actorSessionId,
  ) => actorSessionId != null && record.actorSessionId == actorSessionId;
}

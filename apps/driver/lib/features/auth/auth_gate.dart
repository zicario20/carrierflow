import 'dart:async';

import 'package:carrierflow_driver/core/localization/driver_localizations.dart';
import 'package:carrierflow_driver/core/push/push_service.dart';
import 'package:carrierflow_driver/features/loads/load_detail_page.dart';
import 'package:carrierflow_driver/features/loads/load_home_page.dart';
import 'package:carrierflow_driver/features/loads/load_state_controller.dart';
import 'package:carrierflow_driver/features/tracking/tracking_runtime_coordinator.dart';
import 'package:flutter/material.dart';

/// Session states deliberately do not carry a caller-provided driver ID.
/// The server-derived authenticated identity is the only authority for data.
sealed class DriverSessionState {
  const DriverSessionState();
}

final class DriverSessionLoading extends DriverSessionState {
  const DriverSessionLoading();
}

final class DriverSessionSignedOut extends DriverSessionState {
  const DriverSessionSignedOut();
}

final class DriverSessionAuthenticated extends DriverSessionState {
  const DriverSessionAuthenticated({required this.userId});

  /// UI-only session identity. It never crosses an RPC boundary; PostgreSQL
  /// still derives authorization from auth.uid().
  final String userId;
}

/// The only mobile data boundary for this shell. Implementations must derive
/// the driver and organization from the authenticated session server-side.
abstract interface class OwnAssignedLoadRepository {
  Future<OwnAssignedLoadSnapshot> fetchOwnAssignedLoads();
}

/// Safe local fallback. It intentionally returns no data rather than sample or
/// cross-driver data when no authenticated repository has been configured.
final class SafeEmptyOwnAssignedLoadRepository
    implements OwnAssignedLoadRepository {
  const SafeEmptyOwnAssignedLoadRepository();

  @override
  Future<OwnAssignedLoadSnapshot> fetchOwnAssignedLoads() =>
      Future<OwnAssignedLoadSnapshot>.value(
        const OwnAssignedLoadSnapshot.empty(),
      );
}

class AuthGate extends StatefulWidget {
  const AuthGate({
    required this.authStateChanges,
    required this.ownAssignedLoadRepository,
    this.ownLoadExecutionRepository,
    this.loadStateSyncReconciler,
    this.pushRefreshService,
    this.trackingLifecycle,
    super.key,
  });

  /// Derived by the authenticated client. Callers never provide a driver ID.
  final Stream<DriverSessionState> authStateChanges;
  final OwnAssignedLoadRepository ownAssignedLoadRepository;
  final OwnLoadExecutionRepository? ownLoadExecutionRepository;
  final DriverLoadStateSyncReconciler? loadStateSyncReconciler;
  final DriverPushRefreshService? pushRefreshService;
  final DriverTrackingLifecycle? trackingLifecycle;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  String? _lastAuthenticatedUserId;

  void _enforceSessionBoundary(DriverSessionState sessionState) {
    final userId = switch (sessionState) {
      DriverSessionAuthenticated(:final userId) => userId,
      _ => null,
    };
    final previousUserId = _lastAuthenticatedUserId;
    _lastAuthenticatedUserId = userId;
    if (previousUserId == null || previousUserId == userId) {
      return;
    }
    // A persisted background acknowledgement has no user binding. Drop it
    // before B's keyed subtree starts so it cannot refresh B's own view.
    unawaited(
      widget.pushRefreshService?.discardPendingRefresh() ?? Future.value(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.maybeOf(context, rootNavigator: true)?.popUntil(
        (route) => route.isFirst,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DriverSessionState>(
      stream: widget.authStateChanges,
      initialData: const DriverSessionLoading(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const LoadHomePage.signedOut();
        }

        final sessionState = snapshot.requireData;
        _enforceSessionBoundary(sessionState);
        return switch (sessionState) {
          DriverSessionLoading() => _stoppedTracking(
            const LoadHomePage.loading(),
          ),
          DriverSessionSignedOut() => _stoppedTracking(
            const LoadHomePage.signedOut(),
            discardPendingPushRefresh: true,
          ),
          DriverSessionAuthenticated(:final userId) => _AuthenticatedLoadGate(
            key: ValueKey<String>('authenticated-loads-$userId'),
            userId: userId,
            repository: widget.ownAssignedLoadRepository,
            executionRepository: widget.ownLoadExecutionRepository,
            loadStateSyncReconciler: widget.loadStateSyncReconciler,
            pushRefreshService: widget.pushRefreshService,
            trackingLifecycle: widget.trackingLifecycle,
          ),
        };
      },
    );
  }

  Widget _stoppedTracking(
    Widget child, {
    bool discardPendingPushRefresh = false,
  }) {
    widget.trackingLifecycle?.stop();
    if (discardPendingPushRefresh) {
      unawaited(
        widget.pushRefreshService?.discardPendingRefresh() ?? Future.value(),
      );
    }
    widget.pushRefreshService?.stop();
    return child;
  }
}

class _AuthenticatedLoadGate extends StatefulWidget {
  const _AuthenticatedLoadGate({
    super.key,
    required this.userId,
    required this.repository,
    required this.executionRepository,
    required this.loadStateSyncReconciler,
    required this.pushRefreshService,
    required this.trackingLifecycle,
  });

  final String userId;
  final OwnAssignedLoadRepository repository;
  final OwnLoadExecutionRepository? executionRepository;
  final DriverLoadStateSyncReconciler? loadStateSyncReconciler;
  final DriverPushRefreshService? pushRefreshService;
  final DriverTrackingLifecycle? trackingLifecycle;

  @override
  State<_AuthenticatedLoadGate> createState() => _AuthenticatedLoadGateState();
}

class _AuthenticatedLoadGateState extends State<_AuthenticatedLoadGate>
    with WidgetsBindingObserver {
  late Future<OwnAssignedLoadSnapshot> _loads;
  StreamSubscription<void>? _pushRefreshSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loads = _fetchAuthorizedLoads();
    final pushRefreshService = widget.pushRefreshService;
    if (pushRefreshService != null) {
      _pushRefreshSubscription = pushRefreshService.ownViewRefreshes.listen((_) {
        if (mounted) _retry();
      });
      unawaited(pushRefreshService.startForAuthenticatedSession(widget.userId));
      unawaited(pushRefreshService.consumePendingRefreshForCurrentSession());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final pushRefreshService = widget.pushRefreshService;
    if (pushRefreshService != null) {
      unawaited(pushRefreshService.consumePendingRefreshForCurrentSession());
    }
  }

  void _retry() {
    setState(() {
      _loads = _fetchAuthorizedLoads();
    });
  }

  Future<OwnAssignedLoadSnapshot> _fetchAuthorizedLoads() async {
    try {
      final loads = await widget.repository.fetchOwnAssignedLoads();
      // This State belongs to the authenticated session key. A load result
      // that reaches us after sign-out (or an A-to-B switch) must never start
      // tracking for the now-disposed session. Keep location startup outside
      // the load-home critical path so a slow GPS read cannot block the UI.
      if (mounted) {
        unawaited(_refreshAuthorizedTrackingContext());
      }
      return loads;
    } on Object {
      if (mounted) {
        widget.trackingLifecycle?.stop();
      }
      rethrow;
    }
  }

  Future<void> _refreshAuthorizedTrackingContext() async {
    try {
      await widget.trackingLifecycle?.refreshAuthorizedTrackingContext();
    } on Object {
      // Tracking is best effort. It must not turn a successfully authorized
      // load query into a broken driver home, and it must stop on failure.
      if (mounted) {
        widget.trackingLifecycle?.stop();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_pushRefreshSubscription?.cancel());
    widget.pushRefreshService?.stop();
    widget.trackingLifecycle?.stop();
    super.dispose();
  }

  Future<void> _openCurrentLoad() async {
    final executionRepository = widget.executionRepository;
    if (executionRepository == null) return;

    try {
      final execution = await executionRepository
          .fetchOwnCurrentLoadExecution();
      if (!mounted) return;
      if (execution == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(DriverStrings.of(context).loadDetailsUnavailable),
          ),
        );
        return;
      }
      final controller = DriverLoadStateController(execution);
      final reconciler = widget.loadStateSyncReconciler;
      reconciler?.attach(controller, actorSessionId: widget.userId);
      try {
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => LoadDetailPage(
              snapshot: execution,
              controller: controller,
            ),
          ),
        );
      } finally {
        reconciler?.detach(controller);
        controller.dispose();
      }
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(DriverStrings.of(context).loadDetailsUnavailable),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<OwnAssignedLoadSnapshot>(
      future: _loads,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return LoadHomePage.unavailable(onRetry: _retry);
        }

        if (!snapshot.hasData) {
          return const LoadHomePage.loading();
        }

        return LoadHomePage(
          loads: snapshot.requireData,
          onViewCurrentLoad: widget.executionRepository == null
              ? null
              : _openCurrentLoad,
          trackingState: widget.trackingLifecycle?.permissionState,
          pushNotificationState: widget.pushRefreshService?.notificationState,
          onEnableNotifications: widget.pushRefreshService == null
              ? null
              : widget.pushRefreshService!.requestPermissionAndRegister,
        );
      },
    );
  }
}

import 'dart:async';

import 'package:carrierflow_driver/core/localization/driver_localizations.dart';
import 'package:carrierflow_driver/core/push/push_service.dart';
import 'package:carrierflow_driver/features/loads/driver_load_status.dart';
import 'package:carrierflow_driver/features/tracking/tracking_permission_state.dart';
import 'package:carrierflow_driver/features/tracking/tracking_status_banner.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

export 'driver_load_status.dart';

/// A deliberately limited driver-visible representation. Revenue, margin,
/// customer financial fields, and other drivers' data do not cross this boundary.
class DriverAssignedLoad {
  const DriverAssignedLoad({
    required this.loadId,
    required this.loadNumber,
    required this.pickupLabel,
    required this.deliveryLabel,
    required this.operationalStatus,
  });

  final String loadId;
  final String loadNumber;
  final String pickupLabel;
  final String deliveryLabel;
  final DriverLoadOperationalStatus operationalStatus;
}

/// The repository distinguishes an active/current load from an upcoming load.
/// This prevents an upcoming assignment from obscuring active execution.
class OwnAssignedLoadSnapshot {
  const OwnAssignedLoadSnapshot({this.currentLoad, this.nextLoad});

  const OwnAssignedLoadSnapshot.empty() : currentLoad = null, nextLoad = null;

  /// Partitioning is independent of response/update ordering. A running load
  /// always takes precedence; assigned work remains a nonblocking preview.
  factory OwnAssignedLoadSnapshot.partition(
    Iterable<DriverAssignedLoad> assignedLoads,
  ) {
    final activeLoads =
        assignedLoads.where((load) => load.operationalStatus.isActive).toList()
          ..sort(_compareLoads);
    final nextAssignedLoads =
        assignedLoads
            .where(
              (load) =>
                  load.operationalStatus ==
                  DriverLoadOperationalStatus.assigned,
            )
            .toList()
          ..sort(_compareLoads);

    final currentLoad =
        activeLoads.firstOrNull ?? nextAssignedLoads.firstOrNull;
    final nextLoad = nextAssignedLoads
        .where((load) => load.loadId != currentLoad?.loadId)
        .firstOrNull;
    if (currentLoad == null) {
      return const OwnAssignedLoadSnapshot.empty();
    }

    return OwnAssignedLoadSnapshot(
      currentLoad: currentLoad,
      nextLoad: nextLoad,
    );
  }

  static int _compareLoads(DriverAssignedLoad left, DriverAssignedLoad right) {
    final byLoadNumber = left.loadNumber.compareTo(right.loadNumber);
    return byLoadNumber != 0
        ? byLoadNumber
        : left.loadId.compareTo(right.loadId);
  }

  final DriverAssignedLoad? currentLoad;
  final DriverAssignedLoad? nextLoad;

  bool get isEmpty => currentLoad == null && nextLoad == null;
}

class LoadHomePage extends StatelessWidget {
  const LoadHomePage({
    required this.loads,
    this.onViewCurrentLoad,
    this.trackingState,
    this.pushNotificationState,
    this.onEnableNotifications,
    super.key,
  }) : mode = _LoadHomeMode.ready,
      onRetry = null;

  const LoadHomePage.loading({super.key})
    : loads = const OwnAssignedLoadSnapshot.empty(),
      mode = _LoadHomeMode.loading,
      onRetry = null,
      onViewCurrentLoad = null,
      trackingState = null,
      pushNotificationState = null,
      onEnableNotifications = null;

  const LoadHomePage.signedOut({super.key})
    : loads = const OwnAssignedLoadSnapshot.empty(),
      mode = _LoadHomeMode.signedOut,
      onRetry = null,
      onViewCurrentLoad = null,
      trackingState = null,
      pushNotificationState = null,
      onEnableNotifications = null;

  const LoadHomePage.unavailable({this.onRetry, super.key})
    : loads = const OwnAssignedLoadSnapshot.empty(),
      mode = _LoadHomeMode.unavailable,
      onViewCurrentLoad = null,
      trackingState = null,
      pushNotificationState = null,
      onEnableNotifications = null;

  static const retryButtonKey = Key('load-home-retry-action');
  static const enableNotificationsButtonKey = Key(
    'load-home-enable-notifications-action',
  );

  final OwnAssignedLoadSnapshot loads;
  final _LoadHomeMode mode;
  final VoidCallback? onRetry;
  final Future<void> Function()? onViewCurrentLoad;
  final ValueListenable<TrackingPermissionState?>? trackingState;
  final ValueListenable<PushNotificationState>? pushNotificationState;
  final Future<void> Function()? onEnableNotifications;

  @override
  Widget build(BuildContext context) {
    final strings = DriverStrings.of(context);
    final body = switch (mode) {
      _LoadHomeMode.loading => _LoadingState(
        message: strings.loadingAssignedLoads,
      ),
      _LoadHomeMode.signedOut => _MessageState(
        title: strings.signInToViewLoads,
        detail: strings.noAssignedLoadsDetail,
        icon: Icons.lock_outline,
      ),
      _LoadHomeMode.unavailable => _MessageState(
        title: strings.unavailableLoads,
        detail: strings.unavailableLoadsDetail,
        icon: Icons.cloud_off_outlined,
        actionLabel: strings.retry,
        onAction: onRetry,
      ),
      _LoadHomeMode.ready when loads.isEmpty => _EmptyAssignedLoadsContent(
        trackingState: trackingState,
        pushNotificationState: pushNotificationState,
        onEnableNotifications: onEnableNotifications,
      ),
      _LoadHomeMode.ready => _AssignedLoadsContent(
        loads: loads,
        onViewCurrentLoad: onViewCurrentLoad,
        trackingState: trackingState,
        pushNotificationState: pushNotificationState,
        onEnableNotifications: onEnableNotifications,
      ),
    };

    return Scaffold(
      appBar: AppBar(title: Text(strings.appName)),
      body: SafeArea(
        child: FocusTraversalGroup(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final gutter = constraints.maxWidth >= 600 ? 24.0 : 16.0;
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 24),
                    child: body,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

enum _LoadHomeMode { ready, loading, signedOut, unavailable }

class _EmptyAssignedLoadsContent extends StatelessWidget {
  const _EmptyAssignedLoadsContent({
    required this.trackingState,
    required this.pushNotificationState,
    required this.onEnableNotifications,
  });

  final ValueListenable<TrackingPermissionState?>? trackingState;
  final ValueListenable<PushNotificationState>? pushNotificationState;
  final Future<void> Function()? onEnableNotifications;

  @override
  Widget build(BuildContext context) {
    final strings = DriverStrings.of(context);
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (trackingState != null) ...<Widget>[
            TrackingStatusBanner(trackingState: trackingState!),
            const SizedBox(height: 16),
          ],
          if (pushNotificationState != null) ...<Widget>[
            PushNotificationStatusBanner(
              notificationState: pushNotificationState!,
              onEnableNotifications: onEnableNotifications,
            ),
            const SizedBox(height: 16),
          ],
          _MessageState(
            title: strings.noAssignedLoads,
            detail: strings.noAssignedLoadsDetail,
            icon: Icons.inbox_outlined,
          ),
        ],
      ),
    );
  }
}

class _AssignedLoadsContent extends StatelessWidget {
  const _AssignedLoadsContent({
    required this.loads,
    required this.onViewCurrentLoad,
    required this.trackingState,
    required this.pushNotificationState,
    required this.onEnableNotifications,
  });

  final OwnAssignedLoadSnapshot loads;
  final Future<void> Function()? onViewCurrentLoad;
  final ValueListenable<TrackingPermissionState?>? trackingState;
  final ValueListenable<PushNotificationState>? pushNotificationState;
  final Future<void> Function()? onEnableNotifications;

  @override
  Widget build(BuildContext context) {
    final strings = DriverStrings.of(context);
    final currentLoad = loads.currentLoad;
    final nextLoad = loads.nextLoad;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (trackingState != null) ...<Widget>[
            TrackingStatusBanner(trackingState: trackingState!),
            const SizedBox(height: 16),
          ],
          if (pushNotificationState != null) ...<Widget>[
            PushNotificationStatusBanner(
              notificationState: pushNotificationState!,
              onEnableNotifications: onEnableNotifications,
            ),
            const SizedBox(height: 16),
          ],
          if (currentLoad != null) ...<Widget>[
            Text(
              strings.currentLoad,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            _LoadCard(
              load: currentLoad,
              prominent: true,
              onView: onViewCurrentLoad,
            ),
          ],
          if (nextLoad != null) ...<Widget>[
            if (currentLoad != null) const SizedBox(height: 24),
            Text(
              strings.nextAssignedLoad,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            _LoadCard(load: nextLoad, prominent: false),
          ],
        ],
      ),
    );
  }
}

class _LoadCard extends StatelessWidget {
  const _LoadCard({required this.load, required this.prominent, this.onView});

  final DriverAssignedLoad load;
  final bool prominent;
  final Future<void> Function()? onView;

  @override
  Widget build(BuildContext context) {
    final strings = DriverStrings.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final cardColor = prominent
        ? colorScheme.primaryContainer
        : colorScheme.surfaceContainerHighest;

    return Card(
      color: cardColor,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              load.loadNumber,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            _LoadFact(label: strings.pickup, value: load.pickupLabel),
            const SizedBox(height: 8),
            _LoadFact(label: strings.delivery, value: load.deliveryLabel),
            const SizedBox(height: 8),
            Semantics(
              label: strings.loadStatusSemantics(
                strings.operationalStatus(load.operationalStatus),
              ),
              child: _LoadFact(
                label: strings.status,
                value: strings.operationalStatus(load.operationalStatus),
              ),
            ),
            if (onView != null) ...<Widget>[
              const SizedBox(height: 16),
              SizedBox(
                height: 48,
                child: FilledButton.icon(
                  onPressed: () => onView!(),
                  icon: const Icon(Icons.visibility_outlined),
                  label: Text(strings.viewLoad),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Shows notification permission/configuration honestly. It is deliberately a
/// visible, text-and-icon status rather than a color-only indicator, and the
/// only consent prompt is attached to the explicit 48dp action below.
class PushNotificationStatusBanner extends StatelessWidget {
  const PushNotificationStatusBanner({
    required this.notificationState,
    this.onEnableNotifications,
    super.key,
  });

  final ValueListenable<PushNotificationState> notificationState;
  final Future<void> Function()? onEnableNotifications;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PushNotificationState>(
      valueListenable: notificationState,
      builder: (context, state, _) {
        final strings = DriverStrings.of(context);
        final content = switch (state.status) {
          PushNotificationStatus.permissionRequired => (
            title: strings.notificationPermissionRequiredTitle,
            detail: strings.notificationPermissionRequiredDetail,
            semanticState: strings.notificationPermissionRequired,
            icon: Icons.notifications_none_outlined,
            actionLabel: strings.enableNotifications,
          ),
          PushNotificationStatus.denied => (
            title: strings.notificationDeniedTitle,
            detail: strings.notificationDeniedDetail,
            semanticState: strings.notificationDeniedTitle,
            icon: Icons.notifications_off_outlined,
            actionLabel: null,
          ),
          PushNotificationStatus.ready => (
            title: strings.notificationReadyTitle,
            detail: strings.notificationReadyDetail,
            semanticState: strings.notificationReadyTitle,
            icon: Icons.notifications_active_outlined,
            actionLabel: null,
          ),
          PushNotificationStatus.unavailable ||
          PushNotificationStatus.registrationUnavailable => (
            title: strings.notificationUnavailableTitle,
            detail: strings.notificationUnavailableDetail,
            semanticState: strings.notificationUnavailableTitle,
            icon: Icons.notifications_off_outlined,
            actionLabel: null,
          ),
        };

        return Semantics(
          label: strings.notificationStatusSemantics(
            content.semanticState,
            detail: content.detail,
          ),
          liveRegion: true,
          child: Card(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      ExcludeSemantics(
                        child: Icon(content.icon, size: 24),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          content.title,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(content.detail),
                  if (content.actionLabel != null &&
                      onEnableNotifications != null) ...<Widget>[
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 48,
                      child: FilledButton.icon(
                        key: LoadHomePage.enableNotificationsButtonKey,
                        onPressed: () => unawaited(onEnableNotifications!()),
                        icon: const Icon(Icons.notifications_outlined),
                        label: Text(content.actionLabel!),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LoadFact extends StatelessWidget {
  const _LoadFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(
        style: Theme.of(context).textTheme.bodyLarge,
        children: <InlineSpan>[
          TextSpan(
            text: '$label: ',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          TextSpan(text: value),
        ],
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.of(context).disableAnimations;

    return Semantics(
      label: message,
      liveRegion: true,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CircularProgressIndicator(value: reducedMotion ? 0.5 : null),
            const SizedBox(height: 16),
            Text(message),
          ],
        ),
      ),
    );
  }
}

class _MessageState extends StatelessWidget {
  const _MessageState({
    required this.title,
    required this.detail,
    required this.icon,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String detail;
  final IconData icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ExcludeSemantics(
                child: Icon(
                  icon,
                  size: 40,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(detail, textAlign: TextAlign.center),
              if (actionLabel != null && onAction != null) ...<Widget>[
                const SizedBox(height: 24),
                SizedBox(
                  height: 48,
                  child: FilledButton.icon(
                    key: LoadHomePage.retryButtonKey,
                    onPressed: onAction,
                    icon: const Icon(Icons.refresh),
                    label: Text(actionLabel!),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:carrierflow_driver/core/localization/driver_localizations.dart';
import 'package:carrierflow_driver/features/tracking/tracking_permission_state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// A textual, icon-supported status surface. It does not use color as the
/// only signal and intentionally does not contain an accept/reject action.
class TrackingStatusBanner extends StatelessWidget {
  const TrackingStatusBanner({required this.trackingState, super.key});

  final ValueListenable<TrackingPermissionState?> trackingState;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TrackingPermissionState?>(
      valueListenable: trackingState,
      builder: (context, state, _) {
        if (state == null) return const SizedBox.shrink();
        final strings = DriverStrings.of(context);
        final label = state.labelFor(strings.locale.languageCode);
        final disclosure = strings.trackingBackgroundBestEffort;
        final colorScheme = Theme.of(context).colorScheme;
        return Semantics(
          container: true,
          label: strings.trackingStatusSemantics(label, detail: disclosure),
          liveRegion: true,
          child: Card(
            color: state.isDegraded
                ? colorScheme.surfaceContainerHighest
                : colorScheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  ExcludeSemantics(
                    child: Icon(
                      _iconFor(state.kind),
                      color: state.isDegraded
                          ? colorScheme.onSurfaceVariant
                          : colorScheme.onSecondaryContainer,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          strings.locationTracking,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 4),
                        Text(label),
                        const SizedBox(height: 4),
                        Text(
                          disclosure,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  IconData _iconFor(TrackingPermissionKind kind) => switch (kind) {
    TrackingPermissionKind.ready => Icons.location_on_outlined,
    TrackingPermissionKind.approximate || TrackingPermissionKind.stale =>
      Icons.location_searching_outlined,
    TrackingPermissionKind.denied ||
    TrackingPermissionKind.deniedForever ||
    TrackingPermissionKind.unavailable ||
    TrackingPermissionKind.batteryRestricted ||
    TrackingPermissionKind.forceQuit ||
    TrackingPermissionKind.backgroundLimited => Icons.location_off_outlined,
  };
}

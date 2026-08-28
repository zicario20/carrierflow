/// The platform permission surface is deliberately smaller than any one OS
/// plugin. It makes every degraded state explicit before a sample can leave
/// the device and never implies that force-quit tracking is possible.
enum TrackingPlatformPermission {
  denied,
  deniedForever,
  whileInUse,
  always,
}

enum TrackingAccuracy { precise, reduced }

enum TrackingPermissionKind {
  ready,
  denied,
  deniedForever,
  unavailable,
  approximate,
  backgroundLimited,
  batteryRestricted,
  forceQuit,
  stale,
}

final class TrackingPermissionState {
  const TrackingPermissionState._({
    required this.kind,
    required this.platformPermission,
  });

  factory TrackingPermissionState.assess({
    required TrackingAccuracy accuracy,
    required bool batteryRestricted,
    required DateTime now,
    required TrackingPlatformPermission permission,
    required bool processWasForceQuit,
    required bool serviceEnabled,
    DateTime? lastSampleAt,
  }) {
    final lastSample = lastSampleAt?.toUtc();
    final isStale = lastSample != null &&
        now.toUtc().difference(lastSample) > const Duration(minutes: 5);

    if (processWasForceQuit) {
      return TrackingPermissionState._(
        kind: TrackingPermissionKind.forceQuit,
        platformPermission: permission,
      );
    }
    if (!serviceEnabled) {
      return TrackingPermissionState._(
        kind: TrackingPermissionKind.unavailable,
        platformPermission: permission,
      );
    }
    if (permission == TrackingPlatformPermission.denied) {
      return const TrackingPermissionState._(
        kind: TrackingPermissionKind.denied,
        platformPermission: TrackingPlatformPermission.denied,
      );
    }
    if (permission == TrackingPlatformPermission.deniedForever) {
      return const TrackingPermissionState._(
        kind: TrackingPermissionKind.deniedForever,
        platformPermission: TrackingPlatformPermission.deniedForever,
      );
    }
    if (batteryRestricted) {
      return TrackingPermissionState._(
        kind: TrackingPermissionKind.batteryRestricted,
        platformPermission: permission,
      );
    }
    if (accuracy == TrackingAccuracy.reduced) {
      return TrackingPermissionState._(
        kind: TrackingPermissionKind.approximate,
        platformPermission: permission,
      );
    }
    if (permission == TrackingPlatformPermission.whileInUse) {
      return const TrackingPermissionState._(
        kind: TrackingPermissionKind.backgroundLimited,
        platformPermission: TrackingPlatformPermission.whileInUse,
      );
    }
    if (isStale) {
      return TrackingPermissionState._(
        kind: TrackingPermissionKind.stale,
        platformPermission: permission,
      );
    }
    return TrackingPermissionState._(
      kind: TrackingPermissionKind.ready,
      platformPermission: permission,
    );
  }

  final TrackingPermissionKind kind;
  final TrackingPlatformPermission platformPermission;

  bool get canCollectForeground => switch (kind) {
    TrackingPermissionKind.denied ||
    TrackingPermissionKind.deniedForever ||
    TrackingPermissionKind.unavailable ||
    TrackingPermissionKind.batteryRestricted ||
    TrackingPermissionKind.forceQuit => false,
    _ => true,
  };

  /// Android/iOS may still interrupt this work. `true` only means the OS has
  /// granted the permission level required to *request* best-effort tracking.
  bool get canRequestBackground =>
      canCollectForeground &&
      platformPermission == TrackingPlatformPermission.always &&
      kind != TrackingPermissionKind.forceQuit;

  bool get isDegraded => kind != TrackingPermissionKind.ready;

  String labelFor(String languageCode) {
    final spanish = languageCode.toLowerCase() == 'es';
    return switch (kind) {
      TrackingPermissionKind.ready =>
        spanish ? 'Ubicación disponible' : 'Location available',
      TrackingPermissionKind.denied =>
        spanish ? 'Permiso de ubicación denegado' : 'Location permission denied',
      TrackingPermissionKind.deniedForever => spanish
          ? 'El permiso de ubicación debe habilitarse en Configuración'
          : 'Location permission must be enabled in Settings',
      TrackingPermissionKind.unavailable => spanish
          ? 'El servicio de ubicación no está disponible'
          : 'Location service is unavailable',
      TrackingPermissionKind.approximate => spanish
          ? 'Ubicación aproximada; la precisión es limitada'
          : 'Approximate location; accuracy is limited',
      TrackingPermissionKind.backgroundLimited => spanish
          ? 'Seguimiento en segundo plano limitado por el permiso'
          : 'Background tracking is limited by permission',
      TrackingPermissionKind.batteryRestricted => spanish
          ? 'Seguimiento limitado por ahorro de batería'
          : 'Tracking is limited by battery restrictions',
      TrackingPermissionKind.forceQuit => spanish
          ? 'La app se cerró por completo; el seguimiento se reanuda al abrirla'
          : 'The app was force-quit; tracking resumes when it is opened',
      TrackingPermissionKind.stale => spanish
          ? 'La última ubicación está desactualizada'
          : 'The last location is stale',
    };
  }
}

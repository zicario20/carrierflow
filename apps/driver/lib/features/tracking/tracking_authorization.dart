/// Server-derived eligibility used by the runtime. It intentionally contains
/// no company, driver, vehicle, or load identifier.
final class AuthorizedDriverTrackingContext {
  const AuthorizedDriverTrackingContext({
    required this.hasActiveLoad,
    required this.isOnDuty,
  });

  final bool hasActiveLoad;
  final bool isOnDuty;

  @override
  bool operator ==(Object other) =>
      other is AuthorizedDriverTrackingContext &&
      other.hasActiveLoad == hasActiveLoad &&
      other.isOnDuty == isOnDuty;

  @override
  int get hashCode => Object.hash(hasActiveLoad, isOnDuty);
}

/// Reads only the authenticated driver's tracking eligibility. The database
/// derives every identity and tenant boundary from the session server-side.
abstract interface class OwnDriverTrackingContextRepository {
  Future<AuthorizedDriverTrackingContext> fetchOwnDriverTrackingContext();
}

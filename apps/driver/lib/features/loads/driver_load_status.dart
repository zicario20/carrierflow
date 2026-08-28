/// Typed representation of the server's `loads.operational_status` enum.
/// Unknown wire values never become driver-visible data.
enum DriverLoadOperationalStatus {
  draft('draft'),
  scheduled('scheduled'),
  assigned('assigned'),
  enRouteToPickup('en_route_to_pickup'),
  arrivedPickup('arrived_pickup'),
  loading('loading'),
  pickedUp('picked_up'),
  enRouteToDelivery('en_route_to_delivery'),
  arrivedDelivery('arrived_delivery'),
  unloading('unloading'),
  delivered('delivered'),
  closed('closed'),
  cancelled('cancelled');

  const DriverLoadOperationalStatus(this.wireValue);

  final String wireValue;

  static const driverVisible = <DriverLoadOperationalStatus>{
    assigned,
    enRouteToPickup,
    arrivedPickup,
    loading,
    pickedUp,
    enRouteToDelivery,
    arrivedDelivery,
    unloading,
  };

  static final driverVisibleWireValues = List<String>.unmodifiable(
    driverVisible.map((status) => status.wireValue),
  );

  bool get isActive => driverVisible.contains(this) && this != assigned;

  static DriverLoadOperationalStatus? fromWire(Object? value) {
    if (value is! String) {
      return null;
    }

    for (final status in DriverLoadOperationalStatus.values) {
      if (status.wireValue == value) {
        return status;
      }
    }
    return null;
  }
}

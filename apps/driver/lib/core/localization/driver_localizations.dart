import 'package:carrierflow_driver/features/loads/driver_load_status.dart';
import 'package:carrierflow_driver/features/evidence/evidence_capture.dart';
import 'package:carrierflow_driver/features/loads/load_state_controller.dart';
import 'package:flutter/widgets.dart';

/// Driver-facing strings are intentionally local and never contain load data.
/// Dynamic values remain typed at the feature boundary rather than being read
/// from locale resources.
class DriverStrings {
  const DriverStrings._(this.locale);

  final Locale locale;

  static const LocalizationsDelegate<DriverStrings> delegate =
      _DriverStringsDelegate();

  static DriverStrings of(BuildContext context) {
    return Localizations.of<DriverStrings>(context, DriverStrings) ??
        DriverStrings._(Localizations.localeOf(context));
  }

  bool get _isSpanish => locale.languageCode.toLowerCase() == 'es';

  String get appName => _isSpanish ? 'CarrierFlow' : 'CarrierFlow';
  String get locationTracking =>
      _isSpanish ? 'Seguimiento de ubicación' : 'Location tracking';
  String get notifications => _isSpanish ? 'Notificaciones' : 'Notifications';
  String get notificationPermissionRequired =>
      _isSpanish ? 'Se requiere permiso' : 'Permission required';
  String get notificationPermissionRequiredTitle => _isSpanish
      ? 'Las notificaciones necesitan permiso'
      : 'Notifications need permission';
  String get notificationPermissionRequiredDetail => _isSpanish
      ? 'Activa las notificaciones para recibir actualizaciones de carga.'
      : 'Enable notifications to receive load updates.';
  String get enableNotifications =>
      _isSpanish ? 'Activar notificaciones' : 'Enable notifications';
  String get notificationDeniedTitle => _isSpanish
      ? 'Las notificaciones están desactivadas'
      : 'Notifications are turned off';
  String get notificationDeniedDetail => _isSpanish
      ? 'Puedes seguir trabajando sin notificaciones. Actívalas en los ajustes de tu dispositivo si quieres recibir actualizaciones.'
      : 'You can keep working without notifications. Turn them on in your device settings to receive updates.';
  String get notificationUnavailableTitle => _isSpanish
      ? 'Las notificaciones no están disponibles'
      : 'Notifications are unavailable';
  String get notificationUnavailableDetail => _isSpanish
      ? 'Este servidor de CarrierFlow no está configurado para entregar actualizaciones push. Puedes seguir trabajando sin notificaciones.'
      : 'This CarrierFlow server is not configured to deliver push updates. You can keep working without notifications.';
  String get notificationReadyTitle =>
      _isSpanish ? 'Las notificaciones están listas' : 'Notifications are ready';
  String get notificationReadyDetail => _isSpanish
      ? 'Recibirás actualizaciones de carga cuando estén disponibles.'
      : 'You will receive load updates when they are available.';
  String get trackingBackgroundBestEffort => _isSpanish
      ? 'Las actualizaciones en segundo plano durante una carga activa son de mejor esfuerzo y las controla tu dispositivo.'
      : 'Background updates during an active load are best effort and controlled by your device.';
  String get currentLoad => _isSpanish ? 'Carga actual' : 'Current load';
  String get nextAssignedLoad =>
      _isSpanish ? 'Próxima carga asignada' : 'Next assigned load';
  String get pickup => _isSpanish ? 'Recogida' : 'Pickup';
  String get delivery => _isSpanish ? 'Entrega' : 'Delivery';
  String get status => _isSpanish ? 'Estado' : 'Status';
  String get loadingAssignedLoads => _isSpanish
      ? 'Cargando tus cargas asignadas'
      : 'Loading your assigned loads';
  String get noAssignedLoads =>
      _isSpanish ? 'No tienes cargas asignadas' : 'No assigned loads';
  String get noAssignedLoadsDetail => _isSpanish
      ? 'Cuando el despacho te asigne una carga, aparecerá aquí.'
      : 'When dispatch assigns a load, it will appear here.';
  String get signInToViewLoads => _isSpanish
      ? 'Inicia sesión para ver tus cargas asignadas'
      : 'Sign in to view your assigned loads';
  String get unavailableLoads => _isSpanish
      ? 'Tus cargas no están disponibles ahora'
      : 'Your assigned loads are unavailable right now';
  String get unavailableLoadsDetail => _isSpanish
      ? 'Comprueba tu conexión e inténtalo de nuevo.'
      : 'Check your connection and try again.';
  String get retry => _isSpanish ? 'Intentar de nuevo' : 'Try again';
  String get loadDetails =>
      _isSpanish ? 'Detalles de la carga' : 'Load details';
  String get viewLoad => _isSpanish ? 'Ver carga' : 'View load';
  String get loadDetailsUnavailable => _isSpanish
      ? 'Los detalles de la carga no están disponibles ahora.'
      : 'Load details are unavailable right now.';
  String get nextStep => _isSpanish ? 'Siguiente paso' : 'Next step';
  String advanceTo(String status) =>
      _isSpanish ? 'Marcar como $status' : 'Mark as $status';
  String get noFurtherDriverStep => _isSpanish
      ? 'No hay otro paso operativo disponible.'
      : 'No further operational step is available.';
  String terminalLoadConfirmation(DriverLoadOperationalStatus status) {
    final statusLabel = operationalStatus(status);
    if (status == DriverLoadOperationalStatus.delivered) {
      return _isSpanish
          ? 'Entrega confirmada. Esta carga ya no está activa.'
          : 'Delivery confirmed. This load is no longer active.';
    }
    return _isSpanish
        ? '$statusLabel confirmada. Esta carga ya no está activa.'
        : '$statusLabel confirmed. This load is no longer active.';
  }
  String get evidence => _isSpanish ? 'Evidencia' : 'Evidence';
  String get evidenceRecordedLocally => _isSpanish
      ? 'La evidencia se registra localmente y se sincroniza de forma privada.'
      : 'Evidence is recorded locally and syncs privately.';
  String get noEvidenceRecorded => _isSpanish
      ? 'Aún no hay evidencia registrada.'
      : 'No evidence is recorded yet.';
  String recordEvidenceLocally(String type) => _isSpanish
      ? 'Registrar $type de forma privada'
      : 'Record $type privately';
  String get privateEvidenceCaptureNotice => _isSpanish
      ? 'Registra solamente evidencia que ya se haya guardado en tu dispositivo autorizado.'
      : 'Record only evidence already saved by your approved device workflow.';
  String get privateEvidenceCaptureUnavailable => _isSpanish
      ? 'La captura privada no está disponible en este dispositivo todavía.'
      : 'Private evidence capture is not available on this device yet.';
  String get deliveryBlocked =>
      _isSpanish ? 'Entrega bloqueada' : 'Delivery blocked';
  String get missingEvidenceDetail => _isSpanish
      ? 'Completa estos requisitos antes de entregar.'
      : 'Complete these requirements before delivery.';
  String get reportProblem =>
      _isSpanish ? 'Reportar un problema' : 'Report a problem';
  String get incidentCategory =>
      _isSpanish ? 'Categoría del problema' : 'Problem category';
  String get incidentDescription =>
      _isSpanish ? 'Describe el problema' : 'Describe the problem';
  String get incidentLocationWhenAvailable => _isSpanish
      ? 'La ubicación se incluirá cuando esté disponible.'
      : 'Location will be included when available.';
  String get submitIncident =>
      _isSpanish ? 'Enviar problema' : 'Submit problem';
  String get incidentQueued => _isSpanish
      ? 'Problema en cola para despacho'
      : 'Incident queued for dispatch';
  String get actionQueued => _isSpanish
      ? 'Actualización en cola. CarrierFlow la sincronizará cuando se restablezca la conexión con el servicio.'
      : 'Update queued. CarrierFlow will sync it after service connection is restored.';
  String evidenceQueued(String evidence) => _isSpanish
      ? '$evidence en cola. CarrierFlow la sincronizará cuando se restablezca la conexión con el servicio.'
      : '$evidence queued. CarrierFlow will sync it after service connection is restored.';
  String get incidentDescriptionRequired => _isSpanish
      ? 'Describe el problema para continuar.'
      : 'Describe the problem to continue.';
  String get incidentFormTitle =>
      _isSpanish ? 'Reportar un problema' : 'Report a problem';
  String get close => _isSpanish ? 'Cerrar' : 'Close';

  String executionFailure(DriverExecutionFailure failure) {
    return switch (failure) {
      DriverExecutionFailure.transitionUnavailable =>
        _isSpanish
            ? 'Este paso ya no está disponible. Actualiza la carga.'
            : 'This step is no longer available. Refresh the load.',
      DriverExecutionFailure.evidenceIncomplete =>
        _isSpanish
            ? 'Falta evidencia obligatoria para entregar.'
            : 'Required evidence is incomplete for delivery.',
      DriverExecutionFailure.denied =>
        _isSpanish
            ? 'No tienes permiso para actualizar esta carga.'
            : 'You do not have permission to update this load.',
      DriverExecutionFailure.unavailable =>
        _isSpanish
            ? 'Esta acción no está disponible ahora. Inténtalo de nuevo.'
            : 'This action is unavailable right now. Try again.',
      DriverExecutionFailure.invalidIncident =>
        _isSpanish
            ? 'Revisa los detalles del problema e inténtalo de nuevo.'
            : 'Review the incident details and try again.',
    };
  }

  String evidenceType(DriverEvidenceType type) {
    if (_isSpanish) {
      return switch (type) {
        DriverEvidenceType.photo => 'Fotografía',
        DriverEvidenceType.receiverName => 'Nombre del receptor',
        DriverEvidenceType.signature => 'Firma',
        DriverEvidenceType.billOfLading => 'Bill of Lading',
        DriverEvidenceType.pod => 'Comprobante de entrega',
        DriverEvidenceType.referenceNumber => 'Número de referencia',
        DriverEvidenceType.deliveryTimestamp => 'Hora de entrega',
        DriverEvidenceType.deliveryGps => 'Ubicación de entrega',
      };
    }

    return switch (type) {
      DriverEvidenceType.photo => 'Photo',
      DriverEvidenceType.receiverName => 'Receiver name',
      DriverEvidenceType.signature => 'Signature',
      DriverEvidenceType.billOfLading => 'Bill of Lading',
      DriverEvidenceType.pod => 'Proof of delivery',
      DriverEvidenceType.referenceNumber => 'Reference number',
      DriverEvidenceType.deliveryTimestamp => 'Delivery time',
      DriverEvidenceType.deliveryGps => 'Delivery location',
    };
  }

  String incidentType(DriverIncidentType type) {
    if (_isSpanish) {
      return switch (type) {
        DriverIncidentType.pickupIssue => 'Problema en recogida',
        DriverIncidentType.deliveryIssue => 'Problema en entrega',
        DriverIncidentType.breakdown => 'Vehículo averiado',
        DriverIncidentType.badAddress => 'Dirección incorrecta',
        DriverIncidentType.customerUnavailable => 'Cliente no disponible',
        DriverIncidentType.siteRejectedLoad =>
          'Carga rechazada por el establecimiento',
        DriverIncidentType.accidentEmergency => 'Accidente o emergencia',
        DriverIncidentType.awaitingInstruction => 'Esperando instrucciones',
      };
    }

    return switch (type) {
      DriverIncidentType.pickupIssue => 'Pickup issue',
      DriverIncidentType.deliveryIssue => 'Delivery issue',
      DriverIncidentType.breakdown => 'Vehicle breakdown',
      DriverIncidentType.badAddress => 'Incorrect address',
      DriverIncidentType.customerUnavailable => 'Customer unavailable',
      DriverIncidentType.siteRejectedLoad => 'Load rejected by facility',
      DriverIncidentType.accidentEmergency => 'Accident or emergency',
      DriverIncidentType.awaitingInstruction => 'Awaiting instructions',
    };
  }

  String operationalStatus(DriverLoadOperationalStatus status) {
    if (_isSpanish) {
      return switch (status) {
        DriverLoadOperationalStatus.draft => 'Borrador',
        DriverLoadOperationalStatus.scheduled => 'Programada',
        DriverLoadOperationalStatus.assigned => 'Asignada',
        DriverLoadOperationalStatus.enRouteToPickup => 'En camino a recogida',
        DriverLoadOperationalStatus.arrivedPickup => 'Llegó a recogida',
        DriverLoadOperationalStatus.loading => 'Cargando',
        DriverLoadOperationalStatus.pickedUp => 'Carga recogida',
        DriverLoadOperationalStatus.enRouteToDelivery => 'En camino a entrega',
        DriverLoadOperationalStatus.arrivedDelivery => 'Llegó a entrega',
        DriverLoadOperationalStatus.unloading => 'Descargando',
        DriverLoadOperationalStatus.delivered => 'Entregada',
        DriverLoadOperationalStatus.closed => 'Cerrada',
        DriverLoadOperationalStatus.cancelled => 'Cancelada',
      };
    }

    return switch (status) {
      DriverLoadOperationalStatus.draft => 'Draft',
      DriverLoadOperationalStatus.scheduled => 'Scheduled',
      DriverLoadOperationalStatus.assigned => 'Assigned',
      DriverLoadOperationalStatus.enRouteToPickup => 'En route to pickup',
      DriverLoadOperationalStatus.arrivedPickup => 'Arrived at pickup',
      DriverLoadOperationalStatus.loading => 'Loading',
      DriverLoadOperationalStatus.pickedUp => 'Load picked up',
      DriverLoadOperationalStatus.enRouteToDelivery => 'En route to delivery',
      DriverLoadOperationalStatus.arrivedDelivery => 'Arrived at delivery',
      DriverLoadOperationalStatus.unloading => 'Unloading',
      DriverLoadOperationalStatus.delivered => 'Delivered',
      DriverLoadOperationalStatus.closed => 'Closed',
      DriverLoadOperationalStatus.cancelled => 'Cancelled',
    };
  }

  String loadStatusSemantics(String value) => '$status: $value';
  String trackingStatusSemantics(String value, {String? detail}) =>
      '$locationTracking: $value${detail == null ? '' : '. $detail'}';
  String notificationStatusSemantics(String value, {String? detail}) =>
      '$notifications: $value${detail == null ? '' : '. $detail'}';
}

class _DriverStringsDelegate extends LocalizationsDelegate<DriverStrings> {
  const _DriverStringsDelegate();

  @override
  bool isSupported(Locale locale) =>
      const <String>{'en', 'es'}.contains(locale.languageCode.toLowerCase());

  @override
  Future<DriverStrings> load(Locale locale) async => DriverStrings._(locale);

  @override
  bool shouldReload(_DriverStringsDelegate old) => false;
}

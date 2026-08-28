/// These values mirror the server-side `load_evidence_type` enum. They remain
/// typed so unknown values cannot silently satisfy a delivery requirement.
enum DriverEvidenceType {
  photo('photo'),
  receiverName('receiver_name'),
  signature('signature'),
  billOfLading('bol'),
  pod('pod'),
  referenceNumber('reference_number'),
  deliveryTimestamp('delivery_timestamp'),
  deliveryGps('delivery_gps');

  const DriverEvidenceType(this.wireValue);

  final String wireValue;

  static DriverEvidenceType? fromWire(Object? value) {
    if (value is! String) return null;
    for (final type in DriverEvidenceType.values) {
      if (type.wireValue == value) return type;
    }
    return null;
  }
}

/// A reference to data retained on the device or prepared for a private
/// upload. It deliberately has no URL field: public evidence links are never
/// a valid driver-side representation.
class PrivateEvidenceReference {
  PrivateEvidenceReference._(this.localReceiptKey);

  factory PrivateEvidenceReference.localReceiptKey(String value) {
    final normalized = value.trim();
    final isOpaqueReceiptKey = RegExp(r'^[a-z0-9][a-z0-9_-]{0,95}$')
        .hasMatch(normalized);
    if (!isOpaqueReceiptKey) {
      throw ArgumentError.value(
        value,
        'value',
        'A private evidence reference must be an opaque local receipt key.',
      );
    }
    return PrivateEvidenceReference._(normalized);
  }

  final String localReceiptKey;
}

/// Non-sensitive metadata retained alongside a local evidence receipt.
class EvidenceCaptureMetadata {
  const EvidenceCaptureMetadata({
    required this.mimeType,
    required this.byteLength,
  }) : assert(mimeType != ''),
       assert(byteLength >= 0);

  final String mimeType;
  final int byteLength;
}

class DriverEvidenceLocation {
  const DriverEvidenceLocation({
    required this.latitude,
    required this.longitude,
  }) : assert(latitude >= -90 && latitude <= 90),
       assert(longitude >= -180 && longitude <= 180);

  final double latitude;
  final double longitude;
}

/// A local evidence receipt. Actual upload and replay are assigned to the
/// durable outbox slice; this model never substitutes a public URL for it.
class DriverEvidenceCapture {
  DriverEvidenceCapture({
    required this.receiptId,
    required this.type,
    required this.capturedAt,
    required String summary,
    this.attachment,
    this.metadata,
    this.textValue,
    this.timestampValue,
    this.locationValue,
  }) : summary = summary.trim() {
    if (receiptId.trim().isEmpty || this.summary.isEmpty) {
      throw ArgumentError('Evidence receipts require an id and summary.');
    }
  }

  factory DriverEvidenceCapture.textValue({
    required String receiptId,
    required DriverEvidenceType type,
    required DateTime capturedAt,
    required String value,
  }) {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      throw ArgumentError.value(
        value,
        'value',
        'A non-empty value is required.',
      );
    }
    return DriverEvidenceCapture(
      receiptId: receiptId,
      type: type,
      capturedAt: capturedAt,
      summary: normalized,
      textValue: normalized,
    );
  }

  factory DriverEvidenceCapture.timestampValue({
    required String receiptId,
    required DateTime capturedAt,
    required DateTime value,
  }) => DriverEvidenceCapture(
    receiptId: receiptId,
    type: DriverEvidenceType.deliveryTimestamp,
    capturedAt: capturedAt,
    summary: value.toUtc().toIso8601String(),
    timestampValue: value.toUtc(),
  );

  factory DriverEvidenceCapture.locationValue({
    required String receiptId,
    required DateTime capturedAt,
    required DriverEvidenceLocation value,
  }) => DriverEvidenceCapture(
    receiptId: receiptId,
    type: DriverEvidenceType.deliveryGps,
    capturedAt: capturedAt,
    summary: 'Location recorded',
    locationValue: value,
  );

  /// Builds a display-only receipt from a server-authoritative snapshot.
  /// It contains no path, signed URL, binary, or receiver value.
  factory DriverEvidenceCapture.serverRecorded({
    required DriverEvidenceType type,
    required DateTime capturedAt,
  }) => DriverEvidenceCapture(
    receiptId: 'server-${type.wireValue}-${capturedAt.millisecondsSinceEpoch}',
    type: type,
    capturedAt: capturedAt,
    summary: 'Recorded',
  );

  final String receiptId;
  final DriverEvidenceType type;
  final DateTime capturedAt;
  final String summary;
  final PrivateEvidenceReference? attachment;
  final EvidenceCaptureMetadata? metadata;
  final String? textValue;
  final DateTime? timestampValue;
  final DriverEvidenceLocation? locationValue;

  /// Converts the strictly typed local receipt into the small RPC payload.
  /// Private evidence sends an opaque receipt key only; PostgreSQL derives the
  /// tenant/load Storage path and independently verifies the private object.
  Map<String, Object?>? toOwnLoadRpcContent() {
    switch (type) {
      case DriverEvidenceType.signature ||
          DriverEvidenceType.receiverName ||
          DriverEvidenceType.referenceNumber:
        final value = textValue?.trim();
        return value == null || value.isEmpty
            ? null
            : <String, Object?>{'value': value};
      case DriverEvidenceType.deliveryTimestamp:
        final value = timestampValue;
        return value == null
            ? null
            : <String, Object?>{'value': value.toUtc().toIso8601String()};
      case DriverEvidenceType.deliveryGps:
        final value = locationValue;
        return value == null
            ? null
            : <String, Object?>{
                'latitude': value.latitude,
                'longitude': value.longitude,
              };
      case DriverEvidenceType.photo ||
          DriverEvidenceType.billOfLading ||
          DriverEvidenceType.pod:
        final reference = attachment;
        final captureMetadata = metadata;
        return reference == null || captureMetadata == null
            ? null
            : <String, Object?>{
                'receiptKey': reference.localReceiptKey,
                'mimeType': captureMetadata.mimeType,
                'byteLength': captureMetadata.byteLength,
              };
    }
  }
}

/// A platform adapter writes evidence to private local storage before it
/// returns the receipt. A null result means the driver cancelled capture.
/// Public file, storage, and tracking URLs are not valid adapter output.
abstract interface class DriverLocalEvidenceCaptureAdapter {
  Future<DriverEvidenceCapture?> capturePrivateEvidence(
    DriverEvidenceType type,
  );
}

/// Client-side feedback only. The server remains authoritative for delivery
/// and independently rechecks every configured evidence requirement.
abstract final class EvidenceRequirements {
  static List<DriverEvidenceType> missingRequiredDeliveryEvidence({
    required Iterable<DriverEvidenceType> requiredEvidence,
    required Iterable<DriverEvidenceCapture> recordedEvidence,
  }) {
    final recordedTypes = recordedEvidence
        .map((evidence) => evidence.type)
        .toSet();
    return requiredEvidence
        .where(
          (requirement) =>
              requirement != DriverEvidenceType.photo &&
              !recordedTypes.contains(requirement),
        )
        .toSet()
        .toList(growable: false);
  }
}

import 'package:carrierflow_driver/features/evidence/evidence_capture.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('delivery evidence requirements', () {
    test(
      'identifies required non-photo evidence that has not been recorded',
      () {
        final missing = EvidenceRequirements.missingRequiredDeliveryEvidence(
          requiredEvidence: const <DriverEvidenceType>[
            DriverEvidenceType.photo,
            DriverEvidenceType.signature,
            DriverEvidenceType.receiverName,
          ],
          recordedEvidence: <DriverEvidenceCapture>[
            DriverEvidenceCapture(
              receiptId: 'receipt-signature',
              type: DriverEvidenceType.signature,
              capturedAt: DateTime.utc(2026, 8, 28),
              summary: 'Signature recorded locally',
            ),
          ],
        );

        expect(missing, const <DriverEvidenceType>[
          DriverEvidenceType.receiverName,
        ]);
      },
    );

    test('accepts only an opaque local receipt key', () {
      for (final invalidReference in <String>[
        'https://storage.example/public-proof.jpg',
        '/private/evidence',
        '../receipt',
        'folder\\receipt',
        'receipt.pdf',
        'evidence/receipt',
        'receipt:public',
      ]) {
        expect(
          () => PrivateEvidenceReference.localReceiptKey(invalidReference),
          throwsArgumentError,
        );
      }

      expect(
        PrivateEvidenceReference.localReceiptKey('receipt_pod-20260828')
            .localReceiptKey,
        'receipt_pod-20260828',
      );
    });

    test('retains local receipt metadata without a public URL', () {
      final capture = DriverEvidenceCapture(
        receiptId: 'receipt-pod',
        type: DriverEvidenceType.pod,
        capturedAt: DateTime.utc(2026, 8, 28),
        summary: 'Proof of delivery saved on device',
        attachment: PrivateEvidenceReference.localReceiptKey('receipt-pod'),
        metadata: const EvidenceCaptureMetadata(
          mimeType: 'application/pdf',
          byteLength: 2048,
        ),
      );

      expect(capture.attachment?.localReceiptKey, 'receipt-pod');
      expect(capture.metadata?.mimeType, 'application/pdf');
      expect(capture.metadata?.byteLength, 2048);
    });
  });
}

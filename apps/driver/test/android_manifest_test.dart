import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('declares only the location permissions used by the best-effort tracker', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();

    expect(manifest, contains('android.permission.ACCESS_COARSE_LOCATION'));
    expect(manifest, contains('android.permission.ACCESS_FINE_LOCATION'));
    expect(manifest, contains('android.permission.ACCESS_BACKGROUND_LOCATION'));
    expect(manifest, isNot(contains('android.permission.FOREGROUND_SERVICE')));
  });
}

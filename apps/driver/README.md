# CarrierFlow Driver App

The Flutter driver shell starts from an HTTPS Supabase URL and a public publishable key passed at runtime; it contains no endpoint, key, or service-role credential. Use `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` through `--dart-define` or the deployment secret manager. Secret keys (`sb_secret_*`) and legacy service-role JWTs are rejected before the client initializes. Session and PKCE verifier persistence use the device Keychain/Android Keystore rather than shared preferences.

Provision the exact Windows SDK from the pinned official source before testing:

```powershell
pwsh -NoProfile -File scripts/provision-flutter-windows.ps1 -Download
```

The provisioner verifies the official `flutter_windows_3.47.2-stable.zip` SHA-256 (`37934f2128a55d77a38baba12fd611157ed23a47bf7d2b7d17e9e84da118409d`) and requires Flutter 3.47.2 / Dart 3.13.2. It does not recommend weakening PowerShell execution policy.

On Windows, Flutter's native-asset hook can mis-handle a Flutter SDK path containing spaces. Run the reproducible workspace-junction gate from the repository root:

```powershell
pwsh -NoProfile -File scripts/test-driver-windows.ps1
```

The script creates or validates a junction under `%LOCALAPPDATA%`, runs from its no-space path, verifies both the retained pinned Flutter archive SHA-256 and the Flutter/Dart versions, then executes `flutter pub get`, the focused driver widget test, the full `flutter test` suite, and `flutter analyze`. It never copies credentials or source files. Keep the verified archive and extracted SDK under `.tooling/`, which is ignored by Git. Use a PowerShell host allowed by your organization rather than bypassing its execution policy.

Before the first physical mobile build, add the generated Android/iOS runners to the repository and verify the platform requirements for `flutter_secure_storage 11.0.0`: Android `minSdk` 23 or later, the plugin's backup protection configuration, and the iOS Keychain capability/entitlements. These are release gates, not a claim that a test host exercises device storage.

The sign-in screen is a later slice. Its explicit OAuth-cancellation/sign-out handler must call `SecurePkceStorage.clearPendingCodeVerifier()` after the flow ends; bootstrap intentionally does not clear it because a valid redirect callback can still require the verifier.

// lib/config/app_config.dart
//
// UnBot Delivery — Compile-Time Environment Configuration
// ─────────────────────────────────────────────────────────────────────────────
// ARCHITECTURE DECISION: --dart-define over runtime Platform detection
// ───────────────────────────────────────────────────────────────────────────
// We use Dart's compile-time constant system (String.fromEnvironment) rather
// than runtime Platform.isAndroid / Platform.isIOS checks for the following
// reasons:
//
//   1. CORRECTNESS: Runtime platform detection cannot distinguish "Android
//      emulator on the same machine as the Go server" from "Android physical
//      device on the same LAN". Both are Platform.isAndroid == true but need
//      different URLs (10.0.2.2 vs LAN IP). A compile-time flag is explicit.
//
//   2. SEPARATION OF CONCERNS: Business logic (ApiService) should not contain
//      environment-routing code. Config belongs in config.
//
//   3. PRODUCTION SAFETY: compile-time constants are tree-shaken and cannot
//      accidentally expose a dev URL in a production build. A const that
//      was never set defaults to the production URL.
//
//   4. ZERO DEPENDENCIES: No .env packages, no flutter_dotenv, no external
//      tooling. Pure Dart.
//
// ─────────────────────────────────────────────────────────────────────────────
// USAGE
// ─────────────────────────────────────────────────────────────────────────────
//
// 1. Android Emulator (Go server on the same host machine):
//
//    flutter run \
//      --dart-define=API_BASE_URL=http://10.0.2.2:8080
//
//    The Android emulator routes 10.0.2.2 to the host machine's localhost.
//    This is the standard Android emulator loopback alias — do NOT use
//    127.0.0.1 or localhost, they resolve to the emulator's own loopback.
//
// 2. Physical device on the same Wi-Fi network as the Go server:
//
//    flutter run \
//      --dart-define=API_BASE_URL=http://192.168.1.42:8080
//
//    Replace 192.168.1.42 with the LAN IP of the machine running `make run`.
//    Find it with `ipconfig` (Windows) or `ifconfig` / `ip addr` (Linux/macOS).
//
// 3. Production (AWS gateway — the default):
//
//    flutter build apk   # No --dart-define needed; falls back to PROD_BASE_URL
//    flutter build ios
//
//    Or explicitly:
//    flutter build apk \
//      --dart-define=API_BASE_URL=https://rvdj88q6-8000.brs.devtunnels.ms
//
// 4. VS Code launch.json (recommended for the team):
//
//    {
//      "version": "0.2.0",
//      "configurations": [
//        {
//          "name": "Dev - Android Emulator",
//          "request": "launch",
//          "type": "dart",
//          "args": ["--dart-define=API_BASE_URL=http://10.0.2.2:8080"]
//        },
//        {
//          "name": "Dev - Physical Device (edit IP)",
//          "request": "launch",
//          "type": "dart",
//          "args": ["--dart-define=API_BASE_URL=http://192.168.1.42:8080"]
//        },
//        {
//          "name": "Production",
//          "request": "launch",
//          "type": "dart"
//        }
//      ]
//    }
//
// ─────────────────────────────────────────────────────────────────────────────

/// Centralised compile-time configuration.
///
/// All values are resolved at compile time via --dart-define flags passed to
/// `flutter run` or `flutter build`. If a flag is absent, the constant falls
/// back to the production default defined below.
///
/// Access anywhere in the app via [AppConfig.apiBaseUrl].
/// Never import dart:io or check Platform here — this class is pure config.
abstract final class AppConfig {
  // ── API base URL ──────────────────────────────────────────────────────────
  //
  // The trailing slash is intentionally omitted so endpoint paths can be
  // written as '$apiBaseUrl/api/...' without double-slash ambiguity.
  //
  // Default: production AWS dev-tunnel URL currently in use by the team.
  // Override at build time with:
  //   --dart-define=API_BASE_URL=http://10.0.2.2:8080
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://rvdj88q6-8000.brs.devtunnels.ms',
  );

  // ── Request timeout ───────────────────────────────────────────────────────
  //
  // Override for slower environments:
  //   --dart-define=API_TIMEOUT_SECONDS=30
  static const int _timeoutSecondsRaw = int.fromEnvironment(
    'API_TIMEOUT_SECONDS',
    defaultValue: 10,
  );

  static const Duration apiTimeout = Duration(seconds: _timeoutSecondsRaw);

  // ── Feature flags (extend as needed) ─────────────────────────────────────
  //
  // Example future use:
  //   --dart-define=ENABLE_QR_SCANNER=true
  //
  // static const bool enableQrScanner = bool.fromEnvironment(
  //   'ENABLE_QR_SCANNER',
  //   defaultValue: true,
  // );

  // Prevent instantiation — this is a pure namespace.
  AppConfig._();
}

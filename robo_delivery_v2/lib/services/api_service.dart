import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

// ─── CONSTANTS ─────────────────────────────────────────────────────────────
// FIX #5 (Flutter side): A short connect/read timeout prevents the UI from
// hanging indefinitely when campus Wi-Fi is congested. The backend's MQTT
// connect now times out in 5 s; we allow 10 s for the full HTTP round-trip
// (5 s MQTT + network RTT + FastAPI processing headroom).
const Duration _kApiTimeout = Duration(seconds: 10);

class ApiService {
  // Android emulator loopback to host machine's localhost.
  // Change to your machine's LAN IP (e.g. "192.168.0.X") for physical devices.
  static const String baseUrl = "https://rvdj88q6-8000.brs.devtunnels.ms";

  // ─── dispatchOrder ───────────────────────────────────────────────────────
  //
  // FIX #6 (Flutter side): The original body included `order_id` as a JSON
  // field. The backend's NavigateRequest model has been fixed to NOT declare
  // `order_id` in the body anymore — it comes exclusively from the URL path.
  // Sending `order_id` in the body would cause Pydantic to raise a 422
  // validation error on the updated backend because that field no longer
  // exists in the model.
  //
  // FIX #7 (Flutter side): The backend now always returns HTTP 200 with the
  // OTP even when the MQTT broker is unreachable (it returns status="otp_only"
  // in that case). We surface the `mqtt_connected` flag to the caller so the
  // UI can optionally show a hardware-offline warning.
  //
  // Returns a [DispatchResult] instead of a raw String? so callers have full
  // context without needing a second API call.
  Future<DispatchResult?> dispatchOrder(
    String orderId,
    String restaurantName,
  ) async {
    // FIX #6 — order_id is in the URL path only, NOT in the body.
    final url = Uri.parse("$baseUrl/api/orders/$orderId/dispatch");

    try {
      final response = await http
          .post(
            url,
            headers: {"Content-Type": "application/json"},
            body: jsonEncode({
              // order_id intentionally omitted from body — see FIX #6 above.
              "destination": {"x": 12.0, "y": -3.5},
              "restaurant_name": restaurantName,
            }),
          )
          .timeout(_kApiTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final result = DispatchResult.fromJson(data);
        debugPrint(
          "dispatchOrder success — OTP: ${result.otpCode} "
          "| status: ${result.status} "
          "| mqtt_connected: ${result.mqttConnected}",
        );
        return result;
      } else {
        // 422 = body schema mismatch (would catch FIX #6 regressions)
        // 502 = broker error (should no longer happen after FIX #7 on backend)
        debugPrint(
          "dispatchOrder failed — HTTP ${response.statusCode}: ${response.body}",
        );
      }
    } on Exception catch (e) {
      debugPrint("dispatchOrder connection error: $e");
    }
    return null;
  }

  // ─── validateOtp ─────────────────────────────────────────────────────────
  //
  // No structural changes needed here. The order_id passed to this function
  // must match the one used in dispatchOrder (both use the same path/key).
  // Added timeout for campus Wi-Fi resilience (FIX #5 Flutter side).
  Future<bool> validateOtp(String code, String orderId) async {
    final url = Uri.parse("$baseUrl/api/validate-code");

    try {
      final response = await http
          .post(
            url,
            headers: {"Content-Type": "application/json"},
            body: jsonEncode({
              "code": code,
              "order_id": orderId,
            }),
          )
          .timeout(_kApiTimeout);

      if (response.statusCode == 200) {
        debugPrint("validateOtp success: Compartimento aberto!");
        return true;
      } else {
        final Map<String, dynamic> error;
        try {
          error = jsonDecode(response.body) as Map<String, dynamic>;
        } catch (_) {
          debugPrint("validateOtp failed — HTTP ${response.statusCode} (non-JSON body)");
          return false;
        }
        // 401 → invalid/expired code
        // 503 → robot hard-offline (uncertain state still passes on backend)
        // 502 → MQTT publish failed for unlock command
        debugPrint(
          "validateOtp failed — HTTP ${response.statusCode}: ${error['detail']}",
        );
        return false;
      }
    } on Exception catch (e) {
      debugPrint("validateOtp connection error: $e");
      return false;
    }
  }
}

// ─── DispatchResult ──────────────────────────────────────────────────────────
//
// Typed wrapper for the /api/orders/{id}/dispatch response.
// Using a dedicated model instead of Map<String, dynamic> catches schema
// drift at compile time and makes callers readable.
class DispatchResult {
  final bool success;
  final String orderId;
  final String status;       // "dispatched" | "otp_only"
  final String otpCode;
  final bool mqttConnected;  // FIX #8: lets the UI surface a hardware warning
  final String gatewayMode;  // "full" | "otp_only" | "degraded"

  const DispatchResult({
    required this.success,
    required this.orderId,
    required this.status,
    required this.otpCode,
    required this.mqttConnected,
    required this.gatewayMode,
  });

  factory DispatchResult.fromJson(Map<String, dynamic> json) {
    return DispatchResult(
      success:       json['success'] as bool,
      orderId:       json['order_id'] as String,
      status:        json['status'] as String,
      otpCode:       json['otp_code'] as String,
      mqttConnected: json['mqtt_connected'] as bool,
      gatewayMode:   json['gateway_mode'] as String,
    );
  }

  /// True when the robot received the navigate command.
  bool get robotDispatched => mqttConnected;

  /// True when we have an OTP but the robot hasn't received the navigate
  /// command yet (broker was unreachable at dispatch time).
  bool get isOtpOnly => status == 'otp_only';
}
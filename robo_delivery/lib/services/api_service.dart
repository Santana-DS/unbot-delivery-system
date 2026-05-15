// lib/services/api_service.dart
//
// CHANGES IN THIS REVISION
// ────────────────────────
// Environment management:
//   • baseUrl is now sourced from AppConfig.apiBaseUrl (a compile-time
//     --dart-define constant) instead of a hardcoded string literal.
//   • _kApiTimeout is now sourced from AppConfig.apiTimeout.
//   • No other logic changes — ApiService remains a pure HTTP client.
//
// To run against the local Go server on an Android emulator:
//   flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8080
//
// See lib/config/app_config.dart for the full environment switching guide.

// ignore_for_file: prefer_const_constructors

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';

// ─── SEALED RESULT HIERARCHY ─────────────────────────────────────────────────
//
// Four exhaustive outcomes for POST /api/validate-code.
// The UI switches on this type — no status codes, no exceptions, no booleans
// leak past this file's boundary.
//
//   UnlockSuccess          HTTP 200  — gateway confirmed, MQTT published.
//   UnlockInvalidCode      HTTP 401  — code wrong, consumed, or expired.
//   UnlockRobotUnreachable HTTP 502  — OTP valid but MQTT publish failed.
//   UnlockNetworkError     timeout / socket exception / non-JSON body.

sealed class UnlockResult {
  const UnlockResult();
}

/// Gateway confirmed the OTP and published the unlock command to the robot.
final class UnlockSuccess extends UnlockResult {
  /// orderId echoed back by the gateway — use for logging / analytics.
  final String orderId;
  const UnlockSuccess({required this.orderId});
}

/// The code was not found, already consumed, or has expired.
/// The user must re-enter or re-scan; do NOT auto-retry.
final class UnlockInvalidCode extends UnlockResult {
  final String message;
  const UnlockInvalidCode({this.message = 'Código inválido ou expirado.'});
}

/// OTP was valid but the gateway could not reach the robot over MQTT.
/// The code has been consumed — a retry requires a fresh OTP from the gateway.
final class UnlockRobotUnreachable extends UnlockResult {
  final String message;
  const UnlockRobotUnreachable(
      {this.message = 'Robô temporariamente inacessível. Tente novamente.'});
}

/// Network-layer failure: timeout, no connectivity, or unexpected server error.
/// The code may or may not have been consumed — surface a retry option.
final class UnlockNetworkError extends UnlockResult {
  final String message;
  const UnlockNetworkError(
      {this.message = 'Sem conexão. Verifique sua internet.'});
}

// ─── API SERVICE ─────────────────────────────────────────────────────────────

class ApiService {
  // CHANGED: baseUrl and timeout now read from AppConfig (compile-time
  // --dart-define constants) instead of hardcoded strings.
  //
  // Default resolves to the production AWS tunnel URL when no
  // --dart-define=API_BASE_URL flag is provided at build time.
  static String get baseUrl => AppConfig.apiBaseUrl;

  // ─── validateOtp ───────────────────────────────────────────────────────────
  //
  // Sends POST /api/validate-code and maps every possible outcome to the
  // sealed UnlockResult hierarchy. No raw status codes or http.Response
  // objects are returned to the caller.
  Future<UnlockResult> validateOtp(String code, String orderId) async {
    final url = Uri.parse('$baseUrl/api/validate-code');

    try {
      final response = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'code': code, 'order_id': orderId}),
          )
          .timeout(AppConfig.apiTimeout);

      // ── Happy path ──────────────────────────────────────────────────────
      if (response.statusCode == 200) {
        final data = _parseJson(response.body);
        final echoed = data?['order_id'] as String? ?? orderId;
        debugPrint('validateOtp success — order: $echoed');
        return UnlockSuccess(orderId: echoed);
      }

      // ── Known error codes ───────────────────────────────────────────────
      final errBody = _parseJson(response.body);
      final detail = errBody?['error'] as String? ?? 'Unknown error';

      debugPrint(
          'validateOtp failed — HTTP ${response.statusCode}: $detail');

      if (response.statusCode == 401) {
        return UnlockInvalidCode(message: detail);
      }

      if (response.statusCode == 502) {
        return UnlockRobotUnreachable(message: detail);
      }

      return const UnlockNetworkError();

    } on TimeoutException {
      debugPrint('validateOtp timed out after ${AppConfig.apiTimeout.inSeconds}s');
      return const UnlockNetworkError(
          message: 'Tempo de resposta excedido. Tente novamente.');
    } on Exception catch (e) {
      debugPrint('validateOtp connection error: $e');
      return const UnlockNetworkError();
    }
  }

  // ─── dispatchOrder ─────────────────────────────────────────────────────────
  Future<DispatchResult?> dispatchOrder(
    String orderId,
    String restaurantName,
  ) async {
    final url = Uri.parse('$baseUrl/api/orders/$orderId/dispatch');

    try {
      final response = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'destination': {'x': 12.0, 'y': -3.5},
              'restaurant_name': restaurantName,
            }),
          )
          .timeout(AppConfig.apiTimeout);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final result = DispatchResult.fromJson(data);
        debugPrint(
          'dispatchOrder success — OTP: ${result.otpCode} '
          '| status: ${result.status} '
          '| mqtt_connected: ${result.mqttConnected}',
        );
        return result;
      }

      debugPrint(
          'dispatchOrder failed — HTTP ${response.statusCode}: ${response.body}');
    } on Exception catch (e) {
      debugPrint('dispatchOrder connection error: $e');
    }
    return null;
  }

  // ─── helpers ──────────────────────────────────────────────────────────────

  /// Parses a JSON body safely. Returns null on malformed responses.
  static Map<String, dynamic>? _parseJson(String body) {
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}

// ─── DispatchResult ──────────────────────────────────────────────────────────

class DispatchResult {
  final bool success;
  final String orderId;
  final String status;
  final String otpCode;
  final bool mqttConnected;
  final String gatewayMode;

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

  bool get robotDispatched => mqttConnected;
  bool get isOtpOnly => status == 'otp_only';
}

// lib/services/api_service.dart
//
// CHANGES IN THIS REVISION
// ────────────────────────
// Phase 1 — Typed unlock result:
//   • Replaced the previous `Future<bool> validateOtp(...)` with
//     `Future<UnlockResult> validateOtp(...)`.
//   • Introduced the sealed class hierarchy `UnlockResult` with four
//     exhaustive subtypes: UnlockSuccess, UnlockInvalidCode,
//     UnlockRobotUnreachable, UnlockNetworkError.
//   • The UI layer switches on UnlockResult and never sees a status code
//     or a raw exception. All HTTP/network surface area is quarantined here.
//   • dispatchOrder() is unchanged — it already used a typed result model.
//
// SEALED CLASS RATIONALE (Dart 3)
// ────────────────────────────────
// `sealed` forces every switch on UnlockResult to be exhaustive at compile
// time. If a future engineer adds a fifth subtype (e.g. UnlockRateLimited)
// the compiler will flag every unhandled switch site immediately — no silent
// fall-through to a wrong UI state at runtime.
// ignore_for_file: prefer_const_constructors

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

// ─── CONSTANTS ────────────────────────────────────────────────────────────────

const Duration _kApiTimeout = Duration(seconds: 10);

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
  // Swap for your production gateway URL via a build-time const or --dart-define.
  static const String baseUrl = 'https://rvdj88q6-8000.brs.devtunnels.ms';

  // ─── validateOtp ───────────────────────────────────────────────────────────
  //
  // Sends POST /api/validate-code and maps every possible outcome to the
  // sealed UnlockResult hierarchy. No raw status codes or http.Response
  // objects are returned to the caller.
  //
  // Parameters:
  //   code    — exactly 4 ASCII digit characters (validation is the caller's
  //             responsibility; the gateway also validates server-side).
  //   orderId — the active order identifier from ActiveOrder.orderId.
  Future<UnlockResult> validateOtp(String code, String orderId) async {
    final url = Uri.parse('$baseUrl/api/validate-code');

    try {
      final response = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'code': code, 'order_id': orderId}),
          )
          .timeout(_kApiTimeout);

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

      // Any other 4xx/5xx — treat as network-layer error; do not assume
      // the code was consumed since we don't know server state.
      return const UnlockNetworkError();

    } on TimeoutException {
      debugPrint('validateOtp timed out after ${_kApiTimeout.inSeconds}s');
      return const UnlockNetworkError(
          message: 'Tempo de resposta excedido. Tente novamente.');
    } on Exception catch (e) {
      debugPrint('validateOtp connection error: $e');
      return const UnlockNetworkError();
    }
  }

  // ─── dispatchOrder ─────────────────────────────────────────────────────────
  // Unchanged from previous revision — already uses a typed result model.
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
          .timeout(_kApiTimeout);

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

  /// Parses a JSON body safely. Returns null instead of throwing on malformed
  /// responses (e.g. an nginx 502 HTML page instead of a JSON body).
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

// lib/services/api_service.dart
//
// CHANGES IN THIS REVISION (Phase 1.5 — On-Demand Display)
// ──────────────────────────────────────────────────────────
// + wakeDisplay(orderId) — calls POST /api/orders/{id}/wake-display.
//   Returns a sealed WakeDisplayResult hierarchy so code_screen.dart
//   never sees raw status codes or http.Response objects.
//
// SEALED CLASS: WakeDisplayResult
//   WakeDisplayTriggered  — HTTP 200, ESP32 is rendering the QR.
//   WakeDisplayNotFound   — HTTP 404, order unknown or already completed.
//   WakeDisplayUnreachable — HTTP 502, MQTT broker down; fallback to manual.
//   WakeDisplayNetworkError — timeout / socket error.
//
// All other methods (validateOtp, dispatchOrder) are unchanged.
// ignore_for_file: prefer_const_constructors

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

// ─── CONSTANTS ────────────────────────────────────────────────────────────────

const Duration _kApiTimeout = Duration(seconds: 10);

// ─── WAKE DISPLAY RESULT HIERARCHY ───────────────────────────────────────────
//
// Exhaustive outcomes for POST /api/orders/{id}/wake-display.
// The compiler enforces that every switch in code_screen.dart handles all
// four cases — no silent fall-through to a wrong UI state.

sealed class WakeDisplayResult {
  const WakeDisplayResult();
}

/// ESP32 received the display command; QR is rendering on OLED.
final class WakeDisplayTriggered extends WakeDisplayResult {
  final String orderId;
  const WakeDisplayTriggered({required this.orderId});
}

/// Order not found or OTP already consumed (delivery completed).
/// Flutter should skip the scanner and show the manual OTP entry instead.
final class WakeDisplayNotFound extends WakeDisplayResult {
  final String message;
  const WakeDisplayNotFound(
      {this.message = 'Pedido não encontrado ou já concluído.'});
}

/// MQTT broker unreachable — ESP32 won't get the display command.
/// Flutter should offer manual OTP entry as fallback.
final class WakeDisplayUnreachable extends WakeDisplayResult {
  final String message;
  const WakeDisplayUnreachable(
      {this.message = 'Display do robô inacessível. Use o código manual.'});
}

/// Network-layer failure: timeout, no connectivity, unexpected server error.
final class WakeDisplayNetworkError extends WakeDisplayResult {
  final String message;
  const WakeDisplayNetworkError(
      {this.message = 'Sem conexão. Verifique sua internet.'});
}

// ─── UNLOCK RESULT HIERARCHY (unchanged) ─────────────────────────────────────

sealed class UnlockResult {
  const UnlockResult();
}

final class UnlockSuccess extends UnlockResult {
  final String orderId;
  const UnlockSuccess({required this.orderId});
}

final class UnlockInvalidCode extends UnlockResult {
  final String message;
  const UnlockInvalidCode({this.message = 'Código inválido ou expirado.'});
}

final class UnlockRobotUnreachable extends UnlockResult {
  final String message;
  const UnlockRobotUnreachable(
      {this.message = 'Robô temporariamente inacessível. Tente novamente.'});
}

final class UnlockNetworkError extends UnlockResult {
  final String message;
  const UnlockNetworkError(
      {this.message = 'Sem conexão. Verifique sua internet.'});
}

// ─── API SERVICE ─────────────────────────────────────────────────────────────

class ApiService {
  static const String baseUrl = 'http://3.22.171.3:8080';

  // ─── wakeDisplay ───────────────────────────────────────────────────────────
  //
  // Triggers the ESP32 to render the QR Code for the given order.
  // Must be awaited before pushing QrScannerScreen so the OLED is ready
  // by the time the customer points their camera at it.
  //
  // On WakeDisplayUnreachable or WakeDisplayNetworkError, the caller should
  // offer manual OTP entry rather than blocking the user entirely.
  Future<WakeDisplayResult> wakeDisplay(String orderId) async {
    final url = Uri.parse('$baseUrl/api/orders/$orderId/wake-display');

    try {
      final response = await http
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            // No body needed — orderId is in the path, no additional params.
          )
          .timeout(_kApiTimeout);

      if (response.statusCode == 200) {
        final data = _parseJson(response.body);
        final echoed = data?['order_id'] as String? ?? orderId;
        debugPrint('wakeDisplay success — order: $echoed');
        return WakeDisplayTriggered(orderId: echoed);
      }

      final errBody = _parseJson(response.body);
      final detail = errBody?['error'] as String? ?? 'Unknown error';

      debugPrint('wakeDisplay failed — HTTP ${response.statusCode}: $detail');

      if (response.statusCode == 404) {
        return WakeDisplayNotFound(message: detail);
      }
      if (response.statusCode == 502) {
        return WakeDisplayUnreachable(message: detail);
      }

      return const WakeDisplayNetworkError();
    } on TimeoutException {
      debugPrint('wakeDisplay timed out after ${_kApiTimeout.inSeconds}s');
      return const WakeDisplayNetworkError(
          message: 'Tempo de resposta excedido. Tente novamente.');
    } on Exception catch (e) {
      debugPrint('wakeDisplay connection error: $e');
      return const WakeDisplayNetworkError();
    }
  }

  // ─── validateOtp (unchanged) ───────────────────────────────────────────────

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

      if (response.statusCode == 200) {
        final data = _parseJson(response.body);
        final echoed = data?['order_id'] as String? ?? orderId;
        debugPrint('validateOtp success — order: $echoed');
        return UnlockSuccess(orderId: echoed);
      }

      final errBody = _parseJson(response.body);
      final detail = errBody?['error'] as String? ?? 'Unknown error';

      debugPrint('validateOtp failed — HTTP ${response.statusCode}: $detail');

      if (response.statusCode == 401) return UnlockInvalidCode(message: detail);
      if (response.statusCode == 502) return UnlockRobotUnreachable(message: detail);

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

  // ─── dispatchOrder (unchanged) ────────────────────────────────────────────

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
        return DispatchResult.fromJson(data);
      }

      debugPrint(
          'dispatchOrder failed — HTTP ${response.statusCode}: ${response.body}');
    } on Exception catch (e) {
      debugPrint('dispatchOrder connection error: $e');
    }
    return null;
  }

  // ─── helpers ──────────────────────────────────────────────────────────────

  static Map<String, dynamic>? _parseJson(String body) {
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}

// ─── DispatchResult (unchanged) ──────────────────────────────────────────────

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

  bool get isOtpOnly => status == 'otp_only';
}

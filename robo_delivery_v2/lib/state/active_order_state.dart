// lib/state/active_order_state.dart
//
// Global state for ALL in-flight delivery orders (multi-order support).
//
// ARCHITECTURE RATIONALE
// ──────────────────────
// Upgraded from ValueNotifier<ActiveOrder?> to ValueNotifier<List<ActiveOrder>>
// to support concurrent orders placed at different restaurants.
//
// CRITICAL INVARIANT — immutable swap:
//   ValueNotifier fires listeners only when its .value reference changes.
//   Calling activeOrdersNotifier.value.add(order) mutates the existing list
//   IN PLACE and does NOT trigger a rebuild. Every mutation must create a
//   new list and assign it to .value. The helpers addOrder() / removeOrder()
//   enforce this invariant at the call site — callers must never mutate
//   the list directly.
//
// ORDER HISTORY INTEGRATION (2025 refactor)
// ──────────────────────────────────────────
// removeOrder() now archives the departing order into pastOrdersNotifier
// (defined in user_state.dart) BEFORE removing it from the active list.
// This guarantees:
//   1. The archive step and the active-list removal are visually atomic —
//      no frame exists where an order is neither active nor archived.
//   2. The caller controls the `reason` label ('completed' | 'cancelled')
//      so the history UI can show appropriate badges.
//
// IMPORT GRAPH (acyclic)
// ───────────────────────
//   active_order_state.dart  imports  user_state.dart  ✓
//   user_state.dart          does NOT import  active_order_state.dart  ✓
//
// LIFETIME
// ────────
// Top-level final, instantiated once at program start, never disposed.
// Identical lifetime model to themeModeNotifier in main.dart.
//
// USAGE PATTERN
// ─────────────
// Append (from order_screen.dart after a successful dispatch):
//   addOrder(ActiveOrder(result: result, restaurant: r, ...));
//
// Remove after delivery confirmed (code_screen.dart — OTP validated):
//   removeOrder(order.orderId, reason: 'completed');
//
// Remove after user cancels (tracking_screen.dart — cancel dialog):
//   removeOrder(order.orderId, reason: 'cancelled');
//
// Read (in any widget):
//   ValueListenableBuilder<List<ActiveOrder>>(
//     valueListenable: activeOrdersNotifier,
//     builder: (context, orders, _) {
//       if (orders.isEmpty) return const _EmptyState();
//       return ListView(children: orders.map((o) => _OrderCard(o)).toList());
//     },
//   )

import 'package:flutter/foundation.dart';
import '../models/models.dart';
import '../services/api_service.dart';
// ORDER HISTORY: import archivePastOrder() from user_state — one-way dependency.
import 'user_state.dart';

// ─── ActiveOrder ─────────────────────────────────────────────────────────────
//
// Pairs the backend's DispatchResult (OTP, orderId, MQTT status) with the
// Restaurant object from the catalogue plus all display-ready strings.
//
// All display strings (itemsSummary, formattedTotal) are pre-computed at order
// time in order_screen.dart so this class stays 100% immutable and the widget
// layer stays 100% logic-free.
class ActiveOrder {
  /// The response from POST /api/orders/{id}/dispatch.
  /// Contains otpCode, orderId, mqttConnected, gatewayMode.
  final DispatchResult result;

  /// The restaurant the user ordered from.
  /// Provides emoji, name, and bgColor for the active order card UI.
  final Restaurant restaurant;

  /// The delivery address the user entered at order time.
  final String deliveryAddress;

  /// Human-readable summary of what was ordered (e.g. "2× Marmita Executiva").
  final String itemsSummary;

  /// The total order value in BRL, pre-formatted (e.g. "R$36,00").
  final String formattedTotal;

  /// UTC timestamp of when this order was confirmed.
  /// Used as a stable sort key so the list stays chronologically ordered
  /// and the badge count matches what the user expects.
  final DateTime placedAt;

  const ActiveOrder({
    required this.result,
    required this.restaurant,
    required this.deliveryAddress,
    required this.itemsSummary,
    required this.formattedTotal,
    required this.placedAt,
  });

  // Convenience pass-throughs — callers don't drill into .result for these.
  String get orderId   => result.orderId;
  String get otpCode   => result.otpCode;
  bool   get isOtpOnly => result.isOtpOnly;

  /// Last 6 chars of the orderId — safe short display ID for cards.
  /// e.g. "order_1714000000123" → "#000123"
  String get shortId {
    final id = result.orderId;
    return '#${id.length > 6 ? id.substring(id.length - 6) : id}';
  }
}

// ─── Global notifier ─────────────────────────────────────────────────────────
//
// Empty list  = no orders in transit.
// Non-empty   = one or more concurrent active orders.
//
// Always use addOrder() / removeOrder() below. Never mutate the list directly.
final ValueNotifier<List<ActiveOrder>> activeOrdersNotifier =
    ValueNotifier<List<ActiveOrder>>(const []);

// ─── Mutation helpers ─────────────────────────────────────────────────────────
//
// These are free functions (not methods on the notifier) so they can be imported
// and called from any screen without needing a reference to the notifier class.

/// Appends [order] to the active orders list.
/// Creates a new list to guarantee ValueNotifier fires its listeners.
void addOrder(ActiveOrder order) {
  // Defensive de-duplication: if the same orderId is dispatched twice
  // (e.g. the user taps "Confirm" rapidly), ignore the duplicate.
  final current = activeOrdersNotifier.value;
  if (current.any((o) => o.orderId == order.orderId)) return;

  // Chronological order: oldest first so the UI presents a natural queue.
  activeOrdersNotifier.value = [...current, order];
}

/// Removes the order identified by [orderId] from the active list **and**
/// archives it to [pastOrdersNotifier] so it appears in order history.
///
/// [reason] controls the history badge:
///   'completed' — OTP was validated; compartment opened successfully.
///   'cancelled' — user cancelled the order from the tracking screen.
///
/// Operation is atomic from the UI's perspective:
///   1. Find the departing order in the active list.
///   2. Write a PastOrder snapshot to pastOrdersNotifier (prepended).
///   3. Write the filtered active list to activeOrdersNotifier.
///   Both notifiers fire in the same synchronous call stack, so Flutter's
///   build scheduler sees both changes before the next frame is drawn.
///
/// No-op if the orderId is not found (safe to call multiple times).
void removeOrder(String orderId, {String reason = 'completed'}) {
  final current = activeOrdersNotifier.value;

  // Step 1 — find the order to archive.
  final departing = current.where((o) => o.orderId == orderId).firstOrNull;

  if (departing == null) {
    // orderId not in the active list — already removed or never existed.
    return;
  }

  // Step 2 — archive BEFORE mutating the active list so there is no frame
  // in which the order has vanished from both lists simultaneously.
  archivePastOrder(
    shortId: departing.shortId,
    orderId: departing.orderId,
    restaurantName: departing.restaurant.name,
    restaurantEmoji: departing.restaurant.emoji,
    restaurantBgColor: departing.restaurant.bgColor,
    itemsSummary: departing.itemsSummary,
    formattedTotal: departing.formattedTotal,
    deliveryAddress: departing.deliveryAddress,
    placedAt: departing.placedAt,
    reason: reason,
  );

  // Step 3 — remove from active list and fire the notifier.
  final updated = current.where((o) => o.orderId != orderId).toList();
  activeOrdersNotifier.value = updated;
}
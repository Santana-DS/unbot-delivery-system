// lib/state/user_state.dart
//
// GLOBAL USER IDENTITY & ORDER HISTORY
// ──────────────────────────────────────────────────────────────────────────────
//
// ARCHITECTURE
// ────────────
// Two top-level ValueNotifiers live here:
//
//   userStateNotifier      — reactive single source of truth for the logged-in
//                            user's identity. Any widget that reads name, email,
//                            or address wraps itself in a ValueListenableBuilder
//                            on this notifier and rebuilds automatically when
//                            the profile is saved.
//
//   pastOrdersNotifier     — append-only archive of completed / cancelled
//                            orders. Fed exclusively by removeOrder() in
//                            active_order_state.dart. The Profile screen's
//                            "Histórico de pedidos" sheet reads from this.
//
// IMMUTABILITY INVARIANT (same rule as activeOrdersNotifier)
// ───────────────────────────────────────────────────────────
// ValueNotifier fires listeners only when its .value *reference* changes.
// Both helpers below (updateUser, archiveOrder) always assign a brand-new
// object / list — never mutate in place.
//
// IMPORT GRAPH (acyclic by design)
// ─────────────────────────────────
//   user_state.dart        imports  active_order_state.dart  (for ActiveOrder)
//   active_order_state.dart imports  user_state.dart          (for archiveOrder)
//
// Wait — that would be a circular import. To break the cycle, pastOrdersNotifier
// is defined HERE but archiveOrder() is also defined here. active_order_state.dart
// calls archiveOrder() from this file. user_state.dart only imports models.dart
// and api_service.dart — never active_order_state.dart. Clean DAG.

import 'package:flutter/foundation.dart';
import '../models/models.dart';
import '../services/api_service.dart'; // for ActiveOrder type via active_order_state

// Re-export ActiveOrder so callers only need one import if desired.
// (ActiveOrder is defined in active_order_state.dart — we import it below
//  only from the models-adjacent file to avoid the cycle.)
//
// ⚠️  ActiveOrder lives in active_order_state.dart, which imports THIS file.
//     Therefore THIS file must NOT import active_order_state.dart.
//     We forward-declare the archive helper as a void Function(dynamic) and
//     cast at the call site — no: cleaner solution below.
//
// SOLUTION: pastOrdersNotifier stores ActiveOrder instances via the
// already-imported api_service.dart barrel. active_order_state.dart imports
// user_state.dart (one-way) and calls archiveOrder() defined here.
// The type ActiveOrder is forward-referenced through the import in
// active_order_state.dart itself — Dart resolves this fine because both
// files import models.dart and api_service.dart; there is no actual circular
// dependency at the type level.
//
// In practice: active_order_state.dart imports user_state.dart ✓
//              user_state.dart does NOT import active_order_state.dart ✓

// ─── UserModel ────────────────────────────────────────────────────────────────
//
// Fully immutable value object. copyWith() is the ONLY mutation surface —
// it returns a new instance, guaranteeing ValueNotifier fires its listeners
// every time updateUser() is called.
class UserModel {
  /// Display name shown in the AppBar greeting and avatar initials.
  final String name;

  /// Primary contact email (future: used for auth token).
  final String email;

  /// Phone number — stored as a raw string, formatted on display.
  final String phone;

  /// Default delivery address pre-filled in OrderScreen.
  final String address;

  /// Optional remote URL for a profile photo.
  /// Null = show initials avatar (current behaviour).
  final String? profileImageUrl;

  const UserModel({
    required this.name,
    required this.email,
    required this.phone,
    required this.address,
    this.profileImageUrl,
  });

  /// Returns the user's initials (up to 2 chars) for the avatar widget.
  /// 'Maria Silva' → 'MS' | 'João' → 'JO' | '' → '??'
  String get initials {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '??';
    if (parts.length == 1) {
      return parts.first.substring(0, parts.first.length.clamp(0, 2)).toUpperCase();
    }
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }

  /// Produces a new UserModel with the given fields overridden.
  /// Fields not provided keep their current values.
  UserModel copyWith({
    String? name,
    String? email,
    String? phone,
    String? address,
    String? profileImageUrl,
  }) {
    return UserModel(
      name: name ?? this.name,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      address: address ?? this.address,
      profileImageUrl: profileImageUrl ?? this.profileImageUrl,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserModel &&
          other.name == name &&
          other.email == email &&
          other.phone == phone &&
          other.address == address &&
          other.profileImageUrl == profileImageUrl;

  @override
  int get hashCode =>
      Object.hash(name, email, phone, address, profileImageUrl);
}

// ─── Default seed data ────────────────────────────────────────────────────────
//
// Hardcoded defaults replace every scattered 'Maria Silva' / 'Rua das Acácias'
// string across the codebase. All screens read from userStateNotifier.value.
const UserModel _kDefaultUser = UserModel(
  name: 'Maria Silva',
  email: 'maria.unb@gmail.com',
  phone: '(61) 99999-1234',
  address: 'Rua das Acácias, 42 - Asa Sul',
);

// ─── Global notifiers ─────────────────────────────────────────────────────────

/// Reactive single source of truth for the logged-in user's identity.
///
/// Read pattern (any widget):
/// ```dart
/// ValueListenableBuilder<UserModel>(
///   valueListenable: userStateNotifier,
///   builder: (context, user, _) => Text(user.address),
/// )
/// ```
///
/// Write pattern (ProfileScreen save button):
/// ```dart
/// updateUser(userStateNotifier.value.copyWith(address: _addrCtrl.text));
/// ```
final ValueNotifier<UserModel> userStateNotifier =
    ValueNotifier<UserModel>(_kDefaultUser);

/// Append-only archive of orders that have been completed or cancelled.
///
/// Newest entries are prepended (index 0 = most recent) so the history
/// list renders chronologically without an additional sort pass.
///
/// Read pattern (ProfileScreen history sheet):
/// ```dart
/// ValueListenableBuilder<List<PastOrder>>(
///   valueListenable: pastOrdersNotifier,
///   builder: (context, past, _) { ... },
/// )
/// ```
final ValueNotifier<List<PastOrder>> pastOrdersNotifier =
    ValueNotifier<List<PastOrder>>(const []);

// ─── PastOrder ────────────────────────────────────────────────────────────────
//
// Thin wrapper that pairs a snapshot of the ActiveOrder data with a
// completion timestamp and reason. Keeping this separate from ActiveOrder
// avoids polluting the in-flight order model with archive-only fields.
class PastOrder {
  /// Short display ID mirroring ActiveOrder.shortId.
  final String shortId;

  /// Full backend order identifier.
  final String orderId;

  /// Name of the restaurant (denormalised for offline rendering).
  final String restaurantName;

  /// Emoji used for the restaurant tile.
  final String restaurantEmoji;

  /// Pastel background hex (without #) for the emoji container.
  final String restaurantBgColor;

  /// Human-readable summary: "2× Marmita Executiva".
  final String itemsSummary;

  /// Pre-formatted total: "R$36,00".
  final String formattedTotal;

  /// Delivery address at time of order.
  final String deliveryAddress;

  /// UTC timestamp of when the order was originally placed.
  final DateTime placedAt;

  /// UTC timestamp of when the order left the active list.
  final DateTime completedAt;

  /// 'completed' | 'cancelled'
  final String reason;

  const PastOrder({
    required this.shortId,
    required this.orderId,
    required this.restaurantName,
    required this.restaurantEmoji,
    required this.restaurantBgColor,
    required this.itemsSummary,
    required this.formattedTotal,
    required this.deliveryAddress,
    required this.placedAt,
    required this.completedAt,
    required this.reason,
  });
}

// ─── Mutation helpers ─────────────────────────────────────────────────────────

/// Replaces the current user model with [updated].
///
/// Always pass the result of [UserModel.copyWith] — never construct a
/// UserModel manually at the call site to avoid accidentally resetting fields.
///
/// The equality check short-circuits the notifier if nothing actually changed
/// (e.g., user taps "Salvar" without editing anything), preventing spurious
/// rebuilds across the widget tree.
void updateUser(UserModel updated) {
  if (userStateNotifier.value == updated) return;
  userStateNotifier.value = updated;
}

/// Appends [order] to the past-orders archive.
///
/// Called exclusively from removeOrder() in active_order_state.dart so the
/// archive step is always atomic with the removal from the active list.
///
/// [reason] should be 'completed' (OTP validated) or 'cancelled' (user action).
///
/// Prepends rather than appends so pastOrdersNotifier.value[0] is always the
/// most recent entry — no sort needed in the UI.
void archivePastOrder({
  required String shortId,
  required String orderId,
  required String restaurantName,
  required String restaurantEmoji,
  required String restaurantBgColor,
  required String itemsSummary,
  required String formattedTotal,
  required String deliveryAddress,
  required DateTime placedAt,
  required String reason,
}) {
  final entry = PastOrder(
    shortId: shortId,
    orderId: orderId,
    restaurantName: restaurantName,
    restaurantEmoji: restaurantEmoji,
    restaurantBgColor: restaurantBgColor,
    itemsSummary: itemsSummary,
    formattedTotal: formattedTotal,
    deliveryAddress: deliveryAddress,
    placedAt: placedAt,
    completedAt: DateTime.now().toUtc(),
    reason: reason,
  );

  // Prepend to keep newest-first ordering without an extra sort pass.
  pastOrdersNotifier.value = [entry, ...pastOrdersNotifier.value];
}

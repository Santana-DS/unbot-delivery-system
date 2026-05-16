// lib/screens/client/profile_screen.dart
//
// REFACTOR: Global User Identity + Order History (2025)
// ──────────────────────────────────────────────────────
//
// CHANGES FROM ORIGINAL
// ─────────────────────
// 1. _FormRow converted from StatelessWidget to StatefulWidget.
//    The original used TextEditingController(text: value) inside build(),
//    which creates a brand-new controller on every rebuild — a memory leak
//    and a UX bug (cursor resets to position 0 on any setState). Controllers
//    are now created once in initState() and disposed in dispose().
//
// 2. Controllers are driven by userStateNotifier.value in initState() so
//    the fields are always pre-populated with the current user data, even
//    after a previous save mutated the notifier.
//
// 3. The "Salvar" AppBar button now calls updateUser() (from user_state.dart)
//    with a copyWith snapshot of all four controller values. ValueNotifier
//    fires only if the data actually changed (equality guard in updateUser).
//
// 4. Avatar initials are reactive: they read user.initials from the notifier
//    instead of the hardcoded 'MS' string.
//
// 5. "Histórico de pedidos" row now opens a bottom sheet that reads
//    pastOrdersNotifier. The sheet is self-contained and handles the
//    empty-state gracefully.
//
// 6. All AC.*(context) dynamic theme accessors are preserved throughout.

// ignore_for_file: prefer_const_constructors
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../theme/app_theme.dart';
import '../../widgets/widgets.dart';
import '../../main.dart';
import '../../state/user_state.dart';
import '../login_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  // ── Theme toggle ──────────────────────────────────────────────────────────
  late bool _isDarkMode;

  // ── Form controllers ──────────────────────────────────────────────────────
  // Created once in initState(), seeded from the current user model, and
  // disposed in dispose(). This is the correct pattern for controllers that
  // live inside a long-lived State object — never construct them inside build().
  late final TextEditingController _nameCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _addressCtrl;

  @override
  void initState() {
    super.initState();
    _isDarkMode = themeModeNotifier.value == ThemeMode.dark;

    // Seed from the global notifier so fields always reflect the latest save.
    final user = userStateNotifier.value;
    _nameCtrl    = TextEditingController(text: user.name);
    _emailCtrl   = TextEditingController(text: user.email);
    _phoneCtrl   = TextEditingController(text: user.phone);
    _addressCtrl = TextEditingController(text: user.address);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _addressCtrl.dispose();
    super.dispose();
  }

  // ── Save handler ──────────────────────────────────────────────────────────
  // Reads all four controllers, builds a copyWith snapshot, and hands it to
  // updateUser(). The equality guard in updateUser() prevents spurious
  // rebuilds if nothing changed. A SnackBar confirms the action.
  void _saveProfile() {
    final updated = userStateNotifier.value.copyWith(
      name:    _nameCtrl.text.trim(),
      email:   _emailCtrl.text.trim(),
      phone:   _phoneCtrl.text.trim(),
      address: _addressCtrl.text.trim(),
    );
    updateUser(updated);
    showAppSnack(context, 'Perfil atualizado com sucesso!');
  }

  // ── Order history sheet ───────────────────────────────────────────────────
  void _showHistory() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _OrderHistorySheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    // ValueListenableBuilder wraps the entire body so every text element
    // that references user data (name, initials) updates reactively.
    return ValueListenableBuilder<UserModel>(
      valueListenable: userStateNotifier,
      builder: (context, user, _) {
        return Scaffold(
          backgroundColor: AC.surface(context),
          appBar: AppBar(
            automaticallyImplyLeading: false,
            backgroundColor: AC.surface(context),
            surfaceTintColor: Colors.transparent,
            title: const Text('Meu Perfil'),
            actions: [
              TextButton(
                onPressed: _saveProfile,
                child: Text(
                  'Salvar',
                  style: GoogleFonts.dmSans(
                    color: AppColors.accent,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                // ── Avatar ────────────────────────────────────────────────
                Center(
                  child: Column(
                    children: [
                      Hero(
                        tag: 'user-avatar',
                        child: Stack(
                          children: [
                            Container(
                              width: 80,
                              height: 80,
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [AppColors.accent, Color(0xFFFF9F6B)],
                                ),
                                shape: BoxShape.circle,
                              ),
                              // REACTIVE: initials computed from user.name
                              child: Center(
                                child: Text(
                                  user.initials,
                                  style: const TextStyle(
                                    fontSize: 28,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: Container(
                                width: 26,
                                height: 26,
                                decoration: BoxDecoration(
                                  color: AC.primary(context),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.camera_alt_rounded,
                                  size: 14,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      // REACTIVE: name from notifier
                      Text(
                        user.name,
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: AC.primary(context),
                        ),
                      ),
                      Text(
                        'Cliente · desde 2024',
                        style: GoogleFonts.dmSans(
                            fontSize: 13, color: AC.muted(context)),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 28),
                SectionLabel('Dados pessoais'),

                // ── Form fields — controllers owned by State, not rebuilt ──
                _ControlledFormRow(
                  label: 'Nome completo',
                  icon: Icons.person_outline_rounded,
                  controller: _nameCtrl,
                  keyboardType: TextInputType.name,
                  textCapitalization: TextCapitalization.words,
                ),
                const SizedBox(height: 14),
                _ControlledFormRow(
                  label: 'E-mail',
                  icon: Icons.email_outlined,
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 14),
                _ControlledFormRow(
                  label: 'Telefone',
                  icon: Icons.phone_outlined,
                  controller: _phoneCtrl,
                  keyboardType: TextInputType.phone,
                ),
                const SizedBox(height: 14),
                _ControlledFormRow(
                  label: 'Endereço padrão',
                  icon: Icons.location_on_outlined,
                  controller: _addressCtrl,
                  keyboardType: TextInputType.streetAddress,
                ),

                const SizedBox(height: 24),
                SectionLabel('Configurações'),

                AppCard(
                  child: Column(
                    children: [
                      _SettingRow(
                        icon: Icons.notifications_outlined,
                        label: 'Notificações push',
                        trailing: AppToggle(value: true, onChanged: (_) {}),
                      ),
                      Divider(height: 1, color: AC.border(context)),
                      _SettingRow(
                        icon: Icons.location_on_outlined,
                        label: 'Compartilhar localização',
                        trailing: AppToggle(value: true, onChanged: (_) {}),
                      ),
                      Divider(height: 1, color: AC.border(context)),
                      _SettingRow(
                        icon: Icons.dark_mode_outlined,
                        label: 'Modo escuro',
                        trailing: AppToggle(
                          value: _isDarkMode,
                          onChanged: (value) {
                            setState(() => _isDarkMode = value);
                            themeModeNotifier.value =
                                value ? ThemeMode.dark : ThemeMode.light;
                          },
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 14),

                AppCard(
                  child: Column(
                    children: [
                      // WIRED: opens pastOrdersNotifier sheet
                      _SettingRow(
                        icon: Icons.history_rounded,
                        label: 'Histórico de pedidos',
                        trailing: Icon(Icons.chevron_right_rounded,
                            color: AC.muted(context)),
                        onTap: _showHistory,
                      ),
                      Divider(height: 1, color: AC.border(context)),
                      _SettingRow(
                        icon: Icons.help_outline_rounded,
                        label: 'Ajuda e suporte',
                        trailing: Icon(Icons.chevron_right_rounded,
                            color: AC.muted(context)),
                        onTap: () {},
                      ),
                      Divider(height: 1, color: AC.border(context)),
                      _SettingRow(
                        icon: Icons.privacy_tip_outlined,
                        label: 'Privacidade',
                        trailing: Icon(Icons.chevron_right_rounded,
                            color: AC.muted(context)),
                        onTap: () {},
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),

                AppButton(
                  label: 'Sair da conta',
                  onTap: () => Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(builder: (_) => const LoginScreen()),
                    (r) => false,
                  ),
                  outlined: true,
                  color: Colors.red,
                  icon: Icons.logout_rounded,
                ),

                const SizedBox(height: 32),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ─── Controlled Form Row ──────────────────────────────────────────────────────
//
// StatelessWidget that accepts a pre-existing controller from the parent State.
// This replaces the original _FormRow which created a new controller on every
// build() call (memory leak + cursor-reset bug).
//
// The parent (_ProfileScreenState) owns, seeds, and disposes the controllers.
class _ControlledFormRow extends StatelessWidget {
  final String label;
  final IconData icon;
  final TextEditingController controller;
  final TextInputType keyboardType;
  final TextCapitalization textCapitalization;

  const _ControlledFormRow({
    required this.label,
    required this.icon,
    required this.controller,
    this.keyboardType = TextInputType.text,
    this.textCapitalization = TextCapitalization.none,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FormFieldLabel(label),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          textCapitalization: textCapitalization,
          style: TextStyle(color: AC.primary(context)),
          decoration: InputDecoration(
            prefixIcon: Icon(icon, color: AC.muted(context), size: 20),
          ),
        ),
      ],
    );
  }
}

// ─── Setting Row ─────────────────────────────────────────────────────────────
class _SettingRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget trailing;
  final VoidCallback? onTap;

  const _SettingRow({
    required this.icon,
    required this.label,
    required this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: AC.muted(context)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: GoogleFonts.dmSans(
                    fontSize: 14, color: AC.primary(context)),
              ),
            ),
            trailing,
          ],
        ),
      ),
    );
  }
}

// ─── Order History Bottom Sheet ───────────────────────────────────────────────
//
// Reads pastOrdersNotifier reactively. Each tile shows the restaurant emoji,
// name, items summary, total, and a completion/cancellation badge.
// The sheet handles the empty state (no completed orders yet) gracefully.
class _OrderHistorySheet extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AC.surface(context),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      // Max 80% of screen height; scrollable for large histories.
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.80,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AC.primary(context).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Histórico de pedidos',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AC.primary(context),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: Icon(Icons.close_rounded, color: AC.muted(context)),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // Body — reactive to pastOrdersNotifier
          Flexible(
            child: ValueListenableBuilder<List<PastOrder>>(
              valueListenable: pastOrdersNotifier,
              builder: (context, past, _) {
                if (past.isEmpty) {
                  return _HistoryEmptyState();
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                  itemCount: past.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (ctx, i) => _PastOrderTile(order: past[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Past Order Tile ──────────────────────────────────────────────────────────
class _PastOrderTile extends StatelessWidget {
  final PastOrder order;

  const _PastOrderTile({required this.order});

  @override
  Widget build(BuildContext context) {
    final isCompleted = order.reason == 'completed';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AC.card(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AC.border(context)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Restaurant emoji container
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Color(
                  int.parse('FF${order.restaurantBgColor}', radix: 16)),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Text(
                order.restaurantEmoji,
                style: const TextStyle(fontSize: 24),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        '${order.shortId} · ${order.restaurantName}',
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AC.primary(context),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Completion / cancellation badge
                    StatusBadge(
                      label: isCompleted ? 'Entregue' : 'Cancelado',
                      bg: isCompleted
                          ? AppColors.statusDelivered
                          : AppColors.statusPending,
                      textColor: isCompleted
                          ? AppColors.statusDeliveredText
                          : AppColors.statusPendingText,
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  order.itemsSummary,
                  style: GoogleFonts.dmSans(
                      fontSize: 12, color: AC.muted(context)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Icon(Icons.location_on_outlined,
                        size: 12, color: AC.muted(context)),
                    const SizedBox(width: 3),
                    Expanded(
                      child: Text(
                        order.deliveryAddress,
                        style: GoogleFonts.dmSans(
                            fontSize: 11, color: AC.muted(context)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      order.formattedTotal,
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AC.primary(context),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // Completion timestamp
                Text(
                  _formatDate(order.completedAt),
                  style: GoogleFonts.dmSans(
                      fontSize: 10, color: AC.muted(context)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// e.g. "25/04/2025 às 14:32"
  String _formatDate(DateTime utc) {
    final local = utc.toLocal();
    final d = local.day.toString().padLeft(2, '0');
    final m = local.month.toString().padLeft(2, '0');
    final y = local.year;
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$d/$m/$y às $hh:$mm';
  }
}

// ─── History Empty State ──────────────────────────────────────────────────────
class _HistoryEmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: AC.card(context),
              shape: BoxShape.circle,
              border: Border.all(color: AC.border(context)),
            ),
            child: Icon(Icons.receipt_long_rounded,
                size: 32, color: AC.muted(context)),
          ),
          const SizedBox(height: 16),
          Text(
            'Nenhum pedido concluído',
            style: GoogleFonts.spaceGrotesk(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AC.primary(context),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Seus pedidos entregues\naparecerão aqui.',
            textAlign: TextAlign.center,
            style: GoogleFonts.dmSans(fontSize: 13, color: AC.muted(context)),
          ),
        ],
      ),
    );
  }
}
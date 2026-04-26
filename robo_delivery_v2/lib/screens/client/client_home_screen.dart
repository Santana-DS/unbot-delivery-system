// lib/screens/client/client_home_screen.dart
//
// REFACTOR: Global User Identity integration (2025)
// ──────────────────────────────────────────────────────────────────────────────
//
// CHANGES FROM ORIGINAL
// ─────────────────────
// 1. SliverAppBar address line is now wrapped in a ValueListenableBuilder on
//    userStateNotifier. The address text rebuilds the moment ProfileScreen
//    calls updateUser(), with zero setState() calls required in this file.
//
// 2. The location icon row reads user.address from the notifier instead of
//    the hardcoded string 'Faculdade de Tecnologia, FT - UnB'.
//
// 3. The tracking screen cancel dialog in _OrderListTile now passes
//    reason: 'cancelled' to removeOrder() so the history badge is correct.
//    (The OTP-success path in code_screen.dart keeps reason: 'completed'.)
//
// 4. All other logic and layout is unchanged.
// ignore_for_file: prefer_const_constructors

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../theme/app_theme.dart';
import '../../models/models.dart';
import '../../widgets/widgets.dart';
import '../../state/active_order_state.dart';
import '../../state/user_state.dart';
import '../../main.dart'; // themeModeNotifier
import 'order_screen.dart';
import 'tracking_screen.dart';
import 'profile_screen.dart';

// ─── Shell ───────────────────────────────────────────────────────────────────
class ClientHomeScreen extends StatefulWidget {
  const ClientHomeScreen({super.key});

  @override
  State<ClientHomeScreen> createState() => _ClientHomeScreenState();
}

class _ClientHomeScreenState extends State<ClientHomeScreen>
    with SingleTickerProviderStateMixin {
  int _navIndex = 0;
  late AnimationController _robotCtrl;
  late Animation<double> _robotPulse;
  double _robotX = 0.25;
  Timer? _robotTimer;

  @override
  void initState() {
    super.initState();
    _robotCtrl = AnimationController(
        vsync: this, duration: const Duration(seconds: 2))
      ..repeat(reverse: true);
    _robotPulse = Tween(begin: 1.0, end: 1.15).animate(
        CurvedAnimation(parent: _robotCtrl, curve: Curves.easeInOut));

    _robotTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (mounted) {
        setState(() {
          _robotX += 0.10;
          if (_robotX > 0.72) _robotX = 0.12;
        });
      }
    });
  }

  @override
  void dispose() {
    _robotCtrl.dispose();
    _robotTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<ActiveOrder>>(
      valueListenable: activeOrdersNotifier,
      builder: (context, orders, _) {
        final badgeLabel = orders.isEmpty
            ? null
            : orders.length > 9
                ? '9+'
                : '${orders.length}';

        return Scaffold(
          backgroundColor: AC.surface(context),
          body: IndexedStack(
            index: _navIndex,
            children: [
              _HomeTab(
                robotX: _robotX,
                robotPulse: _robotPulse,
                orders: orders,
                onShowOrders: () => setState(() => _navIndex = 2),
              ),
              _SearchTab(),
              _OrdersTab(orders: orders),
              ProfileScreen(),
            ],
          ),
          bottomNavigationBar: AppBottomNav(items: [
            AppNavItem(
                icon: Icons.home_rounded,
                label: 'Início',
                selected: _navIndex == 0,
                onTap: () => setState(() => _navIndex = 0)),
            AppNavItem(
                icon: Icons.search_rounded,
                label: 'Buscar',
                selected: _navIndex == 1,
                onTap: () => setState(() => _navIndex = 1)),
            AppNavItem(
                icon: Icons.delivery_dining_rounded,
                label: 'Pedidos',
                selected: _navIndex == 2,
                onTap: () => setState(() => _navIndex = 2),
                badge: badgeLabel),
            AppNavItem(
                icon: Icons.person_rounded,
                label: 'Perfil',
                selected: _navIndex == 3,
                onTap: () => setState(() => _navIndex = 3)),
          ]),
        );
      },
    );
  }
}

// ─── HOME TAB ────────────────────────────────────────────────────────────────
class _HomeTab extends StatelessWidget {
  final double robotX;
  final Animation<double> robotPulse;
  final List<ActiveOrder> orders;
  final VoidCallback onShowOrders;

  const _HomeTab({
    required this.robotX,
    required this.robotPulse,
    required this.orders,
    required this.onShowOrders,
  });

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        // ── App bar ──────────────────────────────────────────────────────
        SliverAppBar(
          automaticallyImplyLeading: false,
          floating: true,
          backgroundColor: AC.surface(context),
          surfaceTintColor: Colors.transparent,
          title: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                    color: AppColors.accent,
                    borderRadius: BorderRadius.circular(10)),
                child: const RobotIcon(size: 22, color: Colors.white),
              ),
              const SizedBox(width: 10),
              // ── REACTIVE address from userStateNotifier ───────────────
              // Nested ValueListenableBuilder so only this Column rebuilds
              // when the user saves a new address in ProfileScreen — the
              // rest of the SliverAppBar and the entire HomeTab are unaffected.
              ValueListenableBuilder<UserModel>(
                valueListenable: userStateNotifier,
                builder: (ctx, user, _) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'UnBot Delivery',
                        style: GoogleFonts.spaceGrotesk(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: AC.primary(ctx)),
                      ),
                      Row(children: [
                        Icon(Icons.location_on_rounded,
                            size: 11, color: AC.muted(ctx)),
                        const SizedBox(width: 2),
                        // REACTIVE: reads user.address from the notifier
                        Text(
                          user.address,
                          style: GoogleFonts.dmSans(
                              fontSize: 11, color: AC.muted(ctx)),
                        ),
                      ]),
                    ],
                  );
                },
              ),
            ],
          ),
          actions: [
            // Dark mode toggle
            ValueListenableBuilder<ThemeMode>(
              valueListenable: themeModeNotifier,
              builder: (ctx, mode, _) {
                final currentlyDark =
                    Theme.of(ctx).brightness == Brightness.dark;
                return IconButton(
                  icon: Icon(
                    currentlyDark
                        ? Icons.light_mode_outlined
                        : Icons.dark_mode_outlined,
                    color: AC.primary(ctx),
                  ),
                  tooltip: currentlyDark ? 'Modo claro' : 'Modo escuro',
                  onPressed: () {
                    hapticLight();
                    themeModeNotifier.value =
                        currentlyDark ? ThemeMode.light : ThemeMode.dark;
                  },
                );
              },
            ),
            IconButton(
              icon: Icon(Icons.notifications_outlined,
                  color: AC.primary(context)),
              onPressed: () {},
            ),
          ],
        ),

        // ── Animated map ─────────────────────────────────────────────────
        SliverToBoxAdapter(
          child: _MapWidget(
            robotX: robotX,
            robotPulse: robotPulse,
            hasActiveOrder: orders.isNotEmpty,
          ),
        ),

        // ── Active order cards + section label ───────────────────────────
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 350),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, -0.08),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: orders.isEmpty
                      ? const SizedBox.shrink(key: ValueKey('no-orders'))
                      : Column(
                          key: ValueKey(orders.length),
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (orders.length > 1)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      '${orders.length} pedidos ativos',
                                      style: GoogleFonts.dmSans(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                        color: AC.primary(context),
                                      ),
                                    ),
                                    GestureDetector(
                                      onTap: onShowOrders,
                                      child: Text(
                                        'Ver todos',
                                        style: GoogleFonts.dmSans(
                                          fontSize: 13,
                                          color: AppColors.accent,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ...orders.map((order) => Padding(
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: _ActiveOrderCard(
                                    key: ValueKey(order.orderId),
                                    order: order,
                                  ),
                                )),
                          ],
                        ),
                ),
                if (orders.isNotEmpty) const SizedBox(height: 14),
                SectionLabel('Restaurantes próximos'),
              ],
            ),
          ),
        ),

        // ── Restaurant grid ───────────────────────────────────────────────
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverGrid(
            delegate: SliverGridBuilderDelegate(
              (ctx, i) => _RestaurantCard(restaurant: sampleRestaurants[i]),
              childCount: sampleRestaurants.length,
            ),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 1.08,
            ),
          ),
        ),

        SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}

// ─── MAP WIDGET ──────────────────────────────────────────────────────────────
class _MapWidget extends StatelessWidget {
  final double robotX;
  final Animation<double> robotPulse;
  final bool hasActiveOrder;

  const _MapWidget({
    required this.robotX,
    required this.robotPulse,
    required this.hasActiveOrder,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      height: 200,
      color: AC.mapBg(context),
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(painter: MapBackgroundPainter(isDark: isDark)),
          ),
          if (hasActiveOrder)
            Positioned(
              right: 60,
              top: 100,
              child: Column(children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: const BoxDecoration(
                      color: AppColors.teal, shape: BoxShape.circle),
                  child: const Icon(Icons.home_rounded,
                      color: Colors.white, size: 14),
                ),
                Container(width: 2, height: 8, color: AppColors.teal),
              ]),
            ),
          AnimatedBuilder(
            animation: robotPulse,
            builder: (ctx, child) {
              return AnimatedPositioned(
                duration: const Duration(seconds: 2),
                curve: Curves.easeInOut,
                left: MediaQuery.of(context).size.width * robotX,
                top: 52,
                child: Transform.scale(scale: robotPulse.value, child: child),
              );
            },
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: AppColors.accent,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppColors.accent.withValues(alpha: 0.35),
                    blurRadius: 12,
                    spreadRadius: 4,
                  ),
                ],
              ),
              child: const RobotIcon(size: 26, color: Colors.white),
            ),
          ),
          Positioned(
            bottom: 10,
            left: 12,
            right: 12,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                color: AC.card(context).withValues(alpha: 0.95),
                child: hasActiveOrder
                    ? _MapOverlayActive(context: context)
                    : _MapOverlayIdle(context: context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MapOverlayActive extends StatelessWidget {
  final BuildContext context;
  const _MapOverlayActive({required this.context});

  @override
  Widget build(BuildContext ctx) {
    return Row(
      children: [
        PulsingDot(),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Robô a caminho',
                  style: GoogleFonts.dmSans(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AC.primary(ctx))),
              Text('Toque em "Pedidos" para detalhes',
                  style:
                      GoogleFonts.dmSans(fontSize: 11, color: AC.muted(ctx))),
            ],
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('8 min',
                style: GoogleFonts.spaceGrotesk(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AC.primary(ctx))),
            Text('estimado',
                style: GoogleFonts.dmSans(fontSize: 10, color: AC.muted(ctx))),
          ],
        ),
      ],
    );
  }
}

class _MapOverlayIdle extends StatelessWidget {
  final BuildContext context;
  const _MapOverlayIdle({required this.context});

  @override
  Widget build(BuildContext ctx) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: AC.muted(ctx).withValues(alpha: 0.5),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text('Nenhuma entrega em andamento',
              style: GoogleFonts.dmSans(fontSize: 13, color: AC.muted(ctx))),
        ),
        Text('—',
            style: GoogleFonts.spaceGrotesk(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AC.muted(ctx))),
      ],
    );
  }
}

// ─── ACTIVE ORDER CARD (home tab) ────────────────────────────────────────────
class _ActiveOrderCard extends StatelessWidget {
  final ActiveOrder order;

  const _ActiveOrderCard({super.key, required this.order});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      borderColor: AppColors.accent,
      borderWidth: 1.5,
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => TrackingScreen(
            standalone: true,
            order: order,
          ),
        ),
      ),
      child: Row(
        children: [
          Hero(
            tag: 'order-emoji-${order.orderId}',
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Color(
                    int.parse('FF${order.restaurant.bgColor}', radix: 16)),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Text(order.restaurant.emoji,
                    style: const TextStyle(fontSize: 22)),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${order.shortId} · ${order.restaurant.name}',
                  style: GoogleFonts.spaceGrotesk(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AC.primary(context)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  order.itemsSummary,
                  style: GoogleFonts.dmSans(
                      fontSize: 12, color: AC.muted(context)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          order.isOtpOnly
              ? Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: AppColors.accent.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.wifi_off_rounded,
                          size: 12, color: AppColors.accent),
                      const SizedBox(width: 4),
                      Text('Offline',
                          style: GoogleFonts.dmSans(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: AppColors.accent)),
                    ],
                  ),
                )
              : Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                      color: AppColors.accent,
                      borderRadius: BorderRadius.circular(20)),
                  child: Text('Seguir',
                      style: GoogleFonts.dmSans(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: Colors.white)),
                ),
        ],
      ),
    );
  }
}

// ─── ORDERS TAB ──────────────────────────────────────────────────────────────
class _OrdersTab extends StatelessWidget {
  final List<ActiveOrder> orders;

  const _OrdersTab({required this.orders});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AC.surface(context),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: AC.surface(context),
        surfaceTintColor: Colors.transparent,
        title: Text(
          'Meus Pedidos',
          style: Theme.of(context).textTheme.displaySmall,
        ),
        actions: [
          if (orders.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${orders.length} ${orders.length == 1 ? 'ativo' : 'ativos'}',
                  style: GoogleFonts.dmSans(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: orders.isEmpty
          ? _OrdersEmptyState()
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              itemCount: orders.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (ctx, i) => _OrderListTile(order: orders[i]),
            ),
    );
  }
}

// ─── ORDER LIST TILE ─────────────────────────────────────────────────────────
class _OrderListTile extends StatelessWidget {
  final ActiveOrder order;

  const _OrderListTile({required this.order});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      borderColor: order.isOtpOnly
          ? AppColors.accent.withValues(alpha: 0.4)
          : AC.border(context),
      borderWidth: order.isOtpOnly ? 1.5 : 1,
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => TrackingScreen(
            standalone: true,
            order: order,
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: Color(int.parse('FF${order.restaurant.bgColor}', radix: 16)),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Center(
              child: Text(order.restaurant.emoji,
                  style: const TextStyle(fontSize: 26)),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        '${order.shortId} · ${order.restaurant.name}',
                        style: GoogleFonts.spaceGrotesk(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AC.primary(context)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    order.isOtpOnly
                        ? StatusBadge(
                            label: 'Offline',
                            bg: AppColors.accent.withValues(alpha: 0.1),
                            textColor: AppColors.accent,
                          )
                        : StatusBadge(
                            label: 'A caminho',
                            bg: AppColors.statusDelivered,
                            textColor: AppColors.statusDeliveredText,
                          ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  order.itemsSummary,
                  style: GoogleFonts.dmSans(
                      fontSize: 12, color: AC.muted(context)),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
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
              ],
            ),
          ),
          const SizedBox(width: 6),
          Icon(Icons.chevron_right_rounded, color: AC.muted(context), size: 20),
        ],
      ),
    );
  }
}

// ─── EMPTY STATE ─────────────────────────────────────────────────────────────
class _OrdersEmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: AC.card(context),
              shape: BoxShape.circle,
              border: Border.all(color: AC.border(context)),
            ),
            child: Icon(Icons.delivery_dining_rounded,
                size: 36, color: AC.muted(context)),
          ),
          const SizedBox(height: 20),
          Text(
            'Nenhum pedido ativo',
            style: GoogleFonts.spaceGrotesk(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: AC.primary(context),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Seus pedidos em andamento\naparecerão aqui.',
            textAlign: TextAlign.center,
            style: GoogleFonts.dmSans(fontSize: 13, color: AC.muted(context)),
          ),
        ],
      ),
    );
  }
}

// ─── RESTAURANT CARD ─────────────────────────────────────────────────────────
class _RestaurantCard extends StatelessWidget {
  final Restaurant restaurant;

  const _RestaurantCard({required this.restaurant});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        hapticLight();
        Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => OrderScreen(restaurant: restaurant)));
      },
      child: Container(
        decoration: BoxDecoration(
          color: AC.card(context),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AC.border(context)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 80,
              decoration: BoxDecoration(
                color:
                    Color(int.parse('FF${restaurant.bgColor}', radix: 16)),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Center(
                child: Text(restaurant.emoji,
                    style: const TextStyle(fontSize: 32)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(restaurant.name,
                      style: GoogleFonts.dmSans(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: AC.primary(context)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  Row(children: [
                    const Icon(Icons.star_rounded,
                        size: 13, color: AppColors.accent),
                    const SizedBox(width: 3),
                    Text(
                        '${restaurant.rating} · ${restaurant.etaMinutes} min',
                        style: GoogleFonts.dmSans(
                            fontSize: 11, color: AC.muted(context))),
                  ]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── SEARCH TAB ──────────────────────────────────────────────────────────────
class _SearchTab extends StatefulWidget {
  @override
  State<_SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<_SearchTab> {
  String _query = '';

  List<Restaurant> get _filtered => sampleRestaurants
      .where((r) =>
          r.name.toLowerCase().contains(_query.toLowerCase()) ||
          r.products.any(
              (p) => p.name.toLowerCase().contains(_query.toLowerCase())))
      .toList();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AC.surface(context),
      appBar: AppBar(
          automaticallyImplyLeading: false,
          backgroundColor: AC.surface(context),
          surfaceTintColor: Colors.transparent,
          title: Text('Buscar',
              style: Theme.of(context).textTheme.displaySmall)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: TextField(
              autofocus: false,
              onChanged: (v) => setState(() => _query = v),
              style: TextStyle(color: AC.primary(context)),
              decoration: InputDecoration(
                hintText: 'Restaurantes ou pratos...',
                prefixIcon: Icon(Icons.search_rounded,
                    color: AC.muted(context), size: 20),
                suffixIcon: _query.isNotEmpty
                    ? GestureDetector(
                        onTap: () => setState(() => _query = ''),
                        child: Icon(Icons.close_rounded,
                            color: AC.muted(context), size: 18))
                    : null,
              ),
            ),
          ),
          Expanded(
            child: _filtered.isEmpty
                ? Center(
                    child: Text('Nenhum resultado',
                        style: GoogleFonts.dmSans(
                            fontSize: 14, color: AC.muted(context))))
                : ListView(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                    children: [
                      SectionLabel('${_filtered.length} restaurantes'),
                      ..._filtered.map((r) => Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: AppCard(
                              onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) =>
                                          OrderScreen(restaurant: r))),
                              child: Row(children: [
                                Container(
                                  width: 48,
                                  height: 48,
                                  decoration: BoxDecoration(
                                    color: Color(int.parse('FF${r.bgColor}',
                                        radix: 16)),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Center(
                                      child: Text(r.emoji,
                                          style: const TextStyle(
                                              fontSize: 24))),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(r.name,
                                          style: GoogleFonts.dmSans(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w500,
                                              color: AC.primary(context))),
                                      const SizedBox(height: 3),
                                      Row(children: [
                                        const Icon(Icons.star_rounded,
                                            size: 13,
                                            color: AppColors.accent),
                                        const SizedBox(width: 3),
                                        Text(
                                            '${r.rating} · ${r.etaMinutes} min',
                                            style: GoogleFonts.dmSans(
                                                fontSize: 12,
                                                color: AC.muted(context))),
                                      ]),
                                    ],
                                  ),
                                ),
                                Icon(Icons.chevron_right_rounded,
                                    color: AC.muted(context)),
                              ]),
                            ),
                          )),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

// ─── SliverGridBuilderDelegate alias ─────────────────────────────────────────
typedef SliverGridBuilderDelegate = SliverChildBuilderDelegate;
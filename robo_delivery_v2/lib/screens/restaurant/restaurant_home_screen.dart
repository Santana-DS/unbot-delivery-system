// ignore_for_file: prefer_const_literals_to_create_immutables, prefer_const_constructors
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../theme/app_theme.dart';
import '../../models/models.dart';
import '../../widgets/widgets.dart';
import '../../main.dart';
import '../login_screen.dart';
import 'restaurant_products_screen.dart';
import 'restaurant_tracking_screen.dart';

class RestaurantHomeScreen extends StatefulWidget {
  const RestaurantHomeScreen({super.key});

  @override
  State<RestaurantHomeScreen> createState() => _RestaurantHomeScreenState();
}

class _RestaurantHomeScreenState extends State<RestaurantHomeScreen> {
  int _navIndex = 0;
  bool _isOpen = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AC.surface(context),
      body: IndexedStack(
        index: _navIndex,
        children: [
          _PanelTab(isOpen: _isOpen,
              onToggle: (v) => setState(() => _isOpen = v)),
          RestaurantProductsScreen(standalone: false),
          RestaurantTrackingScreen(standalone: false),
          _RestaurantProfile(),
        ],
      ),
      bottomNavigationBar: AppBottomNav(items: [
        AppNavItem(
            icon: Icons.dashboard_rounded,
            label: 'Painel',
            selected: _navIndex == 0,
            onTap: () => setState(() => _navIndex = 0)),
        AppNavItem(
            icon: Icons.inventory_2_rounded,
            label: 'Produtos',
            selected: _navIndex == 1,
            onTap: () => setState(() => _navIndex = 1)),
        AppNavItem(
            icon: Icons.smart_toy_rounded,
            label: 'Robô',
            selected: _navIndex == 2,
            onTap: () => setState(() => _navIndex = 2),
            badge: '1'),
        AppNavItem(
            icon: Icons.store_rounded,
            label: 'Perfil',
            selected: _navIndex == 3,
            onTap: () => setState(() => _navIndex = 3)),
      ]),
    );
  }
}

// ─── PANEL TAB ─────────────────────────────────────────────────────
class _PanelTab extends StatelessWidget {
  final bool isOpen;
  final ValueChanged<bool> onToggle;

  const _PanelTab({required this.isOpen, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          automaticallyImplyLeading: false,
          floating: true,
          backgroundColor: AC.surface(context),
          surfaceTintColor: Colors.transparent,
          title: Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                  color: AppColors.accent,
                  borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.store_rounded,
                  color: Colors.white, size: 20),
            ),
            const SizedBox(width: 10),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Marmitas da Vó',
                  style: GoogleFonts.spaceGrotesk(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AC.primary(context))),
              Text('Painel do restaurante',
                  style: GoogleFonts.dmSans(
                      fontSize: 11, color: AC.muted(context))),
            ]),
          ]),
          actions: [
            Container(
              margin: const EdgeInsets.only(right: 16),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: isOpen
                    ? AppColors.teal.withValues(alpha: 0.12)
                    : Colors.red.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(children: [
                PulsingDot(
                    color: isOpen ? AppColors.teal : Colors.red, size: 6),
                const SizedBox(width: 5),
                Text(isOpen ? 'Aberto' : 'Fechado',
                    style: GoogleFonts.dmSans(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: isOpen ? AppColors.teal : Colors.red)),
              ]),
            ),
          ],
        ),

        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Stats
                Row(children: [
                  _StatCard(
                      value: '12',
                      label: 'Pedidos\nhoje',
                      color: AppColors.accent),
                  const SizedBox(width: 10),
                  _StatCard(
                      value: '3',
                      label: 'Em\nandamento',
                      color: AppColors.teal),
                  const SizedBox(width: 10),
                  _StatCard(
                      value: 'R\$216',
                      label: 'Faturamento\nhoje',
                      color: AppColors.purple),
                ]),
                const SizedBox(height: 16),

                // Open toggle
                AppCard(
                  child: Row(children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Aceitar pedidos',
                              style: GoogleFonts.dmSans(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                  color: AC.primary(context))),
                          const SizedBox(height: 2),
                          Text('Restaurante visível no app',
                              style: GoogleFonts.dmSans(
                                  fontSize: 12, color: AC.muted(context))),
                        ],
                      ),
                    ),
                    AppToggle(value: isOpen, onChanged: onToggle),
                  ]),
                ),

                const SizedBox(height: 20),
                SectionLabel('Pedidos recentes'),
              ],
            ),
          ),
        ),

        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (ctx, i) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _OrderCard(order: sampleOrders[i]),
              ),
              childCount: sampleOrders.length,
            ),
          ),
        ),

        SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final String value;
  final String label;
  final Color color;

  const _StatCard(
      {required this.value, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AC.card(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AC.border(context)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value,
              style: GoogleFonts.spaceGrotesk(
                  fontSize: 20, fontWeight: FontWeight.w700, color: color)),
          const SizedBox(height: 4),
          Text(label,
              style: GoogleFonts.dmSans(
                  fontSize: 11, color: AC.muted(context), height: 1.3)),
        ]),
      ),
    );
  }
}

class _OrderCard extends StatelessWidget {
  final Order order;

  const _OrderCard({required this.order});

  Color get _borderColor {
    switch (order.status) {
      case OrderStatus.preparing:
        return AppColors.accent;
      case OrderStatus.onTheWay:
        return AppColors.teal;
      case OrderStatus.delivered:
        return AppColors.teal;
      case OrderStatus.pending:
        return const Color(0xFFB97A00);
    }
  }

  StatusBadge get _badge {
    switch (order.status) {
      case OrderStatus.preparing:
        return const StatusBadge(
            label: 'Em preparo',
            bg: AppColors.statusPreparing,
            textColor: AppColors.statusPreparingText);
      case OrderStatus.onTheWay:
        return const StatusBadge(
            label: 'A caminho',
            bg: AppColors.statusDelivered,
            textColor: AppColors.statusDeliveredText);
      case OrderStatus.delivered:
        return const StatusBadge(
            label: 'Entregue',
            bg: AppColors.statusDelivered,
            textColor: AppColors.statusDeliveredText);
      case OrderStatus.pending:
        return const StatusBadge(
            label: 'Pendente',
            bg: AppColors.statusPending,
            textColor: AppColors.statusPendingText);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AC.card(context),
        borderRadius: BorderRadius.circular(14),
        border: Border(
          left: BorderSide(color: _borderColor, width: 3),
          right: BorderSide(color: AC.border(context)),
          top: BorderSide(color: AC.border(context)),
          bottom: BorderSide(color: AC.border(context)),
        ),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('#${order.id}',
                style: GoogleFonts.spaceGrotesk(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AC.primary(context))),
            _badge,
          ],
        ),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: Text(
                order.items
                    .map((i) => '${i.quantity}× ${i.name}')
                    .join(' · '),
                style: GoogleFonts.dmSans(
                    fontSize: 12, color: AC.muted(context)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
        ]),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(children: [
              Icon(Icons.location_on_outlined,
                  size: 13, color: AC.muted(context)),
              const SizedBox(width: 3),
              Text(order.address,
                  style: GoogleFonts.dmSans(
                      fontSize: 12, color: AC.muted(context))),
            ]),
            Text(
                'R\$${order.total.toStringAsFixed(2).replaceAll('.', ',')}',
                style: GoogleFonts.spaceGrotesk(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AC.primary(context))),
          ],
        ),
      ]),
    );
  }
}

// ─── RESTAURANT PROFILE TAB ────────────────────────────────────────
class _RestaurantProfile extends StatefulWidget {
  @override
  State<_RestaurantProfile> createState() => _RestaurantProfileState();
}

class _RestaurantProfileState extends State<_RestaurantProfile> {
  late bool _isDarkMode;

  @override
  void initState() {
    super.initState();
    _isDarkMode = themeModeNotifier.value == ThemeMode.dark;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AC.surface(context),
      appBar: AppBar(
          automaticallyImplyLeading: false,
          backgroundColor: AC.surface(context),
          surfaceTintColor: Colors.transparent,
          title: const Text('Perfil do restaurante')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(children: [
          Center(
            child: Column(children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                    color: const Color(0xFFFFF3EE),
                    borderRadius: BorderRadius.circular(20)),
                child: const Center(
                    child: Text('🍱', style: TextStyle(fontSize: 40))),
              ),
              const SizedBox(height: 12),
              Text('Marmitas da Vó',
                  style: GoogleFonts.spaceGrotesk(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: AC.primary(context))),
              Text('Parceiro desde 2024',
                  style: GoogleFonts.dmSans(
                      fontSize: 13, color: AC.muted(context))),
            ]),
          ),
          const SizedBox(height: 24),
          SectionLabel('Dados do restaurante'),
          ...[
            ['Nome do restaurante', 'Marmitas da Vó'],
            ['E-mail', 'contato@marmitasdavo.com.br'],
            ['Telefone', '(61) 3333-4444'],
            ['Endereço', 'Setor Comercial Sul, Bloco B'],
            ['Horário de funcionamento', '10h às 14h'],
          ].map((item) => Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FormFieldLabel(item[0]),
                    TextField(
                        controller: TextEditingController(text: item[1]),
                        style: TextStyle(color: AC.primary(context))),
                  ],
                ),
              )),
          const SizedBox(height: 24),
          SectionLabel('Configurações'),
          AppCard(
            child: _SettingRow(
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
          ),
          const SizedBox(height: 24),
          AppButton(
              label: 'Salvar alterações',
              onTap: () => showAppSnack(context, 'Dados salvos!')),
          const SizedBox(height: 12),
          AppButton(
            label: 'Sair da conta',
            onTap: () => Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => const LoginScreen()),
                (r) => false),
            outlined: true,
            color: Colors.red,
            icon: Icons.logout_rounded,
          ),
          const SizedBox(height: 32),
        ]),
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget trailing;

  const _SettingRow({
    required this.icon,
    required this.label,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      child: Row(
        children: [
          Icon(icon, color: AC.muted(context), size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label,
                style: GoogleFonts.dmSans(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AC.primary(context))),
          ),
          trailing,
        ],
      ),
    );
  }
}

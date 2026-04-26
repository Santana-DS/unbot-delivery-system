// lib/screens/client/order_screen.dart
// ignore_for_file: prefer_const_constructors

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../theme/app_theme.dart';
import '../../models/models.dart';
import '../../widgets/widgets.dart';
import '../../services/api_service.dart';
import '../../state/active_order_state.dart';
import 'tracking_screen.dart';

class OrderScreen extends StatefulWidget {
  final Restaurant restaurant;

  const OrderScreen({super.key, required this.restaurant});

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  late List<Product> _products;
  bool _isDispatching = false;
  final _addressCtrl =
      TextEditingController(text: 'Faculdade de Tecnologia, FT - UnB');

  @override
  void initState() {
    super.initState();
    // Deep-copy so quantity changes don't mutate the shared catalogue
    _products = widget.restaurant.products
        .map((p) => Product(
              id: p.id,
              name: p.name,
              description: p.description,
              emoji: p.emoji,
              price: p.price,
            ))
        .toList();
  }

  @override
  void dispose() {
    _addressCtrl.dispose();
    super.dispose();
  }

  double get _subtotal =>
      _products.fold(0, (sum, p) => sum + p.price * p.quantity);

  int get _totalItems => _products.fold(0, (sum, p) => sum + p.quantity);

  String get _itemsSummary {
    final ordered = _products.where((p) => p.quantity > 0).toList();
    if (ordered.isEmpty) return '';
    return ordered.map((p) => '${p.quantity}× ${p.name}').join(' · ');
  }

  String get _formattedTotal =>
      'R\$${_subtotal.toStringAsFixed(2).replaceAll('.', ',')}';

  Future<void> _confirmOrder() async {
    if (_subtotal <= 0 || _isDispatching) return;

    final orderId = 'order_${DateTime.now().millisecondsSinceEpoch}';
    setState(() => _isDispatching = true);

    final result = await ApiService().dispatchOrder(
      orderId,
      widget.restaurant.name,
    );

    if (!mounted) return;
    setState(() => _isDispatching = false);

    if (result == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Não foi possível confirmar o pedido. Verifique sua conexão.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final newOrder = ActiveOrder(
      result: result,
      restaurant: widget.restaurant,
      deliveryAddress: _addressCtrl.text.trim(),
      itemsSummary: _itemsSummary,
      formattedTotal: _formattedTotal,
      placedAt: DateTime.now().toUtc(),
    );
    addOrder(newOrder);

    if (result.isOtpOnly && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            '⚠️ Pedido confirmado, mas o robô está offline. '
            'Ele será despachado assim que a conexão for restaurada.',
          ),
          backgroundColor: AppColors.accent,
          duration: const Duration(seconds: 5),
        ),
      );
    }

    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => TrackingScreen(
          standalone: true,
          order: newOrder,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AC.surface(context), // FIXED: was AppColors.surface
      appBar: AppBar(
        backgroundColor: AC.surface(context), // FIXED
        surfaceTintColor: Colors.transparent,
        title: Text(widget.restaurant.name),
        actions: [
          if (_totalItems > 0)
            Container(
              margin: const EdgeInsets.only(right: 16),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.accent,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '$_totalItems ${_totalItems == 1 ? 'item' : 'itens'}',
                style: GoogleFonts.dmSans(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                ),
              ),
            ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          // ── Restaurant hero banner ────────────────────────────────────
          SliverToBoxAdapter(
            child: Container(
              height: 120,
              color: Color(
                int.parse('FF${widget.restaurant.bgColor}', radix: 16),
              ),
              child: Stack(
                children: [
                  Center(
                    child: Text(
                      widget.restaurant.emoji,
                      style: const TextStyle(fontSize: 52),
                    ),
                  ),
                  Positioned(
                    bottom: 12,
                    left: 16,
                    child: Row(
                      children: [
                        const Icon(Icons.star_rounded,
                            size: 14, color: AppColors.accent),
                        const SizedBox(width: 4),
                        Text(
                          '${widget.restaurant.rating} · ${widget.restaurant.etaMinutes} min de entrega',
                          style: GoogleFonts.dmSans(
                            fontSize: 12,
                            // NOTE: restaurant banners have a fixed pastel bg,
                            // so AppColors.primary (dark ink) is intentional here
                            // regardless of theme — it contrasts the light bg.
                            color: AppColors.primary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          SliverPadding(
            padding: const EdgeInsets.all(20),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                // ── Menu items ────────────────────────────────────────
                const SectionLabel('Cardápio'),
                ..._products.asMap().entries.map(
                      (e) => _ProductItem(
                        product: e.value,
                        onQtyChanged: (v) {
                          setState(() => _products[e.key].quantity = v);
                        },
                      ),
                    ),
                const SizedBox(height: 20),

                // ── Delivery address ──────────────────────────────────
                const SectionLabel('Endereço de entrega'),
                TextField(
                  controller: _addressCtrl,
                  style: TextStyle(color: AC.primary(context)), // FIXED
                  decoration: InputDecoration(
                    hintText: 'Rua, número, complemento',
                    prefixIcon: Icon(Icons.location_on_outlined,
                        color: AC.muted(context), size: 20), // FIXED
                  ),
                ),
                const SizedBox(height: 20),

                // ── Order summary ─────────────────────────────────────
                // OBJECTIVE 3: entire summary section now uses AC.* accessors
                if (_subtotal > 0) ...[
                  const SectionLabel('Resumo do pedido'),
                  AppCard(
                    child: Column(
                      children: [
                        ..._products
                            .where((p) => p.quantity > 0)
                            .map(
                              (p) => Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 4),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      '${p.quantity}× ${p.name}',
                                      style: GoogleFonts.dmSans(
                                          fontSize: 13,
                                          color: AC.primary(context)), // FIXED
                                    ),
                                    Text(
                                      'R\$${(p.price * p.quantity).toStringAsFixed(2).replaceAll('.', ',')}',
                                      style: GoogleFonts.dmSans(
                                          fontSize: 13,
                                          color: AC.primary(context)), // FIXED
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Divider(
                              height: 1, color: AC.border(context)), // FIXED
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Taxa de entrega',
                                style: GoogleFonts.dmSans(
                                    fontSize: 13,
                                    color: AC.muted(context))), // FIXED
                            Text('Grátis',
                                style: GoogleFonts.dmSans(
                                  fontSize: 13,
                                  color: AppColors.teal,
                                  fontWeight: FontWeight.w500,
                                )),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Total',
                                style: GoogleFonts.spaceGrotesk(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: AC.primary(context), // FIXED
                                )),
                            Text(
                              _formattedTotal,
                              style: GoogleFonts.spaceGrotesk(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: AppColors.accent,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],

                AppButton(
                  label: _subtotal > 0
                      ? 'Confirmar pedido · $_formattedTotal'
                      : 'Selecione itens para pedir',
                  onTap: _confirmOrder,
                  loading: _isDispatching,
                ),
                const SizedBox(height: 32),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Product item ─────────────────────────────────────────────────────────────
// OBJECTIVE 3: replaced all AppColors.card / AppColors.surface / AppColors.primary
//              / AppColors.muted references with AC.*(context) equivalents.
class _ProductItem extends StatelessWidget {
  final Product product;
  final ValueChanged<int> onQtyChanged;

  const _ProductItem({required this.product, required this.onQtyChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          // Selected state gets a warm tint that works in both modes;
          // default state falls back to the theme-aware card color.
          color: product.quantity > 0
              ? AppColors.accent.withValues(alpha: 0.06) // FIXED: was Color(0xFFFFF8F5)
              : AC.card(context), // FIXED: was AppColors.card
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: product.quantity > 0
                ? AppColors.accent
                : AC.border(context), // FIXED: was AppColors.primary.withValues(alpha:0.08)
            width: product.quantity > 0 ? 1.5 : 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: AC.surface(context), // FIXED: was AppColors.surface
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(product.emoji,
                      style: const TextStyle(fontSize: 28)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(product.name,
                        style: GoogleFonts.dmSans(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: AC.primary(context), // FIXED
                        )),
                    const SizedBox(height: 2),
                    Text(product.description,
                        style: GoogleFonts.dmSans(
                            fontSize: 11, color: AC.muted(context)), // FIXED
                        maxLines: 2),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(
                          'R\$${product.price.toStringAsFixed(2).replaceAll('.', ',')}',
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.accent,
                          ),
                        ),
                        const Spacer(),
                        _QtyControl(
                            qty: product.quantity, onChanged: onQtyChanged),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Quantity control ─────────────────────────────────────────────────────────
class _QtyControl extends StatelessWidget {
  final int qty;
  final ValueChanged<int> onChanged;

  const _QtyControl({required this.qty, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _QtyBtn(
          icon: Icons.remove_rounded,
          onTap: qty > 0 ? () => onChanged(qty - 1) : null,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text('$qty',
              style: GoogleFonts.spaceGrotesk(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AC.primary(context))), // FIXED
        ),
        _QtyBtn(
            icon: Icons.add_rounded,
            onTap: () => onChanged(qty + 1),
            filled: true),
      ],
    );
  }
}

class _QtyBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool filled;

  const _QtyBtn({required this.icon, this.onTap, this.filled = false});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: filled
              ? AppColors.accent
              : AC.primary(context).withValues(alpha: 0.06), // FIXED
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon,
            size: 16, color: filled ? Colors.white : AppColors.accent),
      ),
    );
  }
}
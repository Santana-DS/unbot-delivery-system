// ignore_for_file: prefer_const_constructors

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../theme/app_theme.dart';
import '../../models/models.dart';
import '../../widgets/widgets.dart';

class RestaurantProductsScreen extends StatefulWidget {
  final bool standalone;

  const RestaurantProductsScreen({super.key, this.standalone = true});

  @override
  State<RestaurantProductsScreen> createState() =>
      _RestaurantProductsScreenState();
}

class _RestaurantProductsScreenState
    extends State<RestaurantProductsScreen> {
  late List<_ProductEntry> _products;

  @override
  void initState() {
    super.initState();
    _products = sampleRestaurants[0].products.asMap().entries.map((e) {
      return _ProductEntry(
        product: e.value,
        available: e.key < 2,
        sales: [87, 54, 31][e.key.clamp(0, 2)],
      );
    }).toList();
  }

  void _toggleAvailability(int index) {
    setState(() => _products[index].available = !_products[index].available);
  }

  @override
  Widget build(BuildContext context) {
    final content = CustomScrollView(
      slivers: [
        if (widget.standalone)
          SliverAppBar(
            floating: true,
            title: const Text('Gerenciar Produtos'),
            actions: [
              IconButton(
                icon: const Icon(Icons.add_rounded, color: AppColors.accent),
                onPressed: () => _showAddProductSheet(context),
              ),
            ],
          )
        else
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Produtos',
                      style: Theme.of(context).textTheme.displaySmall),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _showAddProductSheet(context),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.add_rounded,
                              color: Colors.white, size: 16),
                          const SizedBox(width: 4),
                          Text('Adicionar',
                              style: GoogleFonts.dmSans(
                                  fontSize: 13,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w500)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

        SliverPadding(
          padding: const EdgeInsets.all(20),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (ctx, i) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _ProductTile(
                  entry: _products[i],
                  onToggle: () => _toggleAvailability(i),
                  onEdit: () => _showEditSheet(context, _products[i]),
                ),
              ),
              childCount: _products.length,
            ),
          ),
        ),
      ],
    );

    return widget.standalone
        ? Scaffold(backgroundColor: AppColors.surface, body: content)
        : content;
  }

  void _showAddProductSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _ProductFormSheet(title: 'Novo produto'),
    );
  }

  void _showEditSheet(BuildContext context, _ProductEntry entry) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _ProductFormSheet(
        title: 'Editar produto',
        entry: entry,
      ),
    );
  }
}

class _ProductEntry {
  final Product product;
  bool available;
  final int sales;

  _ProductEntry({
    required this.product,
    required this.available,
    required this.sales,
  });
}

class _ProductTile extends StatelessWidget {
  final _ProductEntry entry;
  final VoidCallback onToggle;
  final VoidCallback onEdit;

  const _ProductTile({
    required this.entry,
    required this.onToggle,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.08)),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Text(entry.product.emoji,
                  style: const TextStyle(fontSize: 28)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.product.name,
                  style: GoogleFonts.dmSans(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  entry.product.description,
                  style: GoogleFonts.dmSans(
                      fontSize: 11, color: AppColors.muted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    StatusBadge(
                      label: entry.available ? 'Disponível' : 'Esgotado',
                      bg: entry.available
                          ? AppColors.statusDelivered
                          : AppColors.statusPending,
                      textColor: entry.available
                          ? AppColors.statusDeliveredText
                          : AppColors.statusPendingText,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${entry.sales} vendidos',
                      style: GoogleFonts.dmSans(
                          fontSize: 11, color: AppColors.muted),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'R\$${entry.product.price.toStringAsFixed(2).replaceAll('.', ',')}',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.accent,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  GestureDetector(
                    onTap: onEdit,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.edit_outlined,
                          size: 16, color: AppColors.muted),
                    ),
                  ),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: onToggle,
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: entry.available
                            ? AppColors.teal.withValues(alpha: 0.1)
                            : Colors.red.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        entry.available
                            ? Icons.toggle_on_rounded
                            : Icons.toggle_off_rounded,
                        size: 18,
                        color: entry.available ? AppColors.teal : Colors.red,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProductFormSheet extends StatelessWidget {
  final String title;
  final _ProductEntry? entry;

  const _ProductFormSheet({required this.title, this.entry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(title,
                    style: Theme.of(context).textTheme.displaySmall),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const FormFieldLabel('Nome do produto'),
            TextField(
              controller: TextEditingController(
                  text: entry?.product.name ?? ''),
              decoration:
                  const InputDecoration(hintText: 'Ex: Marmita Executiva'),
            ),
            const SizedBox(height: 14),
            const FormFieldLabel('Descrição'),
            TextField(
              controller: TextEditingController(
                  text: entry?.product.description ?? ''),
              maxLines: 2,
              decoration: const InputDecoration(
                  hintText: 'Descreva os ingredientes...'),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const FormFieldLabel('Preço (R\$)'),
                      TextField(
                        controller: TextEditingController(
                          text: entry != null
                              ? entry!.product.price
                                  .toStringAsFixed(2)
                              : '',
                        ),
                        keyboardType: TextInputType.number,
                        decoration:
                            const InputDecoration(hintText: '0,00'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const FormFieldLabel('Emoji'),
                      TextField(
                        controller: TextEditingController(
                            text: entry?.product.emoji ?? '🍱'),
                        decoration:
                            const InputDecoration(hintText: '🍱'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            AppButton(
              label: entry != null ? 'Salvar alterações' : 'Adicionar produto',
              onTap: () => Navigator.pop(context),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}


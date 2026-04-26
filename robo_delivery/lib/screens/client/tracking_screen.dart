// lib/screens/client/tracking_screen.dart
// ignore_for_file: prefer_const_constructors

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../theme/app_theme.dart';
import '../../state/active_order_state.dart';
import '../../widgets/widgets.dart';
import 'code_screen.dart';

// OBJECTIVE 4: Full AC.*(context) audit.
// Every AppColors.surface / AppColors.card / AppColors.primary / AppColors.muted
// that was hardcoded in static contexts has been replaced with the dynamic
// AC. accessors. The map overlay ETA bar (previously Colors.white) is now
// AC.card(context). InstructionStep and StepTile backgrounds updated accordingly.
class TrackingScreen extends StatefulWidget {
  final bool standalone;
  final ActiveOrder? order;

  const TrackingScreen({
    super.key,
    this.standalone = true,
    this.order,
  });

  @override
  State<TrackingScreen> createState() => _TrackingScreenState();
}

class _TrackingScreenState extends State<TrackingScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseCtrl;
  double _robotProgress = 0.35;
  int _etaMinutes = 8;
  Timer? _timer;

  late final List<_StatusStep> _steps;

  @override
  void initState() {
    super.initState();

    _steps = [
      _StatusStep(
          icon: Icons.check_circle_rounded,
          label: 'Pedido confirmado',
          time: _formatTime(widget.order?.placedAt),
          done: true),
      _StatusStep(
          icon: Icons.restaurant_rounded,
          label: 'Em preparo',
          time: _formatTime(
              widget.order?.placedAt.add(const Duration(minutes: 2))),
          done: true),
      _StatusStep(
          icon: Icons.smart_toy_rounded,
          label: 'Robô a caminho',
          time: 'Em andamento',
          done: false,
          active: true),
      _StatusStep(
          icon: Icons.lock_open_rounded,
          label: 'Retirada com código',
          time: 'Aguardando',
          done: false),
    ];

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && _robotProgress < 0.85) {
        setState(() {
          _robotProgress += 0.05;
          _etaMinutes = (_etaMinutes - 1).clamp(1, 99);
        });
      }
    });
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _timer?.cancel();
    super.dispose();
  }

  static String _formatTime(DateTime? dt) {
    if (dt == null) return '—';
    final local = dt.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.order;

    final content = CustomScrollView(
      slivers: [
        if (widget.standalone)
          SliverAppBar(
            title: Text(
              order != null
                  ? '${order.shortId} · ${order.restaurant.name}'
                  : 'Acompanhar pedido',
            ),
            floating: true,
            backgroundColor: AC.surface(context), // FIXED
            surfaceTintColor: Colors.transparent,
          ),

        if (!widget.standalone)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Text(
                'Acompanhar pedido',
                style: Theme.of(context).textTheme.displaySmall,
              ),
            ),
          ),

        // ── Map ──────────────────────────────────────────────────────────
        SliverToBoxAdapter(
          child: _TrackingMap(
            robotProgress: _robotProgress,
            etaMinutes: _etaMinutes,
            pulseCtrl: _pulseCtrl,
          ),
        ),

        SliverPadding(
          padding: const EdgeInsets.all(20),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              // ── Order summary card ─────────────────────────────────────
              if (order != null)
                AppCard(
                  borderColor: AppColors.accent,
                  borderWidth: 1.5,
                  child: Row(
                    children: [
                      Hero(
                        tag: 'order-emoji-${order.orderId}',
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: Color(int.parse(
                                'FF${order.restaurant.bgColor}',
                                radix: 16)),
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
                                color: AC.primary(context), // FIXED
                              ),
                            ),
                            Text(
                              order.itemsSummary,
                              style: GoogleFonts.dmSans(
                                  fontSize: 12, color: AC.muted(context)), // FIXED
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      Text(
                        order.formattedTotal,
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.accent,
                        ),
                      ),
                    ],
                  ),
                ),

              // ── MQTT offline warning banner ────────────────────────────
              if (order != null && order.isOtpOnly) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: AppColors.accent.withValues(alpha: 0.25)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.wifi_off_rounded,
                          size: 16, color: AppColors.accent),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Robô ainda não recebeu rota. Será despachado quando a conexão for restaurada.',
                          style: GoogleFonts.dmSans(
                              fontSize: 12, color: AppColors.accent),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 20),
              const SectionLabel('Status da entrega'),

              // ── Timeline steps ─────────────────────────────────────────
              ..._steps.map((s) => _StepTile(step: s)),

              const SizedBox(height: 20),

              // ── "Ver código" button ────────────────────────────────────
              AppButton(
                label: 'Ver código de retirada',
                onTap: () {
                  if (order == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Nenhum código ativo no momento.')),
                    );
                    return;
                  }
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => CodeScreen(
                        otp: order.otpCode,
                        orderId: order.orderId,
                      ),
                    ),
                  );
                },
                icon: Icons.lock_open_rounded,
              ),

              const SizedBox(height: 12),

              // ── "Cancelar pedido" button ───────────────────────────────
              if (order != null)
                AppButton(
                  label: 'Cancelar pedido',
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        backgroundColor: AC.card(context), // FIXED
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                        title: Text('Cancelar pedido?',
                            style: GoogleFonts.spaceGrotesk(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: AC.primary(context))), // FIXED
                        content: Text(
                          'O pedido ${order.shortId} será removido da sua lista.',
                          style: GoogleFonts.dmSans(
                              fontSize: 13, color: AC.muted(context)), // FIXED
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: Text('Voltar',
                                style: GoogleFonts.dmSans(
                                    color: AC.muted(context))), // FIXED
                          ),
                          TextButton(
                            onPressed: () {
                              Navigator.pop(ctx);
                              removeOrder(order.orderId);
                              if (widget.standalone && mounted) {
                                Navigator.pop(context);
                              }
                            },
                            child: Text('Cancelar pedido',
                                style: GoogleFonts.dmSans(
                                    color: Colors.red,
                                    fontWeight: FontWeight.w500)),
                          ),
                        ],
                      ),
                    );
                  },
                  outlined: true,
                  color: Colors.red,
                  icon: Icons.cancel_outlined,
                )
              else
                AppButton(
                  label: 'Contatar suporte',
                  onTap: () {},
                  outlined: true,
                  icon: Icons.headset_mic_rounded,
                ),

              const SizedBox(height: 24),
            ]),
          ),
        ),
      ],
    );

    return widget.standalone
        ? Scaffold(
            backgroundColor: AC.surface(context), // FIXED: was AppColors.surface
            body: content)
        : content;
  }
}

// ─── MAP WIDGET ──────────────────────────────────────────────────────────────
// OBJECTIVE 4: ETA bar background was Colors.white — now AC.card(context)
class _TrackingMap extends StatelessWidget {
  final double robotProgress;
  final int etaMinutes;
  final AnimationController pulseCtrl;

  const _TrackingMap({
    required this.robotProgress,
    required this.etaMinutes,
    required this.pulseCtrl,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      height: 220,
      color: AC.mapBg(context), // FIXED: was AppColors.mapBg
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(painter: MapBackgroundPainter(isDark: isDark)), // FIXED: passes isDark
          ),
          Positioned.fill(
            child: CustomPaint(
              painter: _TrackingRoutePainter(progress: robotProgress),
            ),
          ),
          // Restaurant pin
          Positioned(
            left: 24,
            top: 60,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.purple,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Center(
                child: Text('🍱', style: TextStyle(fontSize: 18)),
              ),
            ),
          ),
          // Destination pin
          Positioned(
            right: 30,
            top: 130,
            child: Column(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: const BoxDecoration(
                    color: AppColors.teal,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.home_rounded,
                      color: Colors.white, size: 16),
                ),
                Container(width: 2, height: 8, color: AppColors.teal),
              ],
            ),
          ),
          // Robot
          AnimatedBuilder(
            animation: pulseCtrl,
            builder: (ctx, child) {
              return Positioned(
                left: MediaQuery.of(context).size.width * robotProgress - 60,
                top: 60,
                child: Transform.scale(
                  scale: 1.0 + pulseCtrl.value * 0.1,
                  child: child,
                ),
              );
            },
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.accent,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: AppColors.accent.withValues(alpha: 0.4),
                    blurRadius: 14,
                    spreadRadius: 5,
                  ),
                ],
              ),
              child: const RobotIcon(size: 28, color: Colors.white),
            ),
          ),
          // ETA bar — FIXED: was Colors.white.withValues(alpha:0.95)
          Positioned(
            bottom: 10,
            left: 12,
            right: 12,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AC.card(context).withValues(alpha: 0.95), // FIXED
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: AppColors.teal,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Robô em rota',
                          style: GoogleFonts.dmSans(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: AC.primary(context), // FIXED
                          ),
                        ),
                        Text(
                          '${((1 - robotProgress) * 500).toInt()} metros do destino',
                          style: GoogleFonts.dmSans(
                              fontSize: 11, color: AC.muted(context)), // FIXED
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '$etaMinutes min',
                    style: GoogleFonts.spaceGrotesk(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: AppColors.accent,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Route painter ───────────────────────────────────────────────────────────
class _TrackingRoutePainter extends CustomPainter {
  final double progress;

  _TrackingRoutePainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.purple.withValues(alpha: 0.5)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path = Path()
      ..moveTo(48, 78)
      ..lineTo(size.width * progress - 38, 78)
      ..lineTo(size.width * progress - 38, 140)
      ..lineTo(size.width - 44, 140);

    const dashWidth = 8.0;
    const dashSpace = 5.0;
    final pathMetric = path.computeMetrics().first;
    double distance = 0;
    while (distance < pathMetric.length) {
      canvas.drawPath(
        pathMetric.extractPath(distance, distance + dashWidth),
        paint,
      );
      distance += dashWidth + dashSpace;
    }
  }

  @override
  bool shouldRepaint(covariant _TrackingRoutePainter old) =>
      old.progress != progress;
}

// ─── Status step model ────────────────────────────────────────────────────────
class _StatusStep {
  final IconData icon;
  final String label;
  final String time;
  final bool done;
  final bool active;

  _StatusStep({
    required this.icon,
    required this.label,
    required this.time,
    required this.done,
    this.active = false,
  });
}

// ─── Step tile ────────────────────────────────────────────────────────────────
// OBJECTIVE 4: was AppColors.card / AppColors.primary.withValues / AppColors.muted
class _StepTile extends StatelessWidget {
  final _StatusStep step;

  const _StepTile({required this.step});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AC.card(context), // FIXED
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: step.active
                ? AppColors.accent.withValues(alpha: 0.3)
                : AC.border(context), // FIXED
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: step.done
                    ? AppColors.teal.withValues(alpha: 0.15)
                    : step.active
                        ? AppColors.accent.withValues(alpha: 0.12)
                        : AC.primary(context).withValues(alpha: 0.06), // FIXED
                shape: BoxShape.circle,
              ),
              child: Icon(
                step.icon,
                size: 17,
                color: step.done
                    ? AppColors.teal
                    : step.active
                        ? AppColors.accent
                        : AC.muted(context), // FIXED
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                step.label,
                style: GoogleFonts.dmSans(
                  fontSize: 13,
                  fontWeight:
                      step.active ? FontWeight.w500 : FontWeight.w400,
                  color: step.done || step.active
                      ? AC.primary(context) // FIXED
                      : AC.muted(context), // FIXED
                ),
              ),
            ),
            Text(
              step.time,
              style: GoogleFonts.dmSans(
                  fontSize: 11, color: AC.muted(context)), // FIXED
            ),
          ],
        ),
      ),
    );
  }
}
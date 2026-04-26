// ignore_for_file: prefer_const_literals_to_create_immutables, prefer_const_constructors
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../theme/app_theme.dart';
import '../../widgets/widgets.dart';

class RestaurantTrackingScreen extends StatefulWidget {
  final bool standalone;
  const RestaurantTrackingScreen({super.key, this.standalone = true});

  @override
  State<RestaurantTrackingScreen> createState() =>
      _RestaurantTrackingScreenState();
}

class _RestaurantTrackingScreenState extends State<RestaurantTrackingScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseCtrl;
  double _robotProgress = 0.38;
  int _distanceMeters = 780;
  bool _notificationsOn = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _pulseCtrl =
        AnimationController(vsync: this, duration: const Duration(seconds: 2))
          ..repeat(reverse: true);

    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (mounted && _robotProgress < 0.88) {
        setState(() {
          _robotProgress += 0.04;
          _distanceMeters = (_distanceMeters - 60).clamp(0, 9999);
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final content = CustomScrollView(
      slivers: [
        if (widget.standalone)
          SliverAppBar(
              floating: true,
              backgroundColor: AC.surface(context),
              surfaceTintColor: Colors.transparent,
              title: const Text('Localização do robô'))
        else
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Localização do robô',
                      style: Theme.of(context).textTheme.displaySmall),
                  const SizedBox(height: 4),
                  Row(children: [
                    PulsingDot(color: AppColors.teal, size: 7),
                    const SizedBox(width: 6),
                    Text('Atualização em tempo real',
                        style: GoogleFonts.dmSans(
                            fontSize: 12, color: AC.muted(context))),
                  ]),
                ],
              ),
            ),
          ),

        // Map card
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Container(
                height: 260,
                color: AC.mapBg(context),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                          painter: MapBackgroundPainter(isDark: isDark)),
                    ),
                    Positioned.fill(
                      child: CustomPaint(
                          painter: _RestaurantRoutePainter(
                              progress: _robotProgress, isDark: isDark)),
                    ),

                    // Restaurant icon
                    Positioned(
                      left: 20,
                      top: 60,
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                            color: AppColors.purple,
                            borderRadius: BorderRadius.circular(12)),
                        child: const Center(
                            child: Text('🍱',
                                style: TextStyle(fontSize: 20))),
                      ),
                    ),

                    // Client destination
                    Positioned(
                      right: 20,
                      bottom: 60,
                      child: Column(children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: const BoxDecoration(
                              color: AppColors.teal, shape: BoxShape.circle),
                          child: const Icon(Icons.person_rounded,
                              color: Colors.white, size: 18),
                        ),
                        Container(width: 2, height: 8, color: AppColors.teal),
                      ]),
                    ),

                    // Robot
                    AnimatedBuilder(
                      animation: _pulseCtrl,
                      builder: (ctx, child) {
                        return Positioned(
                          left: MediaQuery.of(context).size.width *
                                  _robotProgress -
                              60,
                          top: 50,
                          child: Transform.scale(
                              scale: 1.0 + _pulseCtrl.value * 0.08,
                              child: child),
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
                                color:
                                    AppColors.accent.withValues(alpha: 0.4),
                                blurRadius: 14,
                                spreadRadius: 5),
                          ],
                        ),
                        child: const RobotIcon(size: 28, color: Colors.white),
                      ),
                    ),

                    // Distance overlay
                    Positioned(
                      bottom: 10,
                      left: 10,
                      right: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: AC.card(context).withValues(alpha: 0.95),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisAlignment:
                              MainAxisAlignment.spaceBetween,
                          children: [
                            Text('Distância ao cliente',
                                style: GoogleFonts.dmSans(
                                    fontSize: 12, color: AC.muted(context))),
                            Text('$_distanceMeters m',
                                style: GoogleFonts.spaceGrotesk(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.accent)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),

        SliverPadding(
          padding: const EdgeInsets.all(20),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              SectionLabel('Entrega em andamento'),

              Container(
                decoration: BoxDecoration(
                  color: AC.card(context),
                  borderRadius: BorderRadius.circular(14),
                  border: Border(
                    left: const BorderSide(color: AppColors.accent, width: 3),
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
                      Text('#4821 · Em entrega',
                          style: GoogleFonts.spaceGrotesk(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AC.primary(context))),
                      const StatusBadge(
                          label: 'Robô ativo',
                          bg: AppColors.statusPreparing,
                          textColor: AppColors.statusPreparingText),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(children: [
                    Expanded(
                        child: Text(
                            '1× Marmita Executiva · Rua das Acácias, 42',
                            style: GoogleFonts.dmSans(
                                fontSize: 12, color: AC.muted(context)))),
                  ]),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(children: [
                        Icon(Icons.timer_outlined,
                            size: 13, color: AC.muted(context)),
                        const SizedBox(width: 4),
                        Text(
                            'ETA: ${(_distanceMeters / 100).ceil()} min',
                            style: GoogleFonts.dmSans(
                                fontSize: 12, color: AC.muted(context))),
                      ]),
                      Text('R\$18,00',
                          style: GoogleFonts.spaceGrotesk(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AC.primary(context))),
                    ],
                  ),
                ]),
              ),

              const SizedBox(height: 16),
              SectionLabel('Telemetria'),

              Row(children: [
                _TelemetryCard(
                    icon: Icons.speed_rounded,
                    label: 'Velocidade',
                    value: '4.2 km/h',
                    color: AppColors.purple),
                const SizedBox(width: 10),
                _TelemetryCard(
                    icon: Icons.battery_charging_full_rounded,
                    label: 'Bateria',
                    value: '78%',
                    color: AppColors.teal),
                const SizedBox(width: 10),
                _TelemetryCard(
                    icon: Icons.signal_wifi_4_bar_rounded,
                    label: 'Sinal',
                    value: 'Forte',
                    color: AppColors.accent),
              ]),

              const SizedBox(height: 16),

              AppCard(
                child: Row(children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Notificações de entrega',
                            style: GoogleFonts.dmSans(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: AC.primary(context))),
                        const SizedBox(height: 2),
                        Text('Alertas quando robô chegar ao destino',
                            style: GoogleFonts.dmSans(
                                fontSize: 12, color: AC.muted(context))),
                      ],
                    ),
                  ),
                  AppToggle(
                    value: _notificationsOn,
                    onChanged: (v) => setState(() => _notificationsOn = v),
                  ),
                ]),
              ),

              const SizedBox(height: 24),
            ]),
          ),
        ),
      ],
    );

    return widget.standalone
        ? Scaffold(backgroundColor: AC.surface(context), body: content)
        : content;
  }
}

class _TelemetryCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _TelemetryCard(
      {required this.icon,
      required this.label,
      required this.value,
      required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AC.card(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AC.border(context)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(height: 6),
          Text(value,
              style: GoogleFonts.spaceGrotesk(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: AC.primary(context))),
          Text(label,
              style: GoogleFonts.dmSans(
                  fontSize: 10, color: AC.muted(context))),
        ]),
      ),
    );
  }
}

class _RestaurantRoutePainter extends CustomPainter {
  final double progress;
  final bool isDark;

  const _RestaurantRoutePainter(
      {required this.progress, required this.isDark});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.purple.withValues(alpha: 0.5)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path = Path()
      ..moveTo(52, 80)
      ..lineTo(size.width * progress - 30, 80)
      ..lineTo(size.width * progress - 30, size.height - 68)
      ..lineTo(size.width - 36, size.height - 68);

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
  bool shouldRepaint(_RestaurantRoutePainter old) =>
      old.progress != progress || old.isDark != isDark;
}

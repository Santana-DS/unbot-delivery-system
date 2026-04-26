// lib/screens/splash_screen.dart
//
// UnBot Delivery — Splash Screen
// ─────────────────────────────────────────────────────────────────────────────
// CHANGE: _navigate() now routes to LoginScreen instead of ClientHomeScreen.
//         SplashScreen is a pure brand moment + gatekeeper; auth state lives
//         in LoginScreen. When a real token is persisted, add the check here:
//
//           final token = await SecureStorage.read('auth_token');
//           if (token != null && !isExpired(token)) {
//             go → ClientHomeScreen  (auto-login)
//           } else {
//             go → LoginScreen
//           }
//
// All animation code is unchanged from the original.
// ignore_for_file: prefer_const_constructors

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'login_screen.dart'; // ← CHANGED: was client/client_home_screen.dart

// ── UnB Brand Colors ──────────────────────────────────────────────────────────
class _UnB {
  static const navy        = Color(0xFF003366);
  static const green       = Color(0xFF006633);
  static const glow        = Color(0xFF00C97A);
  static const onDark      = Color(0xFFF0F4F0);
  static const onDarkMuted = Color(0xFF8DB8A0);
}

// ─────────────────────────────────────────────────────────────────────────────
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {

  // ONE controller drives three staggered rings + one breathe.
  // 2400 ms → ring 3 finishes exactly as ring 1 restarts: seamless sonar loop.
  late final AnimationController _ctrl;
  late final Animation<double> _breathe;
  late final Animation<double> _r1s, _r1o;
  late final Animation<double> _r2s, _r2o;
  late final Animation<double> _r3s, _r3o;
  late final Animation<double> _tagline;

  bool   _navigated = false;
  Timer? _navTimer;

  @override
  void initState() {
    super.initState();

    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();

    Animation<double> curve(double begin, double end, double i0, double i1,
        [Curve c = Curves.easeOut]) =>
        Tween<double>(begin: begin, end: end).animate(
          CurvedAnimation(
              parent: _ctrl, curve: Interval(i0, i1, curve: c)));

    _breathe = curve(1.0, 1.06, 0.0, 1.0, Curves.easeInOut);

    _r1s = curve(0.6, 1.7, 0.00, 1.0, Curves.easeOut);
    _r1o = curve(0.55, 0.0, 0.00, 1.0, Curves.easeIn);
    _r2s = curve(0.6, 1.7, 0.20, 1.0, Curves.easeOut);
    _r2o = curve(0.40, 0.0, 0.20, 1.0, Curves.easeIn);
    _r3s = curve(0.6, 1.7, 0.40, 1.0, Curves.easeOut);
    _r3o = curve(0.25, 0.0, 0.40, 1.0, Curves.easeIn);

    _tagline = curve(0.0, 1.0, 0.0, 0.25, Curves.easeOut);

    // CHANGED: now routes to LoginScreen after 2.5 s.
    _navTimer = Timer(const Duration(milliseconds: 2500), _navigate);
  }

  // ── CHANGED: destination is LoginScreen ───────────────────────────────────
  void _navigate() {
    if (!mounted || _navigated) return;
    _navigated = true;

    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const LoginScreen(),
        // Smooth cross-fade instead of the default slide so it doesn't clash
        // with the header animation inside LoginScreen.
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  @override
  void dispose() {
    _navTimer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;

    return Scaffold(
      backgroundColor: _UnB.navy,
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [_UnB.navy, Color(0xFF00512B), _UnB.green],
            stops: [0.0, 0.55, 1.0],
          ),
        ),
        child: SafeArea(
          child: Stack(
            children: [
              // Subtle grid — campus map / circuit board texture
              Positioned.fill(child: CustomPaint(painter: _GridPainter())),

              // ── Centered hero content ──────────────────────────────────────
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Glow rings + robot
                    SizedBox(
                      width: w * 0.55,
                      height: w * 0.55,
                      child: AnimatedBuilder(
                        animation: _ctrl,
                        child: _RobotContainer(size: w * 0.26),
                        builder: (_, child) => Stack(
                          alignment: Alignment.center,
                          children: [
                            _Ring(_r3s.value, _r3o.value, w * 0.55),
                            _Ring(_r2s.value, _r2o.value, w * 0.55),
                            _Ring(_r1s.value, _r1o.value, w * 0.55),
                            Transform.scale(scale: _breathe.value, child: child),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 36),

                    // App name — "UnBot Delivery"
                    Text(
                      'UnBot Delivery',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 38,
                        fontWeight: FontWeight.w700,
                        color: _UnB.onDark,
                        letterSpacing: 0.5,
                        shadows: [
                          Shadow(
                            color: _UnB.glow.withValues(alpha: 0.45),
                            blurRadius: 24,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 8),

                    // Tagline fades in on first pulse quarter
                    AnimatedBuilder(
                      animation: _tagline,
                      builder: (_, child) =>
                          Opacity(opacity: _tagline.value, child: child),
                      child: Text(
                        'Entrega autônoma na UnB',
                        style: GoogleFonts.dmSans(
                          fontSize: 14,
                          color: _UnB.onDarkMuted,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // ── Bottom: loading + faculty credit ───────────────────────────
              Positioned(
                bottom: 28, left: 0, right: 0,
                child: Column(
                  children: [
                    SizedBox(
                      width: 22, height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: _UnB.glow.withValues(alpha: 0.7),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'FT · Engenharia Mecatrônica · UnB',
                      style: GoogleFonts.dmSans(
                        fontSize: 11,
                        color: _UnB.onDarkMuted.withValues(alpha: 0.5),
                        letterSpacing: 0.5,
                      ),
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

// ─── Glow Ring ───────────────────────────────────────────────────────────────
class _Ring extends StatelessWidget {
  final double scale, opacity, base;
  const _Ring(this.scale, this.opacity, this.base);

  @override
  Widget build(BuildContext ctx) => Transform.scale(
    scale: scale,
    child: Opacity(
      opacity: opacity.clamp(0.0, 1.0),
      child: Container(
        width: base, height: base,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: _UnB.glow, width: 1.8),
          boxShadow: [
            BoxShadow(
              color: _UnB.glow.withValues(alpha: opacity * 0.45),
              blurRadius: 16, spreadRadius: 2,
            ),
          ],
        ),
      ),
    ),
  );
}

// ─── Robot Container ─────────────────────────────────────────────────────────
class _RobotContainer extends StatelessWidget {
  final double size;
  const _RobotContainer({required this.size});

  @override
  Widget build(BuildContext ctx) => Container(
    width: size, height: size,
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.08),
      shape: BoxShape.circle,
      border: Border.all(color: _UnB.glow.withValues(alpha: 0.35), width: 1.5),
      boxShadow: [
        BoxShadow(
          color: _UnB.glow.withValues(alpha: 0.25),
          blurRadius: 32, spreadRadius: 8,
        ),
      ],
    ),
    child: Icon(Icons.smart_toy_rounded, size: size * 0.52, color: _UnB.onDark),
  );
}

// ─── Grid Painter ────────────────────────────────────────────────────────────
// shouldRepaint = false → zero repaints during the animation loop.
class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white.withValues(alpha: 0.04)
      ..strokeWidth = 0.5;
    for (double x = 0; x < size.width; x += 32) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }
    for (double y = 0; y < size.height; y += 32) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }
  @override
  bool shouldRepaint(_GridPainter _) => false;
}
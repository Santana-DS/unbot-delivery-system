// ignore_for_file: prefer_const_constructors
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';

// ─── HAPTIC HELPERS ────────────────────────────────────────────────
void hapticLight() => HapticFeedback.lightImpact();
void hapticMedium() => HapticFeedback.mediumImpact();
void hapticSuccess() => HapticFeedback.selectionClick();

// ─── APP BUTTON ────────────────────────────────────────────────────
class AppButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final Color? color;
  final Color? textColor;
  final bool outlined;
  final IconData? icon;
  final bool loading;

  const AppButton({
    super.key,
    required this.label,
    required this.onTap,
    this.color,
    this.textColor,
    this.outlined = false,
    this.icon,
    this.loading = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg = color ?? AppColors.accent;
    final fg = textColor ?? Colors.white;

    return SizedBox(
      width: double.infinity,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: loading
              ? null
              : () {
                  hapticLight();
                  onTap();
                },
          borderRadius: BorderRadius.circular(14),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(vertical: 15),
            decoration: BoxDecoration(
              color: outlined ? Colors.transparent : bg,
              border: outlined
                  ? Border.all(color: bg, width: 1.5)
                  : null,
              borderRadius: BorderRadius.circular(14),
            ),
            child: loading
                ? Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: outlined ? bg : fg,
                      ),
                    ),
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (icon != null) ...[
                        Icon(icon, size: 18,
                            color: outlined ? bg : fg),
                        const SizedBox(width: 8),
                      ],
                      Text(
                        label,
                        style: GoogleFonts.dmSans(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: outlined ? bg : fg,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

// ─── APP CARD ──────────────────────────────────────────────────────
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets? padding;
  final Color? color;
  final VoidCallback? onTap;
  final Color? borderColor;
  final double borderWidth;

  const AppCard({
    super.key,
    required this.child,
    this.padding,
    this.color,
    this.onTap,
    this.borderColor,
    this.borderWidth = 1,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap != null
            ? () {
                hapticLight();
                onTap!();
              }
            : null,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: padding ?? const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: color ?? AC.card(context),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: borderColor ?? AC.border(context),
              width: borderWidth,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

// ─── STATUS BADGE ──────────────────────────────────────────────────
class StatusBadge extends StatelessWidget {
  final String label;
  final Color bg;
  final Color textColor;

  const StatusBadge({
    super.key,
    required this.label,
    required this.bg,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(
        label,
        style: GoogleFonts.dmSans(
            fontSize: 11, fontWeight: FontWeight.w500, color: textColor),
      ),
    );
  }
}

// ─── SECTION LABEL ─────────────────────────────────────────────────
class SectionLabel extends StatelessWidget {
  final String text;
  const SectionLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        text.toUpperCase(),
        style: GoogleFonts.dmSans(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          letterSpacing: 1.2,
          color: AC.muted(context),
        ),
      ),
    );
  }
}

// ─── FORM FIELD LABEL ──────────────────────────────────────────────
class FormFieldLabel extends StatelessWidget {
  final String text;
  const FormFieldLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text.toUpperCase(),
        style: GoogleFonts.dmSans(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.8,
          color: AC.muted(context),
        ),
      ),
    );
  }
}

// ─── APP TOGGLE ────────────────────────────────────────────────────
class AppToggle extends StatefulWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const AppToggle({super.key, required this.value, required this.onChanged});

  @override
  State<AppToggle> createState() => _AppToggleState();
}

class _AppToggleState extends State<AppToggle> {
  late bool _val;

  @override
  void initState() {
    super.initState();
    _val = widget.value;
  }

  @override
  void didUpdateWidget(AppToggle old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) _val = widget.value;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        hapticMedium();
        setState(() => _val = !_val);
        widget.onChanged(_val);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeInOut,
        width: 46,
        height: 26,
        decoration: BoxDecoration(
          color: _val
              ? AppColors.teal
              : AC.primary(context).withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(13),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeInOut,
          alignment:
              _val ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.all(3),
            width: 20,
            height: 20,
            decoration: const BoxDecoration(
                color: Colors.white, shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }
}

// ─── ROBOT ICON (CustomPainter, repaint-safe) ──────────────────────
class RobotIcon extends StatelessWidget {
  final double size;
  final Color color;

  const RobotIcon(
      {super.key, this.size = 48, this.color = Colors.white});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _RobotPainter(color: color)),
    );
  }
}

class _RobotPainter extends CustomPainter {
  final Color color;
  _RobotPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final bodyPaint = Paint()..color = color;
    final accentPaint = Paint()..color = AppColors.accent;
    final dimPaint = Paint()
      ..color = AppColors.primary.withValues(alpha: 0.25);
    final wheelPaint = Paint()
      ..color = color.withValues(alpha: 0.5);

    // Body
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.1, h * 0.38, w * 0.8, h * 0.48),
        Radius.circular(w * 0.12),
      ),
      bodyPaint,
    );

    // Head
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.3, h * 0.1, w * 0.4, h * 0.3),
        Radius.circular(w * 0.08),
      ),
      bodyPaint..color = color.withValues(alpha: 0.8),
    );

    // Eyes
    canvas.drawCircle(Offset(w * 0.35, h * 0.56), w * 0.08, accentPaint);
    canvas.drawCircle(Offset(w * 0.65, h * 0.56), w * 0.08, accentPaint);

    // Mouth
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.38, h * 0.7, w * 0.24, h * 0.08),
        const Radius.circular(4),
      ),
      dimPaint,
    );

    // Wheels
    canvas.drawCircle(Offset(w * 0.25, h * 0.9), w * 0.08, wheelPaint);
    canvas.drawCircle(Offset(w * 0.75, h * 0.9), w * 0.08, wheelPaint);
  }

  @override
  bool shouldRepaint(_RobotPainter old) => old.color != color;
}

// ─── MAP BACKGROUND PAINTER ────────────────────────────────────────
class MapBackgroundPainter extends CustomPainter {
  final bool isDark;
  const MapBackgroundPainter({this.isDark = false});

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = (isDark ? Colors.white : AppColors.primary)
          .withValues(alpha: 0.05)
      ..strokeWidth = 0.5;

    for (double x = 0; x < size.width; x += 28) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (double y = 0; y < size.height; y += 28) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final roadPaint = Paint()
      ..color = (isDark ? Colors.white : Colors.white)
          .withValues(alpha: isDark ? 0.08 : 0.75);

    canvas.drawRect(
        Rect.fromLTWH(0, size.height * 0.32, size.width, 20), roadPaint);
    canvas.drawRect(
        Rect.fromLTWH(0, size.height * 0.68, size.width, 20), roadPaint);
    canvas.drawRect(
        Rect.fromLTWH(size.width * 0.2, 0, 20, size.height), roadPaint);
    canvas.drawRect(
        Rect.fromLTWH(size.width * 0.5, 0, 20, size.height), roadPaint);
    canvas.drawRect(
        Rect.fromLTWH(size.width * 0.8, 0, 20, size.height), roadPaint);
  }

  @override
  bool shouldRepaint(MapBackgroundPainter old) => old.isDark != isDark;
}

// ─── NAV ITEM (shared by both home shells) ─────────────────────────
class AppNavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? badge;

  const AppNavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        hapticLight();
        onTap();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accent.withValues(alpha: 0.1)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(icon,
                    size: 24,
                    color:
                        selected ? AppColors.accent : AC.muted(context)),
                if (badge != null)
                  Positioned(
                    right: -6,
                    top: -4,
                    child: Container(
                      width: 16,
                      height: 16,
                      decoration: const BoxDecoration(
                          color: AppColors.accent, shape: BoxShape.circle),
                      child: Center(
                        child: Text(badge!,
                            style: const TextStyle(
                                fontSize: 9,
                                color: Colors.white,
                                fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: GoogleFonts.dmSans(
                fontSize: 10,
                fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                color: selected ? AppColors.accent : AC.muted(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── BOTTOM NAV CONTAINER ──────────────────────────────────────────
class AppBottomNav extends StatelessWidget {
  final List<AppNavItem> items;

  const AppBottomNav({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AC.card(context),
        border: Border(
            top: BorderSide(color: AC.border(context))),
      ),
      child: SafeArea(
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: items,
          ),
        ),
      ),
    );
  }
}

// ─── PULSING DOT (live indicator) ──────────────────────────────────
class PulsingDot extends StatefulWidget {
  final Color color;
  final double size;

  const PulsingDot(
      {super.key,
      this.color = AppColors.teal,
      this.size = 8});

  @override
  State<PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(seconds: 1))
      ..repeat(reverse: true);
    _anim = Tween(begin: 0.4, end: 1.0).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.color.withValues(alpha: _anim.value),
        ),
      ),
    );
  }
}

// ─── SNACK BAR HELPER ──────────────────────────────────────────────
void showAppSnack(BuildContext context, String message,
    {bool isError = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message,
          style: GoogleFonts.dmSans(fontSize: 13, color: Colors.white)),
      backgroundColor: isError ? Colors.red.shade700 : AppColors.primary,
      behavior: SnackBarBehavior.floating,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.all(16),
      duration: const Duration(seconds: 2),
    ),
  );
}

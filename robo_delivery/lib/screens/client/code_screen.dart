// lib/screens/client/code_screen.dart
//
// FIXES APPLIED IN THIS REVISION
// ───────────────────────────────
// FIX #1 — Zombie order state: import active_order_state.dart and call
//           removeOrder(widget.orderId) immediately when validateOtp returns
//           true, BEFORE setState(). This guarantees the global notifier fires
//           synchronously so the home-screen badge and order card disappear the
//           moment the compartment opens, not one frame later.
//
// FIX #2 — Stuck Offline guard: added _isValidating bool that is set true at
//           the start of the API call and unconditionally reset to false in a
//           finally block on every code path (success, 503, timeout, exception).
//           This prevents double-taps from issuing concurrent requests while
//           still allowing a fresh retry the moment the current call settles.
//           The AppButton's `loading` prop is wired to _isValidating so the
//           user gets clear visual feedback that a request is in-flight.
//
// FIX #5 — Avaliar Entrega bottom sheet: replaced the bare
//           Navigator.pushNamedAndRemoveUntil with a showModalBottomSheet that
//           contains a fully stateful 5-star rating row + optional feedback
//           TextField. Submission shows a SnackBar then clears the route stack.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../theme/app_theme.dart';
import '../../widgets/widgets.dart';
import '../../services/api_service.dart';
// FIX #1 — required to call removeOrder() on successful OTP validation.
import '../../state/active_order_state.dart';

class CodeScreen extends StatefulWidget {
  final String otp;
  final String orderId;

  const CodeScreen({
    super.key,
    required this.otp,
    required this.orderId,
  });

  @override
  State<CodeScreen> createState() => _CodeScreenState();
}

class _CodeScreenState extends State<CodeScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _anim;
  late Animation<double> _scaleAnim;
  int _secondsLeft = 1920; // 32 min
  Timer? _timer;
  bool _codeUsed = false;

  // FIX #2 — in-flight guard: true only while an API call is active.
  // Reset unconditionally in the finally block so every subsequent tap always
  // reaches the backend fresh — no stale boolean can prevent a retry.
  bool _isValidating = false;

  /// Format OTP for display (e.g. "7429" → "7 4 2 9")
  String get _codeFormatted => widget.otp.split('').join(' ');

  /// OTP without spaces for API validation
  String get _codeForValidation => widget.otp.replaceAll(' ', '');

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat(reverse: true);
    _scaleAnim = Tween(begin: 1.0, end: 1.03).animate(
      CurvedAnimation(parent: _anim, curve: Curves.easeInOut),
    );
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _secondsLeft > 0) {
        setState(() => _secondsLeft--);
      }
    });
  }

  @override
  void dispose() {
    _anim.dispose();
    _timer?.cancel();
    super.dispose();
  }

  String get _timeFormatted {
    final m = _secondsLeft ~/ 60;
    final s = _secondsLeft % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  // ─── OTP validation handler ──────────────────────────────────────────────
  //
  // FIX #1 + FIX #2:
  //   • try/finally guarantees _isValidating resets on EVERY exit path,
  //     including 503, timeout, and unhandled exceptions. The next tap will
  //     always reach the backend — the guard only blocks concurrent taps.
  //   • On success: removeOrder() fires before setState() so the notifier
  //     update and the local UI update are both visible in the same frame.
  Future<void> _handleSimularRetirada() async {
    // Guard: block concurrent in-flight requests, not retries.
    if (_isValidating) return;

    setState(() => _isValidating = true);

    try {
      final sucesso = await ApiService().validateOtp(
        _codeForValidation,
        widget.orderId,
      );

      // Async gap safety: widget may have been disposed during the await.
      if (!mounted) return;

      if (sucesso is UnlockSuccess) {
        // FIX #1 — remove from global notifier BEFORE updating local UI.
        // This ensures the home badge decrements atomically with the success
        // state, with no frame where the order appears both "used" and "active".
        removeOrder(widget.orderId);

        setState(() => _codeUsed = true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Falha ao abrir: Robô offline ou código inválido'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      // FIX #2 — unconditional reset: 503, timeout, or exception all release
      // the guard so the user can retry immediately without restarting the app.
      if (mounted) setState(() => _isValidating = false);
    }
  }

  // ─── FIX #5 — Rating bottom sheet ────────────────────────────────────────
  //
  // Uses showModalBottomSheet + StatefulBuilder so the star row can be
  // interactive without requiring a separate StatefulWidget class.
  // Submission order: SnackBar → Navigator.pop (sheet) → pushNamedAndRemoveUntil.
  void _showRatingSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        return _RatingSheet(
          onSubmit: (rating, feedback) {
            // Close the sheet first.
            Navigator.pop(sheetCtx);
            // Then show the SnackBar and clear the route stack.
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Obrigado pela avaliação! ⭐',
                  style: GoogleFonts.dmSans(fontSize: 13, color: Colors.white),
                ),
                backgroundColor: AppColors.teal,
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                margin: const EdgeInsets.all(16),
                duration: const Duration(seconds: 2),
              ),
            );
            // Clear entire stack back to home.
            Navigator.pushNamedAndRemoveUntil(
                context, '/home', (route) => false);
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AC.surface(context),
      appBar: AppBar(
        title: const Text('Código de retirada'),
        backgroundColor: AC.surface(context),
        foregroundColor: AC.primary(context),
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(
          children: [
            // ── Animated badge icon ──────────────────────────────────────
            ScaleTransition(
              scale: _scaleAnim,
              child: Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [AC.accent(context), AC.accent(context).withValues(alpha: 0.7)],
                  ),
                  borderRadius: BorderRadius.circular(26),
                  boxShadow: [
                    BoxShadow(
                      color: AC.accent(context).withValues(alpha: 0.35),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Center(
                  child: Icon(Icons.lock_open_rounded,
                      color: AC.primary(context), size: 40),
                ),
              ),
            ),

            const SizedBox(height: 20),

            Text(
              'Código de retirada',
              style: Theme.of(context).textTheme.displaySmall,
            ),

            const SizedBox(height: 8),

            Text(
              'Apresente este código no painel do robô.\nO compartimento correto será aberto automaticamente.',
              textAlign: TextAlign.center,
              style: GoogleFonts.dmSans(
                fontSize: 13,
                color: AC.muted(context),
                height: 1.6,
              ),
            ),

            const SizedBox(height: 28),

            // ── Code display / success state ─────────────────────────────
            if (!_codeUsed) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 28),
                decoration: BoxDecoration(
                  color: AC.primary(context),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  children: [
                    Text(
                      _codeFormatted,
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 48,
                        fontWeight: FontWeight.w700,
                        color: AC.surface(context),
                        letterSpacing: 10,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      // FIX: use real orderId suffix instead of hardcoded #4821.
                      'CÓDIGO ÚNICO · PEDIDO ${widget.orderId.length > 6 ? '#${widget.orderId.substring(widget.orderId.length - 6).toUpperCase()}' : widget.orderId.toUpperCase()}',
                      style: GoogleFonts.dmSans(
                        fontSize: 11,
                        color: AC.surface(context).withValues(alpha: 0.35),
                        letterSpacing: 1.5,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 14),

              // Timer row
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: AC.teal(context),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Expira em $_timeFormatted',
                    style: GoogleFonts.dmSans(
                        fontSize: 13, color: AC.muted(context)),
                  ),
                ],
              ),
            ] else ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: AC.teal(context).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                  border:
                      Border.all(color: AC.teal(context).withValues(alpha: 0.3)),
                ),
                child: Column(
                  children: [
                    Icon(Icons.check_circle_rounded,
                        color: AC.teal(context), size: 48),
                    const SizedBox(height: 12),
                    Text(
                      'Entrega concluída!',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: AC.primary(context),
                      ),
                    ),
                    Text(
                      'Bom apetite 🍱',
                      style: GoogleFonts.dmSans(
                          fontSize: 14, color: AC.muted(context)),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 24),

            // ── Instruction steps ────────────────────────────────────────
            const SectionLabel('Como retirar'),

            const _InstructionStep(
              number: '1',
              icon: Icons.smart_toy_rounded,
              title: 'Aguarde o robô chegar',
              description:
                  'O robô chegará ao seu endereço em aproximadamente 6 minutos.',
              done: true,
            ),
            _InstructionStep(
              number: '2',
              icon: Icons.touch_app_rounded,
              title: 'Insira o código no painel',
              description:
                  'Digite os 4 dígitos do seu código no display do robô.',
              active: !_codeUsed,
            ),
            _InstructionStep(
              number: '3',
              icon: Icons.inventory_2_rounded,
              title: 'Retire sua marmita',
              description:
                  'O compartimento correto abrirá automaticamente para você.',
              done: _codeUsed,
            ),

            const SizedBox(height: 24),

            // ── Primary action button ────────────────────────────────────
            //
            // FIX #2: `loading` is wired to _isValidating so the button
            //          shows a spinner and ignores taps during the request,
            //          but is fully interactive again once the request settles.
            //
            // FIX #5: success branch now opens the rating sheet.
            if (!_codeUsed)
              AppButton(
                label: 'Simular retirada',
                onTap: _handleSimularRetirada,
                loading: _isValidating, // FIX #2
                icon: Icons.lock_open_rounded,
              )
            else
              // FIX #5 — opens modal rating sheet instead of bare navigation.
              AppButton(
                label: 'Avaliar entrega',
                onTap: _showRatingSheet,
                icon: Icons.star_outline_rounded,
                color: AppColors.teal,
              ),
          ],
        ),
      ),
    );
  }
}

// ─── Rating Bottom Sheet ──────────────────────────────────────────────────────
//
// FIX #5 — Fully stateful 5-star rating row with optional feedback TextField.
// Extracted into its own StatefulWidget to keep _CodeScreenState lean.
// Communicates back via the onSubmit callback so the caller owns navigation.
class _RatingSheet extends StatefulWidget {
  final void Function(int rating, String feedback) onSubmit;

  const _RatingSheet({required this.onSubmit});

  @override
  State<_RatingSheet> createState() => _RatingSheetState();
}

class _RatingSheetState extends State<_RatingSheet> {
  int _selectedStars = 0;
  final _feedbackCtrl = TextEditingController();

  @override
  void dispose() {
    _feedbackCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AC.surface(context),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      // Respect the keyboard so the TextField stays above it.
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 32,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AC.primary(context).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Header
          Text(
            'Como foi sua entrega?',
            style: GoogleFonts.spaceGrotesk(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AC.primary(context),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Sua opinião ajuda a melhorar o serviço.',
            style: GoogleFonts.dmSans(fontSize: 13, color: AC.muted(context)),
          ),

          const SizedBox(height: 24),

          // ── Interactive 5-star row ───────────────────────────────────
          // Each star is a GestureDetector that sets _selectedStars.
          // Stars at or below _selectedStars render filled (accent color);
          // stars above render outlined (muted).
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(5, (index) {
                final starNumber = index + 1;
                final filled = starNumber <= _selectedStars;
                return GestureDetector(
                  onTap: () {
                    hapticLight();
                    setState(() => _selectedStars = starNumber);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      transitionBuilder: (child, anim) => ScaleTransition(
                        scale: anim,
                        child: child,
                      ),
                      child: Icon(
                        filled ? Icons.star_rounded : Icons.star_outline_rounded,
                        key: ValueKey(filled),
                        size: 40,
                        color: filled ? AC.accent(context) : AC.muted(context),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),

          // Star label feedback (optional UX nicety)
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _selectedStars > 0
                ? Padding(
                    key: ValueKey(_selectedStars),
                    padding: const EdgeInsets.only(top: 8),
                    child: Center(
                      child: Text(
                        _starLabel(_selectedStars),
                        style: GoogleFonts.dmSans(
                          fontSize: 13,
                          color: AC.accent(context),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  )
                : const SizedBox.shrink(key: ValueKey(0)),
          ),

          const SizedBox(height: 20),

          // ── Optional feedback TextField ──────────────────────────────
          TextField(
            controller: _feedbackCtrl,
            maxLines: 3,
            style: GoogleFonts.dmSans(
              fontSize: 14, color: AC.primary(context)),
            decoration: InputDecoration(
              hintText: 'Deixe um comentário (opcional)...',
              hintStyle:
                  GoogleFonts.dmSans(fontSize: 14, color: AC.muted(context)),
              filled: true,
              fillColor: AC.card(context),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    BorderSide(color: AC.primary(context).withValues(alpha: 0.1)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    BorderSide(color: AC.primary(context).withValues(alpha: 0.1)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide:
                    BorderSide(color: AC.accent(context), width: 1.5),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            ),
          ),

          const SizedBox(height: 24),

          // ── Submit button ────────────────────────────────────────────
          AppButton(
            label: 'Enviar Avaliação',
            onTap: _selectedStars == 0
                ? () {
                    // Nudge user to select at least one star.
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Selecione pelo menos 1 estrela.'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  }
                : () => widget.onSubmit(
                      _selectedStars,
                      _feedbackCtrl.text.trim(),
                    ),
            icon: Icons.send_rounded,
            color: _selectedStars > 0 ? AC.teal(context) : AC.muted(context),
          ),
        ],
      ),
    );
  }

  /// Human-readable label for the selected star count.
  String _starLabel(int stars) {
    switch (stars) {
      case 1:
        return 'Muito ruim 😞';
      case 2:
        return 'Ruim 😕';
      case 3:
        return 'Regular 😐';
      case 4:
        return 'Bom 😊';
      case 5:
        return 'Excelente! 🤩';
      default:
        return '';
    }
  }
}

// ─── Instruction Step ─────────────────────────────────────────────────────────
// Unchanged from original — kept here for self-contained compilation.
class _InstructionStep extends StatelessWidget {
  final String number;
  final IconData icon;
  final String title;
  final String description;
  final bool done;
  final bool active;

  const _InstructionStep({
    required this.number,
    required this.icon,
    required this.title,
    required this.description,
    this.done = false,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AC.card(context),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: active
              ? AC.accent(context).withValues(alpha: 0.3)
              : done
                ? AC.teal(context).withValues(alpha: 0.2)
                : AC.primary(context).withValues(alpha: 0.08),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: done
                  ? AC.teal(context).withValues(alpha: 0.15)
                  : active
                    ? AC.accent(context).withValues(alpha: 0.1)
                    : AC.primary(context).withValues(alpha: 0.06),
                shape: BoxShape.circle,
              ),
              child: Icon(
                done ? Icons.check_rounded : icon,
                size: 18,
                color: done
                    ? AC.teal(context)
                    : active
                        ? AC.accent(context)
                        : AC.muted(context),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.dmSans(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color:
                          done || active ? AC.primary(context) : AC.muted(context),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    description,
                    style: GoogleFonts.dmSans(
                        fontSize: 12, color: AC.muted(context), height: 1.4),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
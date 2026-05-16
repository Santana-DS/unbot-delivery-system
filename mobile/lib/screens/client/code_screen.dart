// lib/screens/client/code_screen.dart
//
// CHANGES IN THIS REVISION (Phase 1.5 — On-Demand Display)
// ──────────────────────────────────────────────────────────
// FIX — Race condition: _escanearERetirar() now performs a sequential async
//   chain:
//     1. Call wakeDisplay(orderId)    → ESP32 renders the QR on its OLED.
//     2. Await success response       → only then push QrScannerScreen.
//     3. If wakeDisplay fails         → offer manual entry, never block user.
//
// The button is disabled (loading=true) from the moment the user taps until
// either the scanner is pushed or an error is shown. This prevents double-taps
// from issuing concurrent wake-display requests.
//
// All other logic (FIX #1 removeOrder, FIX #2 _isValidating, FIX #5 rating
// sheet) is preserved unchanged.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'otp_unlock_screen.dart';
import '../../theme/app_theme.dart';
import '../../widgets/widgets.dart';
import '../../services/api_service.dart';
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

  // Covers BOTH the wake-display request and the subsequent OTP validation.
  // True from "tap scan button" until scanner is pushed (or error shown),
  // and again from "scanner returns" until validateOtp settles.
  bool _isValidating = false;

  String get _codeFormatted => widget.otp.split('').join(' ');
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
      if (mounted && _secondsLeft > 0) setState(() => _secondsLeft--);
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

  // ─── Manual OTP validation (fallback path, unchanged) ────────────────────
  Future<void> _handleSimularRetirada() async {
    if (_isValidating) return;
    setState(() => _isValidating = true);

    try {
      final result = await ApiService().validateOtp(
        _codeForValidation,
        widget.orderId,
      );

      if (!mounted) return;

      if (result is UnlockSuccess) {
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
      if (mounted) setState(() => _isValidating = false);
    }
  }

  // ─── On-demand display + scan chain (Phase 1.5) ──────────────────────────
  //
  // SEQUENCE:
  //   [button tap]
  //      │
  //      ▼
  //   setState(_isValidating = true)          ← button shows spinner, blocks re-tap
  //      │
  //      ▼
  //   ApiService().wakeDisplay(orderId)        ← POST /api/orders/{id}/wake-display
  //      │
  //      ├─ WakeDisplayTriggered ─────────────► push QrScannerScreen
  //      │                                         │
  //      │                                         ▼ (user scans or cancels)
  //      │                                      scannedCode returned
  //      │                                         │
  //      │                                         ├─ non-null ──► _handleSimularRetirada()
  //      │                                         └─ null ──────► setState(_isValidating = false)
  //      │
  //      ├─ WakeDisplayNotFound ──────────────► snackbar "pedido não encontrado"
  //      │                                      setState(_isValidating = false)
  //      │
  //      ├─ WakeDisplayUnreachable ──────────► snackbar + offer manual entry
  //      │                                      setState(_isValidating = false)
  //      │
  //      └─ WakeDisplayNetworkError ─────────► snackbar + offer manual entry
  //                                             setState(_isValidating = false)
  Future<void> _escanearERetirar() async {
    if (_isValidating) return;
    setState(() => _isValidating = true);

    try {
      // ── Step 1: Wake the display ────────────────────────────────────────
      final wakeResult = await ApiService().wakeDisplay(widget.orderId);

      if (!mounted) return;

      switch (wakeResult) {
        case WakeDisplayTriggered():
          // Display is rendering. Push the scanner immediately.
          // The ESP32 renders in ~50ms; the navigation push takes ~200ms —
          // the QR will be ready before the camera focuses.
          break; // fall through to scanner push below

        case WakeDisplayNotFound(:final message):
          // Order was completed or never existed. Don't block — show error.
          _showSnackbar(message, isError: true);
          return; // _isValidating reset in finally

        case WakeDisplayUnreachable(:final message):
          // MQTT down. Offer manual entry as the fallback.
          _showWakeFailureDialog(message);
          return; // _isValidating reset in finally

        case WakeDisplayNetworkError(:final message):
          _showWakeFailureDialog(message);
          return; // _isValidating reset in finally
      }

      // ── Step 2: Push scanner ────────────────────────────────────────────
      // _isValidating stays true while the scanner is open — prevents a
      // second tap on the "scan" button from the same screen if the user
      // navigates back without scanning.
      final scannedCode = await Navigator.push<String>(
        context,
        MaterialPageRoute(
          builder: (_) => QrScannerScreen(expectedCode: _codeForValidation),
        ),
      );

      if (!mounted) return;

      if (scannedCode != null) {
        // ── Step 3: Validate OTP ──────────────────────────────────────────
        // _isValidating is still true here; _handleSimularRetirada's own
        // guard check `if (_isValidating) return` would block, so we call
        // the validation logic directly without going through that guard.
        final result = await ApiService().validateOtp(
          _codeForValidation,
          widget.orderId,
        );

        if (!mounted) return;

        if (result is UnlockSuccess) {
          removeOrder(widget.orderId);
          setState(() => _codeUsed = true);
        } else {
          _showSnackbar(
            'Falha ao abrir: Robô offline ou código inválido',
            isError: true,
          );
        }
      }
      // scannedCode == null means user cancelled the scanner — do nothing,
      // just release the lock below in finally.

    } finally {
      // Unconditional release — every exit path (success, error, cancel,
      // exception) must restore the button to its interactive state.
      if (mounted) setState(() => _isValidating = false);
    }
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────

  void _showSnackbar(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: GoogleFonts.dmSans(fontSize: 13, color: Colors.white),
        ),
        backgroundColor: isError ? Colors.red.shade700 : AppColors.teal,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  // Shown when wake-display fails due to MQTT being unreachable.
  // Gives the user a clear choice: retry or fall back to manual entry.
  void _showWakeFailureDialog(String reason) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AC.card(context),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Display do robô inacessível',
          style: GoogleFonts.spaceGrotesk(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AC.primary(context),
          ),
        ),
        content: Text(
          '$reason\n\nVocê pode digitar o código manualmente.',
          style: GoogleFonts.dmSans(fontSize: 13, color: AC.muted(context)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Usar código manual',
              style: GoogleFonts.dmSans(color: AppColors.accent),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              // Retry the full chain.
              _escanearERetirar();
            },
            child: Text(
              'Tentar novamente',
              style: GoogleFonts.dmSans(
                color: AppColors.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Rating sheet (FIX #5, unchanged) ────────────────────────────────────
  void _showRatingSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        return _RatingSheet(
          onSubmit: (rating, feedback) {
            Navigator.pop(sheetCtx);
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
                    colors: [
                      AC.accent(context),
                      AC.accent(context).withValues(alpha: 0.7)
                    ],
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

            Text('Código de retirada',
                style: Theme.of(context).textTheme.displaySmall),

            const SizedBox(height: 8),

            Text(
              'Apresente este código no painel do robô.\nO compartimento correto será aberto automaticamente.',
              textAlign: TextAlign.center,
              style: GoogleFonts.dmSans(
                  fontSize: 13, color: AC.muted(context), height: 1.6),
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

              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                        color: AC.teal(context), shape: BoxShape.circle),
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
                  border: Border.all(
                      color: AC.teal(context).withValues(alpha: 0.3)),
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
                    Text('Bom apetite 🍱',
                        style: GoogleFonts.dmSans(
                            fontSize: 14, color: AC.muted(context))),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 24),

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
              title: 'Escaneie o QR Code do robô',
              description:
                  'Toque em "Escanear" — o display do robô mostrará o código.',
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

            if (!_codeUsed)
              Column(
                children: [
                  // Primary: scan button — triggers wake-display chain.
                  // loading=true during BOTH the wake-display request AND
                  // after scanner returns (while validateOtp is in-flight).
                  AppButton(
                    label: 'Escanear Robô e Abrir',
                    onTap: _escanearERetirar,
                    loading: _isValidating,
                    icon: Icons.qr_code_scanner_rounded,
                  ),
                  const SizedBox(height: 12),
                  // Fallback: manual simulation — bypasses the display chain.
                  TextButton.icon(
                    onPressed: _isValidating ? null : _handleSimularRetirada,
                    icon: const Icon(Icons.touch_app_rounded, size: 18),
                    label: Text(
                      'Simular retirada (Manual)',
                      style: GoogleFonts.dmSans(
                          fontSize: 14, fontWeight: FontWeight.w500),
                    ),
                    style:
                        TextButton.styleFrom(foregroundColor: AppColors.accent),
                  ),
                ],
              )
            else
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

// ─── Rating Bottom Sheet (FIX #5, unchanged) ─────────────────────────────────

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
            style:
                GoogleFonts.dmSans(fontSize: 13, color: AC.muted(context)),
          ),
          const SizedBox(height: 24),
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
                      transitionBuilder: (child, anim) =>
                          ScaleTransition(scale: anim, child: child),
                      child: Icon(
                        filled
                            ? Icons.star_rounded
                            : Icons.star_outline_rounded,
                        key: ValueKey(filled),
                        size: 40,
                        color: filled
                            ? AC.accent(context)
                            : AC.muted(context),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _feedbackCtrl,
            maxLines: 3,
            style: GoogleFonts.dmSans(
                fontSize: 14, color: AC.primary(context)),
            decoration: InputDecoration(
              hintText: 'Deixe um comentário (opcional)...',
              hintStyle: GoogleFonts.dmSans(
                  fontSize: 14, color: AC.muted(context)),
              filled: true,
              fillColor: AC.card(context),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                    color: AC.primary(context).withValues(alpha: 0.1)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                    color: AC.primary(context).withValues(alpha: 0.1)),
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
          AppButton(
            label: 'Enviar Avaliação',
            onTap: _selectedStars == 0
                ? () => ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content:
                              Text('Selecione pelo menos 1 estrela.')),
                    )
                : () =>
                    widget.onSubmit(_selectedStars, _feedbackCtrl.text.trim()),
            icon: Icons.send_rounded,
            color: _selectedStars > 0
                ? AC.teal(context)
                : AC.muted(context),
          ),
        ],
      ),
    );
  }
}

// ─── Instruction Step (unchanged) ────────────────────────────────────────────

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
                      color: done || active
                          ? AC.primary(context)
                          : AC.muted(context),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    description,
                    style: GoogleFonts.dmSans(
                        fontSize: 12,
                        color: AC.muted(context),
                        height: 1.4),
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

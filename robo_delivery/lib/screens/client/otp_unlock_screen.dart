// lib/screens/client/otp_unlock_screen.dart
//
// Phase 2 — OTP Entry Screen with explicit state machine.
//
// STATE MACHINE
// ─────────────
//   OtpScreenState is a sealed class with four subtypes:
//
//     OtpIdle         Initial state. Submit enabled when all 4 digits filled.
//     OtpValidating   API call in-flight. Submit locked, spinner shown.
//     OtpSuccess      Gateway confirmed unlock. Transition to success UI.
//     OtpError        Terminal per-attempt error with typed message + action hint.
//
//   Transitions live exclusively in _OtpController (a ChangeNotifier).
//   The widget tree calls exactly one method: controller.submit(). Everything
//   else — focus management, auto-advance, backspace retreat — is local widget
//   logic that does not need to survive a rebuild.
//
// FOCUS NODE DESIGN
// ─────────────────
//   Four FocusNodes are created in initState() and disposed in dispose().
//   Each _OtpDigitField calls onChanged which:
//     1. Stores the digit in the controller's _digits list.
//     2. If a digit was entered (length == 1) → requests focus on [i+1].
//     3. If backspace cleared the field (length == 0) → requests focus on [i-1].
//   There is no RawKeyboardListener or KeyEventResult involved — we use the
//   TextEditingController's onChanged callback plus a custom InputFormatter
//   that allows only a single digit. This keeps the implementation compatible
//   with both physical keyboards and software keyboards without any platform
//   channel hackery.
//
// STATE MANAGEMENT CHOICE: StatefulWidget + ChangeNotifier
// ──────────────────────────────────────────────────────────
//   The project already uses provider for global state (active_order_state,
//   user_state). For screen-local state a ChangeNotifier owned by the State
//   object is the correct granularity — no Provider ancestor needed, no
//   BuildContext.watch() outside the widget that owns the controller, and
//   the controller is guaranteed to be disposed with the screen.
//   Riverpod or Bloc would be over-engineering for a single-screen flow.
// ignore_for_file: prefer_const_constructors

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../theme/app_theme.dart';
import '../../widgets/widgets.dart';
import '../../services/api_service.dart';

// ─── STATE MACHINE ───────────────────────────────────────────────────────────

sealed class OtpScreenState {
  const OtpScreenState();
}

final class OtpIdle extends OtpScreenState {
  const OtpIdle();
}

final class OtpValidating extends OtpScreenState {
  const OtpValidating();
}

final class OtpSuccess extends OtpScreenState {
  final String orderId;
  const OtpSuccess({required this.orderId});
}

/// Terminal per-attempt error. [isRetryable] drives whether to show a retry
/// button (transient errors) or a re-entry prompt (permanent errors).
final class OtpError extends OtpScreenState {
  final String message;

  /// true  → 502 / network error  → show retry SnackBar, keep digits intact.
  /// false → 401 invalid code     → show inline error, clear digits.
  final bool isRetryable;

  const OtpError({required this.message, required this.isRetryable});
}

// ─── CONTROLLER (ChangeNotifier) ─────────────────────────────────────────────

class _OtpController extends ChangeNotifier {
  _OtpController({required this.orderId});

  final String orderId;
  final ApiService _api = ApiService();

  OtpScreenState _state = const OtpIdle();
  OtpScreenState get state => _state;

  // Raw digit storage — index 0..3 maps to field 0..3.
  // Exposed as a getter so the widget can read the current assembled code
  // without the controller caring about TextEditingControllers.
  final List<String> _digits = ['', '', '', ''];

  void setDigit(int index, String value) {
    assert(index >= 0 && index < 4);
    _digits[index] = value;
    // No notifyListeners() here — the digit change only affects focus
    // and the submit-button enabled state, both of which are derived
    // directly from _isComplete. We notify only on state transitions.
    notifyListeners();
  }

  bool get _isComplete => _digits.every((d) => d.isNotEmpty);

  /// The 4-digit code assembled from the current digit list.
  String get code => _digits.join();

  /// Whether the submit button should be interactive.
  bool get canSubmit =>
      _isComplete && _state is OtpIdle;

  Future<void> submit() async {
    if (!canSubmit) return;

    _transition(const OtpValidating());

    final result = await _api.validateOtp(code, orderId);

    switch (result) {
      case UnlockSuccess(:final orderId):
        _transition(OtpSuccess(orderId: orderId));

      case UnlockInvalidCode(:final message):
        // Clear digits so the user must re-enter a new code.
        _digits.fillRange(0, 4, '');
        _transition(OtpError(message: message, isRetryable: false));

      case UnlockRobotUnreachable(:final message):
        // Keep digits intact — user can retry the same code.
        _transition(OtpError(message: message, isRetryable: true));

      case UnlockNetworkError(:final message):
        _transition(OtpError(message: message, isRetryable: true));
    }
  }

  void resetToIdle() {
    _digits.fillRange(0, 4, '');
    _transition(const OtpIdle());
  }

  void _transition(OtpScreenState next) {
    _state = next;
    notifyListeners();
  }
}

// ─── SCREEN ──────────────────────────────────────────────────────────────────

class OtpUnlockScreen extends StatefulWidget {
  /// The active order's backend identifier. Passed to the gateway as order_id.
  final String orderId;

  /// Optional: pre-fill the OTP fields when arriving from QR scanner.
  final String? prefillCode;

  const OtpUnlockScreen({
    super.key,
    required this.orderId,
    this.prefillCode,
  });

  @override
  State<OtpUnlockScreen> createState() => _OtpUnlockScreenState();
}

class _OtpUnlockScreenState extends State<OtpUnlockScreen> {
  late final _OtpController _controller;

  // Four controllers + four focus nodes, one per digit field.
  // Created once in initState(), disposed in dispose().
  // The ordering contract: index 0 = leftmost digit.
  late final List<TextEditingController> _textCtrls;
  late final List<FocusNode> _focusNodes;

  @override
  void initState() {
    super.initState();
    _controller = _OtpController(orderId: widget.orderId);
    _textCtrls = List.generate(4, (_) => TextEditingController());
    _focusNodes = List.generate(4, (_) => FocusNode());

    // Pre-fill from QR scanner if a code was supplied.
    if (widget.prefillCode != null && widget.prefillCode!.length == 4) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _prefill(widget.prefillCode!);
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    for (final c in _textCtrls) {
      c.dispose();
    }
    for (final f in _focusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  // ── Pre-fill from QR ───────────────────────────────────────────────────────
  void _prefill(String code) {
    for (var i = 0; i < 4; i++) {
      _textCtrls[i].text = code[i];
      _controller.setDigit(i, code[i]);
    }
    // Move focus past last field after pre-fill.
    _focusNodes.last.unfocus();
    // Auto-submit after a short delay so the user sees the digits flash in.
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _handleSubmit();
    });
  }

  // ── Digit field callbacks ─────────────────────────────────────────────────

  void _onDigitChanged(int index, String value) {
    if (value.length == 1) {
      // Digit entered — store and advance focus.
      _controller.setDigit(index, value);
      if (index < 3) {
        _focusNodes[index + 1].requestFocus();
      } else {
        // Last field filled — dismiss keyboard.
        _focusNodes[index].unfocus();
      }
    } else if (value.isEmpty) {
      // Field cleared (backspace) — store empty and retreat focus.
      _controller.setDigit(index, '');
      if (index > 0) {
        _focusNodes[index - 1].requestFocus();
      }
    }
  }

  // ── Submit ─────────────────────────────────────────────────────────────────

  Future<void> _handleSubmit() async {
    FocusScope.of(context).unfocus();
    await _controller.submit();

    if (!mounted) return;

    final state = _controller.state;

    if (state is OtpError) {
      if (state.isRetryable) {
        // 502 / network: SnackBar with retry action, keep digits.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              state.message,
              style: GoogleFonts.dmSans(fontSize: 13, color: Colors.white),
            ),
            backgroundColor: const Color(0xFFB97A00),
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.all(16),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'Tentar novamente',
              textColor: Colors.white,
              onPressed: _handleSubmit,
            ),
          ),
        );
        // Reset to idle so the button re-enables — digits are still populated.
        _controller._transition(const OtpIdle());
      } else {
        // 401: clear the digit fields and return focus to the first field.
        for (final c in _textCtrls) {
          c.clear();
        }
        _focusNodes[0].requestFocus();
        // State was already set to OtpError(isRetryable: false) by the
        // controller, which means the inline error widget will render.
      }
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AC.surface(context),
      appBar: AppBar(
        backgroundColor: AC.surface(context),
        surfaceTintColor: Colors.transparent,
        title: const Text('Código de retirada'),
        elevation: 0,
      ),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          final state = _controller.state;

          if (state is OtpSuccess) {
            return _SuccessView(orderId: state.orderId);
          }

          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // ── Hero icon ───────────────────────────────────────────
                _LockIcon(unlocked: false),
                const SizedBox(height: 28),

                // ── Heading ─────────────────────────────────────────────
                Text(
                  'Digite o código de 4 dígitos',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: AC.primary(context),
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Insira o código recebido após confirmar seu pedido,\nou escaneie o QR Code do robô.',
                  style: GoogleFonts.dmSans(
                    fontSize: 13,
                    color: AC.muted(context),
                    height: 1.5,
                  ),
                  textAlign: TextAlign.center,
                ),

                const SizedBox(height: 36),

                // ── OTP fields ──────────────────────────────────────────
                _OtpFieldRow(
                  textCtrls: _textCtrls,
                  focusNodes: _focusNodes,
                  onChanged: _onDigitChanged,
                  hasError: state is OtpError && !(state).isRetryable,
                  enabled: state is! OtpValidating,
                ),

                // ── Inline error (401 only) ──────────────────────────────
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: (state is OtpError && !state.isRetryable)
                      ? Padding(
                          key: const ValueKey('inline-error'),
                          padding: const EdgeInsets.only(top: 12),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.error_outline_rounded,
                                  size: 14, color: Colors.red),
                              const SizedBox(width: 6),
                              Text(
                                state.message,
                                style: GoogleFonts.dmSans(
                                  fontSize: 12,
                                  color: Colors.red,
                                ),
                              ),
                            ],
                          ),
                        )
                      : const SizedBox.shrink(key: ValueKey('no-error')),
                ),

                const SizedBox(height: 36),

                // ── Submit button ────────────────────────────────────────
                AppButton(
                  label: 'Abrir compartimento',
                  onTap: _handleSubmit,
                  loading: state is OtpValidating,
                  icon: Icons.lock_open_rounded,
                  // AppButton ignores onTap when loading; we also gate on
                  // canSubmit to disable when fields are incomplete.
                  color: _controller.canSubmit || state is OtpValidating
                      ? AppColors.accent
                      : AC.muted(context),
                ),

                const SizedBox(height: 16),

                // ── QR scan shortcut ─────────────────────────────────────
                if (state is! OtpValidating)
                  TextButton.icon(
                    onPressed: () async {
                      final scanned = await _openQrScanner(context);
                      if (scanned != null && mounted) {
                        _prefill(scanned);
                      }
                    },
                    icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                    label: Text(
                      'Escanear QR Code do robô',
                      style: GoogleFonts.dmSans(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    style: TextButton.styleFrom(
                        foregroundColor: AppColors.accent),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ── QR Scanner stub ───────────────────────────────────────────────────────
  // Returns a 4-digit string or null if cancelled.
  // Replace the body with mobile_scanner integration in Phase 3.
  Future<String?> _openQrScanner(BuildContext context) async {
    // Phase 3 placeholder — wire mobile_scanner here.
    // For now, simulate a successful scan so the prefill → auto-submit
    // pipeline can be tested end-to-end before Phase 3 lands.
    return showDialog<String>(
      context: context,
      builder: (ctx) => _QrScannerStubDialog(),
    );
  }
}

// ─── OTP FIELD ROW ───────────────────────────────────────────────────────────
//
// Four individual single-digit TextFields.
// Each field is strictly one character via _SingleDigitFormatter.
// The fields render as large pill boxes matching the UnBot card aesthetic.

class _OtpFieldRow extends StatelessWidget {
  final List<TextEditingController> textCtrls;
  final List<FocusNode> focusNodes;
  final void Function(int index, String value) onChanged;
  final bool hasError;
  final bool enabled;

  const _OtpFieldRow({
    required this.textCtrls,
    required this.focusNodes,
    required this.onChanged,
    required this.hasError,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(4, (i) {
        final isLast = i == 3;
        return Row(
          children: [
            _OtpDigitField(
              controller: textCtrls[i],
              focusNode: focusNodes[i],
              onChanged: (v) => onChanged(i, v),
              hasError: hasError,
              enabled: enabled,
            ),
            if (!isLast)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  '·',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 24,
                    color: AC.muted(context),
                    fontWeight: FontWeight.w300,
                  ),
                ),
              ),
          ],
        );
      }),
    );
  }
}

class _OtpDigitField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final bool hasError;
  final bool enabled;

  const _OtpDigitField({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.hasError,
    required this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    const errorColor = Colors.red;
    const activeColor = AppColors.accent;
    final idleColor = AC.border(context);

    return SizedBox(
      width: 64,
      height: 72,
      child: Focus(
        focusNode: focusNode,
        child: Builder(builder: (ctx) {
          final isFocused = Focus.of(ctx).hasFocus;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              color: AC.card(context),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: hasError
                    ? errorColor
                    : isFocused
                        ? activeColor
                        : idleColor,
                width: (hasError || isFocused) ? 2.0 : 1.0,
              ),
              boxShadow: isFocused && !hasError
                  ? [
                      BoxShadow(
                        color: activeColor.withValues(alpha: 0.18),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      )
                    ]
                  : null,
            ),
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              enabled: enabled,
              textAlign: TextAlign.center,
              keyboardType: TextInputType.number,
              inputFormatters: [_SingleDigitFormatter()],
              style: GoogleFonts.spaceGrotesk(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                color: hasError ? errorColor : AC.primary(context),
              ),
              // Suppress the default InputDecoration border — our AnimatedContainer
              // handles the border so we don't get double-border artifacts.
              decoration: const InputDecoration(
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                counterText: '',
                contentPadding: EdgeInsets.zero,
              ),
              maxLength: 1,
              onChanged: onChanged,
            ),
          );
        }),
      ),
    );
  }
}

// ─── INPUT FORMATTER ─────────────────────────────────────────────────────────
//
// Allows exactly one ASCII digit (0-9) per field.
// Blocks letters, symbols, and pastes of more than one character.
// Backspace (empty string) is always allowed — it triggers the retreat logic.

class _SingleDigitFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // Always allow clearing the field.
    if (newValue.text.isEmpty) return newValue;

    // Accept only the last character typed (handles rapid paste attempts).
    final lastChar = newValue.text[newValue.text.length - 1];
    if (RegExp(r'[0-9]').hasMatch(lastChar)) {
      return newValue.copyWith(
        text: lastChar,
        selection: const TextSelection.collapsed(offset: 1),
      );
    }

    // Reject non-digit input — return old value unchanged.
    return oldValue;
  }
}

// ─── SUCCESS VIEW ─────────────────────────────────────────────────────────────

class _SuccessView extends StatelessWidget {
  final String orderId;

  const _SuccessView({required this.orderId});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: AppColors.teal.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.lock_open_rounded,
                color: AppColors.teal,
                size: 48,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Compartimento aberto!',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                color: AC.primary(context),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            Text(
              'Retire sua marmita agora.\nO compartimento fechará automaticamente.',
              style: GoogleFonts.dmSans(
                fontSize: 14,
                color: AC.muted(context),
                height: 1.6,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Pedido ${orderId.length > 6 ? '#${orderId.substring(orderId.length - 6).toUpperCase()}' : orderId.toUpperCase()}',
              style: GoogleFonts.dmSans(
                fontSize: 12,
                color: AC.muted(context),
              ),
            ),
            const SizedBox(height: 36),
            AppButton(
              label: 'Voltar ao início',
              onTap: () =>
                  Navigator.of(context).popUntil((r) => r.isFirst),
              color: AppColors.teal,
              icon: Icons.home_rounded,
            ),
          ],
        ),
      ),
    );
  }
}

// ─── LOCK ICON ────────────────────────────────────────────────────────────────

class _LockIcon extends StatelessWidget {
  final bool unlocked;

  const _LockIcon({required this.unlocked});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: const [AppColors.accent, AppColors.teal],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: AppColors.accent.withValues(alpha: 0.30),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Icon(
        unlocked ? Icons.lock_open_rounded : Icons.lock_outline_rounded,
        color: Colors.white,
        size: 38,
      ),
    );
  }
}

// ─── QR SCANNER STUB DIALOG ───────────────────────────────────────────────────
// Phase 3 replaces this with a full-screen mobile_scanner widget.
// The stub lets the team test the prefill → auto-submit pipeline immediately.

class _QrScannerStubDialog extends StatefulWidget {
  @override
  State<_QrScannerStubDialog> createState() => _QrScannerStubDialogState();
}

class _QrScannerStubDialogState extends State<_QrScannerStubDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AC.card(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        'Simular QR Scan',
        style: GoogleFonts.spaceGrotesk(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AC.primary(context)),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Phase 3 stub — insira um código de 4 dígitos:',
            style: GoogleFonts.dmSans(fontSize: 13, color: AC.muted(context)),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            keyboardType: TextInputType.number,
            maxLength: 4,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: TextStyle(color: AC.primary(context)),
            decoration: const InputDecoration(counterText: ''),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancelar',
              style: GoogleFonts.dmSans(color: AC.muted(context))),
        ),
        TextButton(
          onPressed: () {
            if (_ctrl.text.length == 4) Navigator.pop(context, _ctrl.text);
          },
          child: Text('Confirmar',
              style: GoogleFonts.dmSans(
                  color: AppColors.accent, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}

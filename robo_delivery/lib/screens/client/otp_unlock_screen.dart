// lib/screens/client/otp_unlock_screen.dart
//
// CHANGES IN THIS REVISION (Phase 3 — QR Scanner, torch fix)
// ─────────────────────────────────────────────────────────────────────────────
// ROOT CAUSE OF THE TORCHSTATE CRASH (documented for the team):
//
//   MobileScannerController exposes torch state via a ValueNotifier<TorchState>
//   that is backed by a native platform channel. This channel is only
//   initialised after MobileScanner's internal camera session starts — which
//   happens asynchronously AFTER the first frame the widget is inserted into
//   the tree. Any call to:
//
//     _scannerCtrl.torchState          ← reading the ValueNotifier too early
//     _scannerCtrl.toggleTorch()       ← calling the native method too early
//
//   before the camera is ready throws LateInitializationError on Android and
//   a PlatformException on iOS.
//
// FIX STRATEGY:
//   1. Track camera readiness with a local `_cameraReady` bool, set to true
//      inside the `MobileScanner.onScannerStarted` callback (mobile_scanner
//      ≥ 5.0 provides this; see implementation below).
//   2. Wrap the torch AppBar action in `ValueListenableBuilder<TorchState>`
//      so the icon is always reactive and never reads a stale snapshot.
//   3. Guard `toggleTorch()` with `if (_cameraReady)` so a fast double-tap
//      before initialization cannot trigger the crash.
//   4. Dispose the controller in dispose() — not in a finally block — so
//      it is only called once and only after the widget has fully unmounted.
//
// ANDROID MANIFEST (already applied in your repo):
//   <uses-permission android:name="android.permission.CAMERA" />
//
// IOS Info.plist (add if missing):
//   <key>NSCameraUsageDescription</key>
//   <string>Usado para escanear o QR Code do robô UnBot.</string>
//
// PACKAGE:
//   mobile_scanner: ^5.0.0   (pinned in pubspec.yaml)
// ─────────────────────────────────────────────────────────────────────────────
// ignore_for_file: prefer_const_constructors

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
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

final class OtpError extends OtpScreenState {
  final String message;
  final bool isRetryable;
  const OtpError({required this.message, required this.isRetryable});
}

// ─── CONTROLLER ──────────────────────────────────────────────────────────────

class _OtpController extends ChangeNotifier {
  _OtpController({required this.orderId});

  final String orderId;
  final ApiService _api = ApiService();

  OtpScreenState _state = const OtpIdle();
  OtpScreenState get state => _state;

  final List<String> _digits = ['', '', '', ''];

  void setDigit(int index, String value) {
    assert(index >= 0 && index < 4);
    _digits[index] = value;
    notifyListeners();
  }

  bool get _isComplete => _digits.every((d) => d.isNotEmpty);
  String get code => _digits.join();
  bool get canSubmit => _isComplete && _state is OtpIdle;

  Future<void> submit() async {
    if (!canSubmit) return;
    _transition(const OtpValidating());

    final result = await _api.validateOtp(code, orderId);

    switch (result) {
      case UnlockSuccess(:final orderId):
        _transition(OtpSuccess(orderId: orderId));
      case UnlockInvalidCode(:final message):
        _digits.fillRange(0, 4, '');
        _transition(OtpError(message: message, isRetryable: false));
      case UnlockRobotUnreachable(:final message):
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
  final String orderId;
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
  late final List<TextEditingController> _textCtrls;
  late final List<FocusNode> _focusNodes;

  @override
  void initState() {
    super.initState();
    _controller = _OtpController(orderId: widget.orderId);
    _textCtrls = List.generate(4, (_) => TextEditingController());
    _focusNodes = List.generate(4, (_) => FocusNode());

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

  // ── Pre-fill from QR or prefillCode prop ──────────────────────────────────
  void _prefill(String code) {
    for (var i = 0; i < 4; i++) {
      _textCtrls[i].text = code[i];
      _controller.setDigit(i, code[i]);
    }
    _focusNodes.last.unfocus();
    // 300 ms delay: lets the digits visually "flash in" before the spinner
    // appears — intentional UX, not a race workaround.
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _handleSubmit();
    });
  }

  void _onDigitChanged(int index, String value) {
    if (value.length == 1) {
      _controller.setDigit(index, value);
      if (index < 3) {
        _focusNodes[index + 1].requestFocus();
      } else {
        _focusNodes[index].unfocus();
      }
    } else if (value.isEmpty) {
      _controller.setDigit(index, '');
      if (index > 0) _focusNodes[index - 1].requestFocus();
    }
  }

  Future<void> _handleSubmit() async {
    FocusScope.of(context).unfocus();
    await _controller.submit();

    if (!mounted) return;

    final state = _controller.state;
    if (state is OtpError) {
      if (state.isRetryable) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(state.message,
                style: GoogleFonts.dmSans(fontSize: 13, color: Colors.white)),
            backgroundColor: const Color(0xFFB97A00),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.all(16),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'Tentar novamente',
              textColor: Colors.white,
              onPressed: _handleSubmit,
            ),
          ),
        );
        _controller._transition(const OtpIdle());
      } else {
        for (final c in _textCtrls) {
          c.clear();
        }
        _focusNodes[0].requestFocus();
      }
    }
  }

  // ── QR Scanner ────────────────────────────────────────────────────────────
  Future<void> _openQrScanner() async {
    final scanned = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const QrScannerScreen()),
    );
    if (scanned != null && mounted) {
      _prefill(scanned);
    }
  }

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
                _LockIcon(unlocked: false),
                const SizedBox(height: 28),

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
                      fontSize: 13, color: AC.muted(context), height: 1.5),
                  textAlign: TextAlign.center,
                ),

                const SizedBox(height: 36),

                _OtpFieldRow(
                  textCtrls: _textCtrls,
                  focusNodes: _focusNodes,
                  onChanged: _onDigitChanged,
                  hasError: state is OtpError && !(state).isRetryable,
                  enabled: state is! OtpValidating,
                ),

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
                                    fontSize: 12, color: Colors.red),
                              ),
                            ],
                          ),
                        )
                      : const SizedBox.shrink(key: ValueKey('no-error')),
                ),

                const SizedBox(height: 36),

                AppButton(
                  label: 'Abrir compartimento',
                  onTap: _handleSubmit,
                  loading: state is OtpValidating,
                  icon: Icons.lock_open_rounded,
                  color: _controller.canSubmit || state is OtpValidating
                      ? AppColors.accent
                      : AC.muted(context),
                ),

                const SizedBox(height: 16),

                if (state is! OtpValidating)
                  TextButton.icon(
                    onPressed: _openQrScanner,
                    icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                    label: Text(
                      'Escanear QR Code do robô',
                      style: GoogleFonts.dmSans(
                          fontSize: 13, fontWeight: FontWeight.w500),
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
}

// ─────────────────────────────────────────────────────────────────────────────
// QR SCANNER SCREEN
// ─────────────────────────────────────────────────────────────────────────────
//
// THE TORCH LIFECYCLE BUG — root cause and fix (read before modifying):
//
//   mobile_scanner's MobileScannerController wraps a native AVCaptureSession
//   (iOS) or CameraX session (Android). The torch is a hardware feature on
//   that session. Until the session starts, every call to toggleTorch() or
//   read of torchState fires a platform channel call that has no native object
//   to talk to → crash.
//
//   The session starts asynchronously. The first safe moment to interact with
//   torch state is the `onScannerStarted` callback on the MobileScanner widget,
//   or the first emission of the `MobileScannerController.torchState` notifier
//   (which emits TorchState.off once the hardware is ready).
//
//   FIX:
//     a) `_cameraReady` bool — set to true inside `onScannerStarted`.
//     b) Torch IconButton is wrapped in ValueListenableBuilder<TorchState> so
//        it only rebuilds when the notifier actually emits, and it guards
//        toggleTorch() behind `if (!_cameraReady) return`.
//     c) Camera-switch button has the same guard.
//
// DOUBLE-POP GUARD:
//   Android's MLKit can fire onDetect multiple times per QR frame burst.
//   `_scanned` bool prevents all but the first valid detection from popping.
//
// VALIDATION:
//   Only QR codes whose rawValue is exactly 4 ASCII digits are accepted.
//   Invalid QR codes show a SnackBar and resume scanning — no dialog.

class QrScannerScreen extends StatefulWidget {
  const QrScannerScreen({super.key});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  late final MobileScannerController _scannerCtrl;

  // ── Lifecycle guards ──────────────────────────────────────────────────────
  //
  // _cameraReady: false until onScannerStarted fires. Gates all torch/camera
  //   interactions to prevent platform channel calls on an uninitialised session.
  //
  // _scanned: true after the first valid QR is processed. Prevents double-pop
  //   from the MLKit burst-detection behaviour on Android.
  bool _cameraReady = false;
  bool _scanned = false;

  @override
  void initState() {
    super.initState();
    _scannerCtrl = MobileScannerController(
      // Only accept QR codes — barcode, Data Matrix, etc. are ignored.
      formats: [BarcodeFormat.qrCode],
      // Start on the back camera. User can switch via AppBar.
      facing: CameraFacing.back,
      // FIX: Do NOT pass torchEnabled here. Setting torch state during
      // controller construction fires a platform channel call before the
      // native session exists. Let it default to false (off); the user
      // can toggle it once _cameraReady is true.
      // torchEnabled: false,  ← removed: was the source of the crash
    );
  }

  @override
  void dispose() {
    // Dispose must happen here, in dispose(), NOT in a finally block inside
    // the scanner callback. The controller's dispose() call joins the
    // camera session and must run after the widget is fully unmounted.
    _scannerCtrl.dispose();
    super.dispose();
  }

  // ── Camera started callback ───────────────────────────────────────────────
  //
  // Called by MobileScanner once the native camera session has fully started.
  // After this fires it is safe to call toggleTorch() and switchCamera().
  void _onScannerStarted(MobileScannerArguments? args) {
    if (!mounted) return;
    setState(() => _cameraReady = true);
  }

  // ── Torch toggle ──────────────────────────────────────────────────────────
  void _toggleTorch() {
    // GUARD: Never call platform channel methods before the session is ready.
    if (!_cameraReady) return;
    _scannerCtrl.toggleTorch();
  }

  // ── Camera switch ─────────────────────────────────────────────────────────
  void _switchCamera() {
    if (!_cameraReady) return;
    _scannerCtrl.switchCamera();
  }

  // ── Barcode detection ─────────────────────────────────────────────────────
  void _onDetect(BarcodeCapture capture) {
    if (_scanned) return;

    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;

      final isValidOtp = raw.length == 4 && RegExp(r'^\d{4}$').hasMatch(raw);

      if (isValidOtp) {
        _scanned = true;
        hapticSuccess();
        Navigator.pop(context, raw);
        return;
      }

      // Invalid QR content — non-blocking hint only; do not close the scanner.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'QR Code inválido. Aponte para o código do robô.',
              style: GoogleFonts.dmSans(fontSize: 13, color: Colors.white),
            ),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.all(16),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          'Escanear QR Code',
          style: GoogleFonts.spaceGrotesk(
              fontSize: 17, fontWeight: FontWeight.w600, color: Colors.white),
        ),
        actions: [
          // ── Torch button ────────────────────────────────────────────────
          //
          // FIX: ValueListenableBuilder<TorchState> ensures the icon is
          // always derived from the live notifier state, not a stale snapshot.
          // The builder will not fire until the native session emits its first
          // TorchState value, so there is no risk of reading an uninitialised
          // notifier.
          ValueListenableBuilder<TorchState>(
            valueListenable: _scannerCtrl.torchState,
            builder: (context, torchState, _) {
              final isOn = torchState == TorchState.on;
              return IconButton(
                // Dim the icon while the camera is still initialising so the
                // user gets a visual cue that the button is not yet active.
                icon: Icon(
                  isOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
                  color: _cameraReady
                      ? (isOn ? Colors.yellow : Colors.white)
                      : Colors.white38,
                ),
                tooltip: isOn ? 'Desligar lanterna' : 'Ligar lanterna',
                // GUARD: no-op until the session is ready.
                onPressed: _cameraReady ? _toggleTorch : null,
              );
            },
          ),

          // ── Camera switch button ─────────────────────────────────────────
          IconButton(
            icon: Icon(
              Icons.flip_camera_ios_rounded,
              color: _cameraReady ? Colors.white : Colors.white38,
            ),
            tooltip: 'Trocar câmera',
            onPressed: _cameraReady ? _switchCamera : null,
          ),
        ],
      ),
      body: Stack(
        children: [
          // ── Camera feed ──────────────────────────────────────────────────
          MobileScanner(
            controller: _scannerCtrl,
            onDetect: _onDetect,
            // FIX: onScannerStarted is the authoritative signal that the
            // native camera session is live. Only after this callback fires
            // is it safe to call toggleTorch() or switchCamera().
            onScannerStarted: _onScannerStarted,
          ),

          // ── Frosted overlay with cutout ──────────────────────────────────
          Positioned.fill(
            child: CustomPaint(
              painter: _ScannerOverlayPainter(
                cutoutSize: 240,
                borderColor: AppColors.accent,
                overlayColor: Colors.black.withValues(alpha: 0.55),
              ),
            ),
          ),

          // ── Status indicator: initialising vs. ready ──────────────────
          //
          // Shows a subtle loading ring while _cameraReady == false so the
          // user knows the camera is spinning up and doesn't tap buttons
          // that would silently fail (or did crash in the old build).
          if (!_cameraReady)
            Positioned.fill(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 32,
                      height: 32,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.accent,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Iniciando câmera...',
                      style: GoogleFonts.dmSans(
                          fontSize: 13, color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ),

          // ── Instructions label ───────────────────────────────────────────
          Positioned(
            bottom: 80,
            left: 32,
            right: 32,
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'Aponte para o QR Code no painel do robô',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.dmSans(
                      fontSize: 13,
                      color: Colors.white,
                      height: 1.4,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // Manual entry fallback — if QR is damaged or missing
                TextButton(
                  onPressed: () => Navigator.pop(context, null),
                  child: Text(
                    'Digitar código manualmente',
                    style: GoogleFonts.dmSans(
                      fontSize: 13,
                      color: Colors.white60,
                      decoration: TextDecoration.underline,
                      decorationColor: Colors.white38,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── SCANNER OVERLAY PAINTER ─────────────────────────────────────────────────
//
// Full-screen semi-transparent overlay with a square transparent cutout and
// accent-coloured corner brackets. Unchanged from previous revision.

class _ScannerOverlayPainter extends CustomPainter {
  final double cutoutSize;
  final Color borderColor;
  final Color overlayColor;

  const _ScannerOverlayPainter({
    required this.cutoutSize,
    required this.borderColor,
    required this.overlayColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final half = cutoutSize / 2;

    final cutout = Rect.fromLTWH(cx - half, cy - half, cutoutSize, cutoutSize);
    final cutoutRRect =
        RRect.fromRectAndRadius(cutout, const Radius.circular(16));

    final overlayPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRRect(cutoutRRect)
      ..fillType = PathFillType.evenOdd;

    canvas.drawPath(overlayPath, Paint()..color = overlayColor);

    final bracketPaint = Paint()
      ..color = borderColor
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    const bracketLen = 28.0;
    const r = 16.0;

    // Top-left
    canvas.drawLine(Offset(cutout.left + r, cutout.top),
        Offset(cutout.left + r + bracketLen, cutout.top), bracketPaint);
    canvas.drawLine(Offset(cutout.left, cutout.top + r),
        Offset(cutout.left, cutout.top + r + bracketLen), bracketPaint);
    // Top-right
    canvas.drawLine(Offset(cutout.right - r, cutout.top),
        Offset(cutout.right - r - bracketLen, cutout.top), bracketPaint);
    canvas.drawLine(Offset(cutout.right, cutout.top + r),
        Offset(cutout.right, cutout.top + r + bracketLen), bracketPaint);
    // Bottom-left
    canvas.drawLine(Offset(cutout.left + r, cutout.bottom),
        Offset(cutout.left + r + bracketLen, cutout.bottom), bracketPaint);
    canvas.drawLine(Offset(cutout.left, cutout.bottom - r),
        Offset(cutout.left, cutout.bottom - r - bracketLen), bracketPaint);
    // Bottom-right
    canvas.drawLine(Offset(cutout.right - r, cutout.bottom),
        Offset(cutout.right - r - bracketLen, cutout.bottom), bracketPaint);
    canvas.drawLine(Offset(cutout.right, cutout.bottom - r),
        Offset(cutout.right, cutout.bottom - r - bracketLen), bracketPaint);
  }

  @override
  bool shouldRepaint(_ScannerOverlayPainter old) =>
      old.cutoutSize != cutoutSize ||
      old.borderColor != borderColor ||
      old.overlayColor != overlayColor;
}

// ─── OTP FIELD ROW ───────────────────────────────────────────────────────────

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
        return Row(
          children: [
            _OtpDigitField(
              controller: textCtrls[i],
              focusNode: focusNodes[i],
              onChanged: (v) => onChanged(i, v),
              hasError: hasError,
              enabled: enabled,
            ),
            if (i < 3)
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

class _SingleDigitFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.isEmpty) return newValue;
    final lastChar = newValue.text[newValue.text.length - 1];
    if (RegExp(r'[0-9]').hasMatch(lastChar)) {
      return newValue.copyWith(
        text: lastChar,
        selection: const TextSelection.collapsed(offset: 1),
      );
    }
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
                  fontSize: 14, color: AC.muted(context), height: 1.6),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Pedido ${orderId.length > 6 ? '#${orderId.substring(orderId.length - 6).toUpperCase()}' : orderId.toUpperCase()}',
              style:
                  GoogleFonts.dmSans(fontSize: 12, color: AC.muted(context)),
            ),
            const SizedBox(height: 36),
            AppButton(
              label: 'Voltar ao início',
              onTap: () => Navigator.of(context).popUntil((r) => r.isFirst),
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
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.accent, AppColors.teal],
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

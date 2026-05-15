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
      MaterialPageRoute(
        builder: (_) => QrScannerScreen(expectedCode: widget.prefillCode ?? ''),
      ),
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
// QrScannerScreen — mobile_scanner ^5.0.0 compliant
// ─────────────────────────────────────────────────────────────────────────────
//
// BREAKING CHANGES FROM v4 → v5 (what was removed and what replaces it):
//
//   REMOVED: MobileScannerArguments
//     The type no longer exists. onScannerStarted was removed from the
//     MobileScanner widget entirely.
//
//   REMOVED: controller.torchState (ValueNotifier<TorchState>)
//     The separate torchState notifier is gone. Torch state is now a field
//     inside MobileScannerState, exposed through the controller itself:
//       controller.value             → MobileScannerState
//       controller.value.torchState  → TorchState (on | off | unavailable)
//
//   REMOVED: onScannerStarted callback on MobileScanner widget
//     Camera readiness is no longer signalled via a widget callback.
//     Instead, MobileScannerController is itself a ValueNotifier<MobileScannerState>.
//     Listen to it to react to any state change, including the transition from
//     MobileScannerState.stopping/stopped → MobileScannerState.running.
//
//   REPLACEMENT PATTERN for camera readiness + torch state:
//     ValueListenableBuilder<MobileScannerState>(
//       valueListenable: _scannerCtrl,
//       builder: (context, state, child) {
//         final isRunning = state.isRunning;           // camera ready guard
//         final torchOn   = state.torchState == TorchState.on;
//         ...
//       },
//     )
//
// LIFECYCLE INVARIANT (unchanged from v4, still applies):
//   toggleTorch() and switchCamera() are safe to call only when the camera
//   session is running. In v5 this is expressed as:
//     if (_scannerCtrl.value.isRunning) _scannerCtrl.toggleTorch();
//   rather than the old _cameraReady bool + onScannerStarted callback.
//
// INTEGRATION:
//   Drop this class (and its State) into otp_unlock_screen.dart, replacing
//   the existing QrScannerScreen and _QrScannerScreenState verbatim.
//   No other classes in that file need to change.
// ─────────────────────────────────────────────────────────────────────────────


class QrScannerScreen extends StatefulWidget {
  final String expectedCode;

  const QrScannerScreen({super.key, required this.expectedCode});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  late final MobileScannerController _scannerCtrl;

  // Double-pop guard: MLKit on Android fires onDetect multiple times per
  // burst. Once we have a valid code and have called Navigator.pop(), we
  // must ignore every subsequent detection callback.
  bool _scanned = false;

  @override
  void initState() {
    super.initState();
    // v5: Do NOT pass torchEnabled here — torch state is managed through
    // the controller's ValueNotifier<MobileScannerState> after the session
    // starts. Passing it in the constructor is a no-op in v5 anyway, but
    // leaving it out makes the intent unambiguous.
    _scannerCtrl = MobileScannerController(
      formats: [BarcodeFormat.qrCode],
      facing: CameraFacing.back,
    );
  }

  @override
  void dispose() {
    // stop() + dispose() in sequence: stop() terminates the camera session
    // cleanly (releases the hardware lock on Android/iOS), then dispose()
    // frees the Dart-side controller and removes all listeners.
    // Do NOT call dispose() without stop() first — on some Android devices
    // this leaves the camera in an acquired state, blocking other apps.
    _scannerCtrl.stop();
    _scannerCtrl.dispose();
    super.dispose();
  }

  // ── Torch toggle ──────────────────────────────────────────────────────────
  //
  // v5 guard: read controller.value.isRunning instead of the old _cameraReady
  // bool. isRunning is true only while the native camera session is active.
  void _toggleTorch() {
    if (!_scannerCtrl.value.isRunning) return;
    _scannerCtrl.toggleTorch();
  }

  // ── Camera switch ─────────────────────────────────────────────────────────
  void _switchCamera() {
    if (!_scannerCtrl.value.isRunning) return;
    _scannerCtrl.switchCamera();
  }

  // ── Barcode detection ─────────────────────────────────────────────────────
  void _onDetect(BarcodeCapture capture) {
    if (_scanned) return;

    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;

      final isValidOtp = raw == widget.expectedCode;

      if (isValidOtp) {
        _scanned = true;
        Navigator.pop(context, raw);
        return;
      }

      // Invalid QR content — non-blocking snackbar, scanner keeps running.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'QR Code inválido. Não corresponde a este pedido.',
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
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        actions: [
          // ── Torch button ────────────────────────────────────────────────
          //
          // v5: Listen to the controller itself (ValueNotifier<MobileScannerState>).
          // controller.value.torchState replaces the old controller.torchState
          // ValueNotifier that was removed in v5.
          //
          // isRunning gates the button so it is visually disabled (greyed out)
          // while the camera session is still initialising — same safety
          // invariant as before, expressed through the v5 API.
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _scannerCtrl,
            builder: (context, state, _) {
              final isRunning = state.isRunning;
              final torchOn = state.torchState == TorchState.on;

              return IconButton(
                icon: Icon(
                  torchOn
                      ? Icons.flash_on_rounded
                      : Icons.flash_off_rounded,
                  // Dim icon while camera is initialising — communicates
                  // that the button is not yet active without disabling it
                  // in a way that breaks the visual rhythm of the AppBar.
                  color: isRunning
                      ? (torchOn ? Colors.yellow : Colors.white)
                      : Colors.white38,
                ),
                tooltip: torchOn ? 'Desligar lanterna' : 'Ligar lanterna',
                onPressed: isRunning ? _toggleTorch : null,
              );
            },
          ),

          // ── Camera switch button ─────────────────────────────────────────
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _scannerCtrl,
            builder: (context, state, _) {
              return IconButton(
                icon: Icon(
                  Icons.flip_camera_ios_rounded,
                  color: state.isRunning ? Colors.white : Colors.white38,
                ),
                tooltip: 'Trocar câmera',
                onPressed: state.isRunning ? _switchCamera : null,
              );
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          // ── Camera feed ──────────────────────────────────────────────────
          // v5: onScannerStarted is removed from the widget. Camera lifecycle
          // is observed exclusively through the controller's ValueNotifier.
          MobileScanner(
            controller: _scannerCtrl,
            onDetect: _onDetect,
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

          // ── Camera initialising indicator ────────────────────────────────
          //
          // Shown until controller.value.isRunning becomes true.
          // ValueListenableBuilder rebuilds automatically on that transition
          // so the spinner disappears the moment the session is live —
          // no polling, no Timer, no setState().
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _scannerCtrl,
            builder: (context, state, _) {
              if (state.isRunning) return const SizedBox.shrink();
              return Positioned.fill(
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
              );
            },
          ),

          // ── Instructions + manual entry fallback ─────────────────────────
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

    canvas.drawLine(Offset(cutout.left + r, cutout.top),
        Offset(cutout.left + r + bracketLen, cutout.top), bracketPaint);
    canvas.drawLine(Offset(cutout.left, cutout.top + r),
        Offset(cutout.left, cutout.top + r + bracketLen), bracketPaint);
    canvas.drawLine(Offset(cutout.right - r, cutout.top),
        Offset(cutout.right - r - bracketLen, cutout.top), bracketPaint);
    canvas.drawLine(Offset(cutout.right, cutout.top + r),
        Offset(cutout.right, cutout.top + r + bracketLen), bracketPaint);
    canvas.drawLine(Offset(cutout.left + r, cutout.bottom),
        Offset(cutout.left + r + bracketLen, cutout.bottom), bracketPaint);
    canvas.drawLine(Offset(cutout.left, cutout.bottom - r),
        Offset(cutout.left, cutout.bottom - r - bracketLen), bracketPaint);
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

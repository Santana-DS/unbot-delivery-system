// lib/screens/login_screen.dart
//
// UnBot Delivery — First Contact / Login Screen
// ─────────────────────────────────────────────────────────────────────────────
// FIX #1 — Role Selector: Added a segmented pill control (Cliente / Restaurante)
//           rendered directly in the form body. _selectedRole drives navigation:
//           'client'     → ClientHomeScreen()
//           'restaurant' → RestaurantHomeScreen()
//           Both roles share the same form fields; the Submit handler reads
//           _selectedRole at invocation time so the toggle is stateless w.r.t.
//           the form validation logic.
//
// FIX #2 — State Hydration ("Maria Silva" bug):
//           • Added _nameCtrl TextEditingController for the Sign-Up name field.
//             Previously the name _InputField was constructed with no controller,
//             making the value unreachable from _handleSubmit().
//           • _handleSubmit() now calls updateUser() BEFORE Navigator.pushReplacement
//             so the global userStateNotifier is populated before ClientHomeScreen
//             (or RestaurantHomeScreen) renders its first frame.
//           • Sign-Up path: uses typed name + email directly.
//           • Login path: derives a display name from the email local-part
//             (e.g. "joao@unb.br" → "Joao") via _nameFromEmail() so the Home
//             screen greeting is immediately personalised.
//           • Controllers are disposed correctly in dispose().
// ignore_for_file: prefer_const_constructors

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../widgets/widgets.dart';
import '../state/user_state.dart';                        // FIX #2
import 'client/client_home_screen.dart';
import 'restaurant/restaurant_home_screen.dart';           // FIX #1

// ─── Brand palette (matches splash_screen.dart constants) ─────────────────────
class _Brand {
  static const navy        = Color(0xFF003366);
  static const green       = Color(0xFF006633);
  static const glow        = Color(0xFF00C97A);
  static const onDark      = Color(0xFFF0F4F0);
  static const onDarkMuted = Color(0xFF8DB8A0);
}

// ─── Role enum ────────────────────────────────────────────────────────────────
enum _Role { client, restaurant }

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  // ── Animation ─────────────────────────────────────────────────────────────
  late final AnimationController _heroCtrl;
  late final Animation<double>   _heroScale;
  late final Animation<double>   _formFade;
  late final Animation<Offset>   _formSlide;

  // ── Form controllers ──────────────────────────────────────────────────────
  // FIX #2: _nameCtrl added so the sign-up name field value is reachable from
  // _handleSubmit(). All three controllers are disposed in dispose().
  final _nameCtrl  = TextEditingController();  // FIX #2
  final _emailCtrl = TextEditingController();
  final _passCtrl  = TextEditingController();

  // ── Form state ────────────────────────────────────────────────────────────
  bool  _obscure    = true;
  bool  _loading    = false;
  bool  _isSignUp   = false;

  // FIX #1: Role selection — defaults to client, drives post-auth navigation.
  _Role _selectedRole = _Role.client;

  @override
  void initState() {
    super.initState();

    _heroCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    _heroScale = Tween<double>(begin: 0.72, end: 1.0).animate(
      CurvedAnimation(parent: _heroCtrl, curve: Curves.elasticOut),
    );
    _formFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _heroCtrl,
        curve: const Interval(0.4, 1.0, curve: Curves.easeOut),
      ),
    );
    _formSlide = Tween<Offset>(
      begin: const Offset(0, 0.12),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _heroCtrl,
        curve: const Interval(0.4, 1.0, curve: Curves.easeOut),
      ),
    );

    Future.delayed(const Duration(milliseconds: 80), () {
      if (mounted) _heroCtrl.forward();
    });
  }

  @override
  void dispose() {
    _heroCtrl.dispose();
    _nameCtrl.dispose();   // FIX #2
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  // ── FIX #2: Derive a display name from email local-part ───────────────────
  // "joao.silva@unb.br" → "Joao"   (first segment, title-cased)
  // Falls back to the whole local-part if no dot/hyphen separator is present.
  String _nameFromEmail(String email) {
    final local = email.split('@').first;
    final first = local.split(RegExp(r'[._\-+]')).first;
    if (first.isEmpty) return local;
    return first[0].toUpperCase() + first.substring(1).toLowerCase();
  }

  // ── Submit handler (FIX #1 + FIX #2) ────────────────────────────────────
  Future<void> _handleSubmit() async {
    if (_loading) return;
    hapticLight();

    final email = _emailCtrl.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      _showError('Informe um e-mail válido.');
      return;
    }
    if (_passCtrl.text.length < 4) {
      _showError('Senha muito curta.');
      return;
    }
    // Sign-up: name field must not be blank.
    if (_isSignUp && _nameCtrl.text.trim().isEmpty) {
      _showError('Informe seu nome completo.');
      return;
    }

    setState(() => _loading = true);
    await Future.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;
    setState(() => _loading = false);

    // ── FIX #2: Hydrate global user state BEFORE navigation ──────────────
    // Determines the display name for the Home screen greeting immediately.
    // Without this, userStateNotifier still holds the _kDefaultUser seed
    // ("Maria Silva") when ClientHomeScreen renders its first frame.
    final displayName = _isSignUp
        ? _nameCtrl.text.trim()
        : _nameFromEmail(email);

    updateUser(
      userStateNotifier.value.copyWith(
        name:  displayName,
        email: email,
      ),
    );

    // ── FIX #1: Route based on selected role ─────────────────────────────
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => _selectedRole == _Role.restaurant
            ? const RestaurantHomeScreen()
            : const ClientHomeScreen(),
      ),
    );
  }

  void _showError(String msg) {
    hapticLight();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg,
            style: GoogleFonts.dmSans(fontSize: 13, color: Colors.white)),
        backgroundColor: Colors.red.shade700,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ));

    return Scaffold(
      backgroundColor: AC.surface(context),
      resizeToAvoidBottomInset: true,
      body: Column(
        children: [
          _Header(heroScale: _heroScale),

          Expanded(
            child: SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 40),
              child: FadeTransition(
                opacity: _formFade,
                child: SlideTransition(
                  position: _formSlide,
                  child: _FormBody(
                    isSignUp:     _isSignUp,
                    selectedRole: _selectedRole,        // FIX #1
                    nameCtrl:     _nameCtrl,             // FIX #2
                    emailCtrl:    _emailCtrl,
                    passCtrl:     _passCtrl,
                    obscure:      _obscure,
                    loading:      _loading,
                    onRoleChanged: (role) =>             // FIX #1
                        setState(() => _selectedRole = role),
                    onToggleObscure: () =>
                        setState(() => _obscure = !_obscure),
                    onSubmit: _handleSubmit,
                    onToggleMode: () {
                      hapticLight();
                      setState(() {
                        _isSignUp = !_isSignUp;
                        _nameCtrl.clear();
                        _emailCtrl.clear();
                        _passCtrl.clear();
                      });
                    },
                    onForgot: () =>
                        _showError('Recuperação de senha em breve.'),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Header ──────────────────────────────────────────────────────────────────
class _Header extends StatelessWidget {
  final Animation<double> heroScale;
  const _Header({required this.heroScale});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 260,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_Brand.navy, Color(0xFF004D26), _Brand.green],
          stops: [0.0, 0.55, 1.0],
        ),
      ),
      child: Stack(
        children: [
          Positioned.fill(child: CustomPaint(painter: _GridPainter())),

          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 8,
            child: Navigator.of(context).canPop()
                ? IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new_rounded,
                        color: _Brand.onDarkMuted, size: 18),
                    onPressed: () => Navigator.maybePop(context),
                  )
                : const SizedBox.shrink(),
          ),

          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(height: MediaQuery.of(context).padding.top * 0.5),

                ScaleTransition(
                  scale: heroScale,
                  child: _RobotBadge(),
                ),

                const SizedBox(height: 18),

                Text(
                  'UnBot Delivery',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: _Brand.onDark,
                    letterSpacing: 0.3,
                    shadows: [
                      Shadow(
                        color: _Brand.glow.withValues(alpha: 0.4),
                        blurRadius: 20,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 5),

                Text(
                  'Entrega autônoma na UnB',
                  style: GoogleFonts.dmSans(
                    fontSize: 13,
                    color: _Brand.onDarkMuted,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),

          Positioned(
            bottom: -1,
            left: 0,
            right: 0,
            child: CustomPaint(
              painter: _CurvePainter(
                color: Theme.of(context).brightness == Brightness.dark
                    ? AppColors.darkSurface
                    : AppColors.surface,
              ),
              size: const Size(double.infinity, 32),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Robot Badge ─────────────────────────────────────────────────────────────
class _RobotBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 76,
      height: 76,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        shape: BoxShape.circle,
        border: Border.all(
            color: _Brand.glow.withValues(alpha: 0.40), width: 1.8),
        boxShadow: [
          BoxShadow(
            color: _Brand.glow.withValues(alpha: 0.28),
            blurRadius: 28,
            spreadRadius: 6,
          ),
        ],
      ),
      child: const Center(
        child: RobotIcon(size: 44, color: _Brand.onDark),
      ),
    );
  }
}

// ─── FIX #1: Role Selector Pill ──────────────────────────────────────────────
//
// A custom segmented control built from first principles so it matches the
// existing AppColors system exactly — no dependency on CupertinoSegmentedControl
// (which ignores Material theming) or third-party packages.
//
// Layout: pill container with a sliding highlight behind the active segment.
// The highlight uses AnimatedContainer so transitions are smooth (200 ms).
//
// Colors:
//   Active pill   → AppColors.accent fill, white label
//   Inactive pill → transparent fill, AC.muted(context) label
//   Container bg  → AC.card(context) with AC.border() stroke
class _RoleSelector extends StatelessWidget {
  final _Role selected;
  final ValueChanged<_Role> onChanged;

  const _RoleSelector({
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 46,
      decoration: BoxDecoration(
        color: AC.card(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AC.border(context)),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          _RolePill(
            label: 'Sou Cliente',
            icon: Icons.person_rounded,
            active: selected == _Role.client,
            onTap: () {
              hapticLight();
              onChanged(_Role.client);
            },
          ),
          _RolePill(
            label: 'Sou Restaurante',
            icon: Icons.store_rounded,
            active: selected == _Role.restaurant,
            onTap: () {
              hapticLight();
              onChanged(_Role.restaurant);
            },
          ),
        ],
      ),
    );
  }
}

class _RolePill extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  const _RolePill({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          decoration: BoxDecoration(
            color: active ? AppColors.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            boxShadow: active
                ? [
                    BoxShadow(
                      color: AppColors.accent.withValues(alpha: 0.30),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    )
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 15,
                color: active ? Colors.white : AC.muted(context),
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: GoogleFonts.dmSans(
                  fontSize: 12,
                  fontWeight:
                      active ? FontWeight.w600 : FontWeight.w400,
                  color: active ? Colors.white : AC.muted(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Form Body ───────────────────────────────────────────────────────────────
class _FormBody extends StatelessWidget {
  final bool isSignUp;
  final _Role selectedRole;                // FIX #1
  final TextEditingController nameCtrl;    // FIX #2
  final TextEditingController emailCtrl;
  final TextEditingController passCtrl;
  final bool obscure;
  final bool loading;
  final ValueChanged<_Role> onRoleChanged; // FIX #1
  final VoidCallback onToggleObscure;
  final VoidCallback onSubmit;
  final VoidCallback onToggleMode;
  final VoidCallback onForgot;

  const _FormBody({
    required this.isSignUp,
    required this.selectedRole,
    required this.nameCtrl,
    required this.emailCtrl,
    required this.passCtrl,
    required this.obscure,
    required this.loading,
    required this.onRoleChanged,
    required this.onToggleObscure,
    required this.onSubmit,
    required this.onToggleMode,
    required this.onForgot,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Section heading ────────────────────────────────────────────────
        Text(
          isSignUp ? 'Criar conta' : 'Bem-vindo de volta',
          style: GoogleFonts.spaceGrotesk(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: AC.primary(context),
          ),
        ),

        const SizedBox(height: 4),

        Text(
          isSignUp
              ? 'Preencha os dados para começar'
              : 'Entre para rastrear sua entrega',
          style: GoogleFonts.dmSans(fontSize: 14, color: AC.muted(context)),
        ),

        const SizedBox(height: 20),

        // ── FIX #1: Role Selector ─────────────────────────────────────────
        // Placed above the form fields so the user commits to a role before
        // typing credentials — minimises the chance of submitting to the
        // wrong home screen. The selector is always visible (not gated on
        // isSignUp) because role selection is relevant for both flows.
        _RoleSelector(
          selected: selectedRole,
          onChanged: onRoleChanged,
        ),

        const SizedBox(height: 20),

        // ── Name field (sign-up only) — FIX #2: wired to nameCtrl ─────────
        AnimatedSize(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeInOut,
          child: isSignUp
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FormFieldLabel('Nome completo'),
                    // FIX #2: controller: nameCtrl — was omitted, making the
                    // typed value unreachable from _handleSubmit().
                    _InputField(
                      controller: nameCtrl,
                      hint: 'Seu nome completo',
                      icon: Icons.person_outline_rounded,
                      textCapitalization: TextCapitalization.words,
                    ),
                    const SizedBox(height: 16),
                  ],
                )
              : const SizedBox.shrink(),
        ),

        // ── E-mail ────────────────────────────────────────────────────────
        FormFieldLabel('E-mail'),
        _InputField(
          controller: emailCtrl,
          hint: 'seu@email.com',
          icon: Icons.email_outlined,
          keyboardType: TextInputType.emailAddress,
        ),

        const SizedBox(height: 16),

        // ── Password ──────────────────────────────────────────────────────
        FormFieldLabel('Senha'),
        TextField(
          controller: passCtrl,
          obscureText: obscure,
          style: TextStyle(color: AC.primary(context)),
          onSubmitted: (_) => onSubmit(),
          decoration: InputDecoration(
            hintText: '••••••••',
            prefixIcon: Icon(Icons.lock_outline_rounded,
                color: AC.muted(context), size: 20),
            suffixIcon: GestureDetector(
              onTap: onToggleObscure,
              child: Icon(
                obscure
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                color: AC.muted(context),
                size: 20,
              ),
            ),
          ),
        ),

        // ── Confirm password (sign-up only) ────────────────────────────────
        AnimatedSize(
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeInOut,
          child: isSignUp
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 16),
                    FormFieldLabel('Confirmar senha'),
                    TextField(
                      obscureText: true,
                      style: TextStyle(color: AC.primary(context)),
                      decoration: InputDecoration(
                        hintText: '••••••••',
                        prefixIcon: Icon(Icons.lock_outline_rounded,
                            color: AC.muted(context), size: 20),
                      ),
                    ),
                  ],
                )
              : const SizedBox.shrink(),
        ),

        // ── Forgot password (login only) ───────────────────────────────────
        if (!isSignUp) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: onForgot,
              child: Text(
                'Esqueci a senha',
                style: GoogleFonts.dmSans(
                  fontSize: 13,
                  color: AppColors.accent,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],

        const SizedBox(height: 28),

        // ── Primary button ─────────────────────────────────────────────────
        // FIX #1: label contextualised by role so the user knows where they
        // are about to land ("Entrar como Restaurante" vs "Entrar como Cliente").
        AppButton(
          label: _submitLabel(isSignUp, selectedRole),
          onTap: onSubmit,
          loading: loading,
          icon: isSignUp ? Icons.person_add_outlined : Icons.login_rounded,
        ),

        const SizedBox(height: 20),

        // ── Divider ───────────────────────────────────────────────────────
        Row(children: [
          Expanded(
              child: Divider(
                  color: AC.primary(context).withValues(alpha: 0.1))),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text('ou',
                style: GoogleFonts.dmSans(
                    fontSize: 12, color: AC.muted(context))),
          ),
          Expanded(
              child: Divider(
                  color: AC.primary(context).withValues(alpha: 0.1))),
        ]),

        const SizedBox(height: 16),

        // ── Google SSO placeholder ────────────────────────────────────────
        _SocialButton(
          label: 'Continuar com Google',
          icon: Icons.g_mobiledata_rounded,
          onTap: onSubmit,
        ),

        const SizedBox(height: 28),

        // ── Toggle login / sign-up ────────────────────────────────────────
        Center(
          child: GestureDetector(
            onTap: onToggleMode,
            child: RichText(
              text: TextSpan(
                style:
                    GoogleFonts.dmSans(fontSize: 13, color: AC.muted(context)),
                children: [
                  TextSpan(
                      text: isSignUp ? 'Já tem conta? ' : 'Não tem conta? '),
                  TextSpan(
                    text: isSignUp ? 'Entrar' : 'Cadastrar-se',
                    style: GoogleFonts.dmSans(
                      fontSize: 13,
                      color: AppColors.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        const SizedBox(height: 24),
        Center(
          child: Text(
            'FT · Engenharia Mecatrônica · UnB',
            style: GoogleFonts.dmSans(
              fontSize: 10,
              color: AC.muted(context).withValues(alpha: 0.5),
              letterSpacing: 0.5,
            ),
          ),
        ),
      ],
    );
  }

  // FIX #1: Contextualised submit label so the destination is unambiguous.
  static String _submitLabel(bool isSignUp, _Role role) {
    if (isSignUp) {
      return role == _Role.restaurant
          ? 'Criar conta · Restaurante'
          : 'Criar conta · Cliente';
    }
    return role == _Role.restaurant
        ? 'Entrar como Restaurante'
        : 'Entrar como Cliente';
  }
}

// ─── Reusable input wrapper ───────────────────────────────────────────────────
class _InputField extends StatelessWidget {
  final TextEditingController? controller;
  final String hint;
  final IconData icon;
  final TextInputType keyboardType;
  final TextCapitalization textCapitalization;

  const _InputField({
    this.controller,
    required this.hint,
    required this.icon,
    this.keyboardType = TextInputType.text,
    this.textCapitalization = TextCapitalization.none,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      textCapitalization: textCapitalization,
      style: TextStyle(color: AC.primary(context)),
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: Icon(icon, color: AC.muted(context), size: 20),
      ),
    );
  }
}

// ─── Social Button ────────────────────────────────────────────────────────────
class _SocialButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _SocialButton(
      {required this.label, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        hapticLight();
        onTap();
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: AC.card(context),
          border: Border.all(
              color: AC.primary(context).withValues(alpha: 0.10)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 22, color: AppColors.accent),
            const SizedBox(width: 8),
            Text(
              label,
              style: GoogleFonts.dmSans(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AC.primary(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Grid Painter ─────────────────────────────────────────────────────────────
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

// ─── Curve Painter ────────────────────────────────────────────────────────────
class _CurvePainter extends CustomPainter {
  final Color color;
  const _CurvePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = Path()
      ..moveTo(0, size.height)
      ..quadraticBezierTo(size.width / 2, 0, size.width, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_CurvePainter old) => old.color != color;
}
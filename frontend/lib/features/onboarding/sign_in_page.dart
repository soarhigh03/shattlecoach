import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../routing/app_router.dart';
import '../../services/auth_service.dart';
import '../../services/supabase_service.dart';
import '../../widgets/app_logo.dart';

class SignInPage extends ConsumerStatefulWidget {
  const SignInPage({super.key});

  @override
  ConsumerState<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends ConsumerState<SignInPage> {
  bool _busy = false;
  String? _error;

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authServiceProvider).signInWithGoogle();
      if (!mounted) return;
      context.go(AppRoute.onboardingIntro);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signInAnonymously() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authServiceProvider).signInAnonymously();
      if (!mounted) return;
      context.go(AppRoute.onboardingIntro);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final configured = SupabaseBootstrap.isInitialized;

    return Scaffold(
      backgroundColor: const Color(0xFF2C2C2E),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const Spacer(flex: 5),
              const AppLogo(size: 96),
              const SizedBox(height: 12),
              const Text(
                'shattlecoach',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 40),
              if (!configured) ...[
                const _ConfigNotice(),
                const SizedBox(height: 12),
              ],
              if (_error != null) ...[
                Text(
                  _error!,
                  style: const TextStyle(color: Color(0xFFFF6B8A)),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
              ],
              _GoogleSignInButton(busy: _busy, onPressed: _signIn),
              const SizedBox(height: 12),
              _AnonymousSignInButton(
                busy: _busy,
                onPressed: _signInAnonymously,
              ),
              const Spacer(flex: 7),
              Text(
                '© shattlecock 2026',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _GoogleSignInButton extends StatelessWidget {
  const _GoogleSignInButton({required this.busy, required this.onPressed});

  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bg = isDark
        ? theme.colorScheme.surfaceContainerHighest
        : const Color(0xFFF5F5F7);

    return SizedBox(
      width: double.infinity,
      height: 56,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        elevation: 4,
        shadowColor: Colors.black.withValues(alpha: 0.18),
        child: InkWell(
          onTap: busy ? null : onPressed,
          child: Center(
            child: busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset(
                        'assets/logo/google logo.png',
                        width: 24,
                        height: 24,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Google로 계속하기',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onSurface,
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

/// Subdued text button intended for graders/TAs — clearly secondary to the
/// primary Google flow so a regular user is unlikely to tap it by mistake.
class _AnonymousSignInButton extends StatelessWidget {
  const _AnonymousSignInButton({required this.busy, required this.onPressed});

  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 44,
      child: TextButton(
        onPressed: busy ? null : onPressed,
        style: TextButton.styleFrom(
          foregroundColor: Colors.white.withValues(alpha: 0.7),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.25)),
          ),
        ),
        child: const Text(
          '채점용 게스트 로그인',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ),
    );
  }
}

class _ConfigNotice extends StatelessWidget {
  const _ConfigNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.info_outline,
            color: theme.colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '.env에 SUPABASE_URL / SUPABASE_ANON_KEY / GOOGLE_WEB_CLIENT_ID를 채워야 로그인이 동작해요.',
              style: TextStyle(
                color: theme.colorScheme.onSecondaryContainer,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

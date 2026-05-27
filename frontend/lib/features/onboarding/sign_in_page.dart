import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../routing/app_router.dart';
import '../../services/auth_service.dart';
import '../../services/supabase_service.dart';

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
      context.go(AppRoute.onboardingProfile);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final configured = SupabaseBootstrap.isInitialized;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),
          Icon(Icons.lock_outline, size: 56, color: theme.colorScheme.primary),
          const SizedBox(height: 24),
          Text(
            'Google 계정으로 시작하기',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            '셔틀코치는 Google 소셜 로그인만 지원해요.\n동아리 계정 정보로 가입해 주세요.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
          const Spacer(),
          if (!configured)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: _ConfigNotice(),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.tertiary),
                textAlign: TextAlign.center,
              ),
            ),
          FilledButton.icon(
            onPressed: _busy ? null : _signIn,
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.login),
            label: const Text('Google로 계속하기'),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _ConfigNotice extends StatelessWidget {
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../routing/app_router.dart';
import '../../services/auth_service.dart';
import '../../services/onboarding_service.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ListView(
          children: [
            const SizedBox(height: 8),
            _AccountTile(email: user?.email, displayName: user?.userMetadata?['full_name'] as String?),
            const SizedBox(height: 8),
            _SectionHeader(text: '앱 정보'),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('버전'),
              trailing: Text('0.1.0', style: theme.textTheme.bodySmall),
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('오픈소스 라이선스'),
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'Shattlecoach',
                applicationVersion: '0.1.0',
              ),
            ),
            const SizedBox(height: 8),
            _SectionHeader(text: '개발자 도구'),
            ListTile(
              leading: const Icon(Icons.restart_alt),
              title: const Text('온보딩 다시 보기'),
              subtitle: const Text('완료 플래그를 초기화하고 환영 화면으로 돌아갑니다.'),
              onTap: () async {
                await ref.read(onboardingServiceProvider).reset();
                ref.invalidate(onboardingCompletedProvider);
                if (!context.mounted) return;
                context.go(AppRoute.onboardingWelcome);
              },
            ),
            const SizedBox(height: 16),
            if (user != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await ref.read(authServiceProvider).signOut();
                  },
                  icon: Icon(Icons.logout, color: theme.colorScheme.tertiary),
                  label: Text(
                    '로그아웃',
                    style: TextStyle(color: theme.colorScheme.tertiary),
                  ),
                ),
              ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({required this.email, required this.displayName});
  final String? email;
  final String? displayName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Icon(Icons.person, color: theme.colorScheme.onPrimaryContainer),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayName ?? '게스트',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      email ?? '로그인되지 않음',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
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

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

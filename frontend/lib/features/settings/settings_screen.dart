import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../routing/app_router.dart';
import '../../services/auth_service.dart';
import '../../services/onboarding_service.dart';
import '../../widgets/app_dialog.dart';

/// 분기별 임원진 등록 코드. 추후 서버 발급으로 대체 예정.
const String _execCodeForCurrentQuarter = '1234';

const String _appVersion = '0.1.0';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const SizedBox(height: 12),
            const _ScreenHeader(),
            const SizedBox(height: 20),
            _ProfileRow(
              email: user?.email,
              displayName: user?.userMetadata?['full_name'] as String?,
            ),
            const SizedBox(height: 20),
            const _SectionDivider(),
            const _SectionHeader(text: '계정 정보'),
            _SettingsTile(
              label: '임원진 등록하기',
              onTap: () => _openExecCodeDialog(context),
            ),
            _SettingsTile(
              label: '로그아웃 및 탈퇴',
              onTap: () => context.push(AppRoute.settingsSignOut),
            ),
            const _SectionDivider(),
            const _SectionHeader(text: '앱 정보'),
            _SettingsTile(
              label: '버전',
              onTap: () => _openVersionDialog(context),
            ),
            _SettingsTile(
              label: '오픈소스 라이선스',
              onTap: () => showLicensePage(
                context: context,
                applicationName: 'Shattlecoach',
                applicationVersion: _appVersion,
              ),
            ),
            const _SectionDivider(),
            const _SectionHeader(text: '개발자 도구'),
            _SettingsTile(
              label: '온보딩 다시 보기',
              onTap: () async {
                await ref.read(onboardingServiceProvider).reset();
                ref.invalidate(onboardingCompletedProvider);
                if (!context.mounted) return;
                context.go(AppRoute.onboardingWelcome);
              },
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Future<void> _openExecCodeDialog(BuildContext context) async {
    final code = await showAppDialog<String>(
      context: context,
      title: '임원진 등록하기',
      builder: (_) => const _ExecCodeForm(),
    );
    if (code == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (code == _execCodeForCurrentQuarter) {
      messenger.showSnackBar(
        const SnackBar(content: Text('임원진으로 등록되었습니다.')),
      );
    } else {
      messenger.showSnackBar(
        const SnackBar(content: Text('잘못된 코드입니다.')),
      );
    }
  }

  Future<void> _openVersionDialog(BuildContext context) {
    return showAppDialog<void>(
      context: context,
      title: '버전',
      builder: (_) => const Text('Shattlecoach $_appVersion'),
    );
  }
}

class _ScreenHeader extends StatelessWidget {
  const _ScreenHeader();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        '설정',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({required this.email, required this.displayName});
  final String? email;
  final String? displayName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            child: Icon(
              Icons.person,
              size: 32,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName ?? '게스트',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  email ?? '로그인되지 않음',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.onSurfaceVariant,
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

class _SectionDivider extends StatelessWidget {
  const _SectionDivider();
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 6,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
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
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

class _ExecCodeForm extends StatefulWidget {
  const _ExecCodeForm();
  @override
  State<_ExecCodeForm> createState() => _ExecCodeFormState();
}

class _ExecCodeFormState extends State<_ExecCodeForm> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(_controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('이번 분기 임원진 코드를 입력하세요.'),
        const SizedBox(height: 16),
        TextField(
          controller: _controller,
          autofocus: true,
          obscureText: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            suffixIcon: IconButton(
              icon: const Icon(Icons.chevron_right),
              onPressed: _submit,
            ),
          ),
        ),
      ],
    );
  }
}

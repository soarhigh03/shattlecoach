import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../services/auth_service.dart';
import '../../widgets/app_dialog.dart';

class SignOutPage extends ConsumerWidget {
  const SignOutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(fontSize: 17),
        title: const Text('로그아웃 및 탈퇴'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new),
          onPressed: () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '계정에서 로그아웃하거나 영구적으로 탈퇴할 수 있어요.',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: () => _confirmSignOut(context, ref),
                icon: const Icon(Icons.logout),
                label: const Text('로그아웃'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => _confirmDeleteAccount(context),
                icon: Icon(Icons.no_accounts, color: theme.colorScheme.tertiary),
                label: Text(
                  '계정 탈퇴',
                  style: TextStyle(color: theme.colorScheme.tertiary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      title: '로그아웃',
      builder: (dialogContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('정말 로그아웃하시겠어요?'),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('취소'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: const Text('로그아웃'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(authServiceProvider).signOut();
  }

  Future<void> _confirmDeleteAccount(BuildContext context) {
    return showAppDialog<void>(
      context: context,
      title: '계정 탈퇴',
      builder: (dialogContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('계정 탈퇴는 현재 준비 중이에요.\n곧 지원할 예정입니다.'),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }
}

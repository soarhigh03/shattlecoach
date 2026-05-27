import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../routing/app_router.dart';
import '../../services/onboarding_service.dart';

enum _PermStatus { idle, granted, denied }

class PermissionPrimersPage extends ConsumerStatefulWidget {
  const PermissionPrimersPage({super.key});

  @override
  ConsumerState<PermissionPrimersPage> createState() =>
      _PermissionPrimersPageState();
}

class _PermissionPrimersPageState extends ConsumerState<PermissionPrimersPage> {
  _PermStatus _camera = _PermStatus.idle;
  _PermStatus _notif = _PermStatus.idle;
  bool _finishing = false;

  Future<void> _requestCamera() async {
    final status = await Permission.camera.request();
    setState(() {
      _camera = status.isGranted ? _PermStatus.granted : _PermStatus.denied;
    });
  }

  Future<void> _requestNotifications() async {
    final status = await Permission.notification.request();
    setState(() {
      _notif = status.isGranted ? _PermStatus.granted : _PermStatus.denied;
    });
  }

  Future<void> _finish() async {
    setState(() => _finishing = true);
    await ref.read(onboardingServiceProvider).markCompleted();
    // Force the FutureProvider to refresh; the router redirect will move us into home.
    ref.invalidate(onboardingCompletedProvider);
    if (!mounted) return;
    context.go(AppRoute.aiCoach);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '권한 안내',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '아래 권한이 있어야 핵심 기능이 동작해요.\n나중에 설정에서 다시 바꿀 수 있어요.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 24),
          _PermissionCard(
            icon: Icons.videocam_outlined,
            title: '카메라',
            body: 'AI Coach에서 스윙 영상을 5초간 녹화하고\n실시간 자세 분석을 제공해요.',
            status: _camera,
            onRequest: _requestCamera,
          ),
          const SizedBox(height: 12),
          _PermissionCard(
            icon: Icons.notifications_outlined,
            title: '알림',
            body: '새로운 운동 세션과 셔틀콕 공동구매\n오픈 소식을 놓치지 않도록 알려드려요.',
            status: _notif,
            onRequest: _requestNotifications,
          ),
          const Spacer(),
          FilledButton(
            onPressed: _finishing ? null : _finish,
            child: _finishing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('시작하기'),
          ),
        ],
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.status,
    required this.onRequest,
  });

  final IconData icon;
  final String title;
  final String body;
  final _PermStatus status;
  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final granted = status == _PermStatus.granted;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: theme.colorScheme.onPrimaryContainer),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    body,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (granted)
              Icon(Icons.check_circle, color: theme.colorScheme.primary)
            else
              TextButton(
                onPressed: onRequest,
                child: Text(status == _PermStatus.denied ? '재요청' : '허용'),
              ),
          ],
        ),
      ),
    );
  }
}

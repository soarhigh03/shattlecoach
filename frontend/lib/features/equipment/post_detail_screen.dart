import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../routing/app_router.dart';
import '../../services/auth_service.dart';
import '../../widgets/app_dialog.dart';
import 'equipment_screen.dart' show StatusBadge;
import 'post_models.dart';
import 'post_providers.dart';
import 'widgets/menu_dropdown.dart';

class PostDetailScreen extends ConsumerStatefulWidget {
  const PostDetailScreen({super.key, required this.postId});

  final String postId;

  @override
  ConsumerState<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends ConsumerState<PostDetailScreen> {
  final _menuKey = GlobalKey();
  bool _changed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final async = ref.watch(postProvider(widget.postId));
    final user = ref.watch(currentUserProvider);
    final isExec = ref.watch(isExecutiveProvider).value ?? false;

    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) context.pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 20),
            onPressed: () => context.pop(_changed),
          ),
          actions: [
            async.maybeWhen(
              data: (post) {
                final canManage = isExec || post.authorId == user?.id;
                if (!canManage) return const SizedBox.shrink();
                return IconButton(
                  key: _menuKey,
                  icon: const Icon(Icons.more_vert),
                  onPressed: () => _openMenu(post),
                );
              },
              orElse: () => const SizedBox.shrink(),
            ),
          ],
        ),
        body: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                '글을 불러오지 못했어요.\n$e',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ),
          data: (post) => _PostBody(post: post),
        ),
      ),
    );
  }

  Future<void> _openMenu(Post post) async {
    await showMenuDropdown(
      context: context,
      anchorKey: _menuKey,
      items: [
        MenuDropdownItem(label: '수정하기', onTap: () => _edit(post)),
        if (post.status == PostStatus.inProgress)
          MenuDropdownItem(
            label: '종료로 표시',
            onTap: () => _setStatus(post, PostStatus.ended),
          )
        else
          MenuDropdownItem(
            label: '진행 중으로 표시',
            onTap: () => _setStatus(post, PostStatus.inProgress),
          ),
        MenuDropdownItem(
          label: '삭제하기',
          destructive: true,
          onTap: () => _delete(post),
        ),
      ],
    );
  }

  Future<void> _edit(Post post) async {
    final saved = await context.push<bool>(
      '${AppRoute.equipment}/compose',
      extra: post,
    );
    if (saved == true) {
      _changed = true;
      ref.invalidate(postProvider(post.id));
    }
  }

  Future<void> _setStatus(Post post, PostStatus next) async {
    try {
      await ref.read(postsRepositoryProvider).setStatus(post.id, next);
      _changed = true;
      ref.invalidate(postProvider(post.id));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('상태 변경에 실패했어요: $e')));
    }
  }

  Future<void> _delete(Post post) async {
    final ok = await showAppDialog<bool>(
      context: context,
      title: '글을 삭제할까요?',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('삭제한 글은 되돌릴 수 없어요.'),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('취소'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(ctx).colorScheme.error,
                  ),
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('삭제'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(postsRepositoryProvider).delete(post.id);
      if (!mounted) return;
      context.pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('삭제에 실패했어요: $e')));
    }
  }
}

class _PostBody extends ConsumerWidget {
  const _PostBody({required this.post});
  final Post post;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final repo = ref.read(postsRepositoryProvider);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        Row(
          children: [
            StatusBadge(status: post.status),
            const SizedBox(width: 8),
            Text(
              post.kind.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          post.title,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          _formatDate(post.createdAt),
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
        if (post.body.trim().isNotEmpty)
          Text(post.body, style: const TextStyle(fontSize: 15, height: 1.55)),
        if (post.images.isNotEmpty) ...[
          const SizedBox(height: 20),
          for (final img in post.images) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.network(
                repo.publicUrl(img.storagePath),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(
                  height: 200,
                  color: theme.colorScheme.surfaceContainerHighest,
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ],
    );
  }

  String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}.${two(local.month)}.${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }
}

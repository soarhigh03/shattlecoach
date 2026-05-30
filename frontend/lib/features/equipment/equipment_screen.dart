import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../routing/app_router.dart';
import '../../theme/app_theme.dart';
import 'post_models.dart';
import 'post_providers.dart';

/// 공동구매 / 부원 나눔 board.
class EquipmentScreen extends ConsumerStatefulWidget {
  const EquipmentScreen({super.key});

  @override
  ConsumerState<EquipmentScreen> createState() => _EquipmentScreenState();
}

class _EquipmentScreenState extends ConsumerState<EquipmentScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _tab.addListener(() {
      if (!_tab.indexIsChanging) setState(() {});
    });
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  PostKind get _currentKind =>
      _tab.index == 0 ? PostKind.groupBuy : PostKind.sharing;

  Future<void> _openCompose() async {
    final wrote = await context.push<bool>(
      '${AppRoute.equipment}/compose',
      extra: _currentKind,
    );
    if (wrote == true && mounted) {
      ref.invalidate(postListProvider(_currentKind));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            TabBar(
              controller: _tab,
              labelStyle: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
              unselectedLabelStyle: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
              labelColor: theme.colorScheme.onSurface,
              unselectedLabelColor: theme.colorScheme.onSurfaceVariant,
              indicatorColor: theme.colorScheme.onSurface,
              indicatorWeight: 2,
              dividerColor: theme.colorScheme.outlineVariant,
              tabs: const [
                Tab(text: '공식 공동구매'),
                Tab(text: '부원 나눔'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tab,
                children: const [
                  _PostList(kind: PostKind.groupBuy),
                  _PostList(kind: PostKind.sharing),
                ],
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openCompose,
        backgroundColor: AppPalette.navSelected,
        foregroundColor: Colors.white,
        shape: const CircleBorder(),
        child: const Icon(Icons.add, size: 28),
      ),
    );
  }
}

class _PostList extends ConsumerWidget {
  const _PostList({required this.kind});
  final PostKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(postListProvider(kind));
    return async.when(
      loading: () => const _SkeletonList(),
      error: (e, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '글을 불러오지 못했어요.\n$e',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      ),
      data: (posts) {
        if (posts.isEmpty) return const _EmptyState();
        return RefreshIndicator(
          onRefresh: () async => ref.refresh(postListProvider(kind).future),
          child: ListView.separated(
            padding: const EdgeInsets.only(top: 4, bottom: 96),
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: posts.length,
            separatorBuilder: (_, _) => Divider(
              height: 1,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            itemBuilder: (_, i) => _PostTile(post: posts[i]),
          ),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        Center(
          child: Text(
            '아직 등록된 글이 없어요.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _PostTile extends ConsumerWidget {
  const _PostTile({required this.post});
  final Post post;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final thumbPath = post.images.isNotEmpty
        ? post.images.first.storagePath
        : null;
    final thumbUrl = thumbPath == null
        ? null
        : ref.read(postsRepositoryProvider).publicUrl(thumbPath);

    return InkWell(
      onTap: () async {
        final changed = await context.push<bool>(
          '${AppRoute.equipment}/${post.id}',
        );
        if (changed == true) {
          ref.invalidate(postListProvider(post.kind));
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      StatusBadge(status: post.status),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          post.title,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  if (post.subtitle.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      post.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (thumbUrl != null) ...[
              const SizedBox(width: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.network(
                  thumbUrl,
                  width: 56,
                  height: 56,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    width: 56,
                    height: 56,
                    color: theme.colorScheme.surfaceContainerHighest,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SkeletonList extends StatefulWidget {
  const _SkeletonList();

  @override
  State<_SkeletonList> createState() => _SkeletonListState();
}

class _SkeletonListState extends State<_SkeletonList>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.only(top: 4, bottom: 96),
      physics: const NeverScrollableScrollPhysics(),
      itemCount: 6,
      separatorBuilder: (_, _) => Divider(
        height: 1,
        color: Theme.of(context).colorScheme.outlineVariant,
      ),
      itemBuilder: (_, i) => _SkeletonTile(pulse: _pulse, withThumb: i.isEven),
    );
  }
}

class _SkeletonTile extends StatelessWidget {
  const _SkeletonTile({required this.pulse, required this.withThumb});

  final Animation<double> pulse;
  final bool withThumb;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _SkeletonBox(
                      pulse: pulse,
                      width: 52,
                      height: 20,
                      radius: 999,
                    ),
                    const SizedBox(width: 8),
                    _SkeletonBox(pulse: pulse, width: 140, height: 16),
                  ],
                ),
                const SizedBox(height: 10),
                _SkeletonBox(pulse: pulse, width: 200, height: 12),
              ],
            ),
          ),
          if (withThumb) ...[
            const SizedBox(width: 12),
            _SkeletonBox(pulse: pulse, width: 56, height: 56, radius: 6),
          ],
        ],
      ),
    );
  }
}

class _SkeletonBox extends StatelessWidget {
  const _SkeletonBox({
    required this.pulse,
    required this.width,
    required this.height,
    this.radius = 4,
  });

  final Animation<double> pulse;
  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: pulse,
      builder: (_, _) {
        final base = theme.colorScheme.surfaceContainerHighest;
        final highlight = theme.colorScheme.surface;
        return Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: Color.lerp(base, highlight, pulse.value * 0.6),
            borderRadius: BorderRadius.circular(radius),
          ),
        );
      },
    );
  }
}

class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.status});
  final PostStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isActive = status == PostStatus.inProgress;
    final bg = isActive
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHighest;
    final fg = isActive
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      ),
    );
  }
}

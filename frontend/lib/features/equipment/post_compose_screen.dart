import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../theme/app_theme.dart';
import 'post_models.dart';
import 'post_providers.dart';

/// Compose screen for creating or editing a post.
///
/// When [editing] is non-null the screen acts as an edit form (kind chips are
/// disabled and pre-existing images can be removed / appended to).
class PostComposeScreen extends ConsumerStatefulWidget {
  const PostComposeScreen({super.key, this.initialKind, this.editing});

  final PostKind? initialKind;
  final Post? editing;

  @override
  ConsumerState<PostComposeScreen> createState() => _PostComposeScreenState();
}

class _PostComposeScreenState extends ConsumerState<PostComposeScreen> {
  late PostKind _kind;
  late final TextEditingController _title;
  late final TextEditingController _body;
  late List<PostImage> _keepImages;
  final List<File> _newImages = [];
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    _kind = e?.kind ?? widget.initialKind ?? PostKind.groupBuy;
    _title = TextEditingController(text: e?.title ?? '');
    _body = TextEditingController(text: e?.body ?? '');
    _keepImages = List.of(e?.images ?? const []);
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 1600,
    );
    if (picked == null) return;
    setState(() => _newImages.add(File(picked.path)));
  }

  Future<void> _submit() async {
    final title = _title.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('제목을 입력해 주세요.')),
      );
      return;
    }
    setState(() => _submitting = true);
    final repo = ref.read(postsRepositoryProvider);
    try {
      final body = _body.text.trim();
      final editing = widget.editing;
      if (editing == null) {
        await repo.create(
          kind: _kind,
          title: title,
          body: body,
          images: _newImages,
        );
      } else {
        await repo.update(
          postId: editing.id,
          kind: _kind,
          title: title,
          body: body,
          keepImages: _keepImages,
          newImages: _newImages,
        );
      }
      if (!mounted) return;
      context.pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('등록에 실패했어요: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isExecAsync = ref.watch(isExecutiveProvider);
    final isExec = isExecAsync.value ?? false;
    final isEditing = widget.editing != null;
    final canPickGroupBuy = isExec;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _submitting ? null : () => context.pop(),
        ),
        title: Text(isEditing ? '글 수정' : '글쓰기'),
        centerTitle: true,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12, top: 8, bottom: 8),
            child: FilledButton(
              onPressed: _submitting ? null : _submit,
              style: FilledButton.styleFrom(
                backgroundColor: AppPalette.navSelected,
                foregroundColor: Colors.white,
                minimumSize: const Size(64, 36),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
                textStyle: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              child: Text(isEditing ? '저장' : '등록'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  _KindChip(
                    label: PostKind.groupBuy.label,
                    selected: _kind == PostKind.groupBuy,
                    enabled: canPickGroupBuy && !isEditing,
                    onTap: () => setState(() => _kind = PostKind.groupBuy),
                  ),
                  const SizedBox(width: 8),
                  _KindChip(
                    label: PostKind.sharing.label,
                    selected: _kind == PostKind.sharing,
                    enabled: !isEditing,
                    onTap: () => setState(() => _kind = PostKind.sharing),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: TextField(
                controller: _title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
                decoration: InputDecoration(
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: '제목을 입력하세요',
                  hintStyle: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.6,
                    ),
                  ),
                ),
              ),
            ),
            Divider(height: 1, color: theme.colorScheme.outlineVariant),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: TextField(
                  controller: _body,
                  expands: true,
                  maxLines: null,
                  minLines: null,
                  keyboardType: TextInputType.multiline,
                  textAlignVertical: TextAlignVertical.top,
                  style: const TextStyle(fontSize: 15, height: 1.5),
                  decoration: InputDecoration(
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    hintText: '본문을 입력하세요\n‘부원 나눔’의 경우, 연락 수단과 본명을 남겨주세요.',
                    hintStyle: TextStyle(
                      fontSize: 15,
                      height: 1.5,
                      color: theme.colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.7,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            _ImageStrip(
              keepImages: _keepImages,
              newImages: _newImages,
              onPick: _pickImage,
              onRemoveKept: (img) => setState(() => _keepImages.remove(img)),
              onRemoveNew: (file) => setState(() => _newImages.remove(file)),
              publicUrl: ref.read(postsRepositoryProvider).publicUrl,
            ),
          ],
        ),
      ),
    );
  }
}

class _KindChip extends StatelessWidget {
  const _KindChip({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = !enabled
        ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)
        : selected
            ? theme.colorScheme.onSurface
            : theme.colorScheme.onSurfaceVariant;
    final border = !enabled
        ? theme.colorScheme.outlineVariant
        : selected
            ? theme.colorScheme.onSurface
            : theme.colorScheme.outline;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border.all(color: border, width: selected ? 1.5 : 1),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}

class _ImageStrip extends StatelessWidget {
  const _ImageStrip({
    required this.keepImages,
    required this.newImages,
    required this.onPick,
    required this.onRemoveKept,
    required this.onRemoveNew,
    required this.publicUrl,
  });

  final List<PostImage> keepImages;
  final List<File> newImages;
  final VoidCallback onPick;
  final void Function(PostImage) onRemoveKept;
  final void Function(File) onRemoveNew;
  final String Function(String) publicUrl;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 96,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        children: [
          _AddTile(onTap: onPick),
          for (final img in keepImages) ...[
            const SizedBox(width: 8),
            _Thumb(
              url: publicUrl(img.storagePath),
              onRemove: () => onRemoveKept(img),
            ),
          ],
          for (final file in newImages) ...[
            const SizedBox(width: 8),
            _Thumb(file: file, onRemove: () => onRemoveNew(file)),
          ],
        ],
      ),
    );
  }
}

class _AddTile extends StatelessWidget {
  const _AddTile({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 80,
        height: 80,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.add,
          size: 28,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({this.url, this.file, required this.onRemove});

  final String? url;
  final File? file;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 80,
      height: 80,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 80,
              height: 80,
              child: file != null
                  ? Image.file(file!, fit: BoxFit.cover)
                  : Image.network(
                      url!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        color: theme.colorScheme.surfaceContainerHighest,
                      ),
                    ),
            ),
          ),
          Positioned(
            top: -6,
            right: -6,
            child: InkResponse(
              onTap: onRemove,
              radius: 18,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, size: 14, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

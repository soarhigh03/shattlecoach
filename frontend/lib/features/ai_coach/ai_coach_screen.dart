import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

import 'ai_coach_models.dart';
import 'ai_coach_providers.dart';

class AiCoachScreen extends ConsumerStatefulWidget {
  const AiCoachScreen({super.key});

  @override
  ConsumerState<AiCoachScreen> createState() => _AiCoachScreenState();
}

class _AiCoachScreenState extends ConsumerState<AiCoachScreen> {
  File? _inputVideo;
  VideoPlayerController? _inputController;

  AiCoachAnalysis? _currentResult;
  VideoPlayerController? _outputController;

  bool _analyzing = false;

  @override
  void dispose() {
    _inputController?.dispose();
    _outputController?.dispose();
    super.dispose();
  }

  Future<void> _pickVideo() async {
    final picker = ImagePicker();
    final picked = await picker.pickVideo(source: ImageSource.gallery);
    if (picked == null) return;
    final file = File(picked.path);
    final controller = VideoPlayerController.file(file);
    await controller.initialize();
    await controller.setLooping(true);
    if (!mounted) {
      await controller.dispose();
      return;
    }
    final prevInput = _inputController;
    final prevOutput = _outputController;
    setState(() {
      _inputVideo = file;
      _inputController = controller;
      // Clear any prior result — the user picked a new clip.
      _currentResult = null;
      _outputController = null;
    });
    await prevInput?.dispose();
    await prevOutput?.dispose();
  }

  void _trimVideo() {
    // Trim flow is not built yet — the ML side will provide the cut points.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('영상 자르기는 곧 추가될 예정이에요.')),
    );
  }

  Future<void> _runCoaching() async {
    final input = _inputVideo;
    if (input == null) return;
    setState(() => _analyzing = true);

    // Algorithm pipeline isn't wired yet. Simulate latency so the UI states
    // (button busy → result populated) are exercisable.
    await Future<void>.delayed(const Duration(milliseconds: 800));

    final analysis = AiCoachAnalysis(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      createdAt: DateTime.now(),
      inputVideo: input,
      // outputVideo / feedback intentionally left null until the ML pipeline
      // produces them — UI renders placeholders in that case.
    );
    ref.read(analysesProvider.notifier).add(analysis);

    if (!mounted) return;
    setState(() {
      _currentResult = analysis;
      _analyzing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasVideo = _inputVideo != null;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Text(
                  'AI 코치',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '샤틀콕 부원만을 위한 온디바이스 AI 코치에요.\n'
                '업로드한 영상은 서버로 전송되지 않고, 기기에 남아있어요.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  height: 1.45,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              _PickerBox(
                controller: _inputController,
                onTap: _pickVideo,
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _SecondaryButton(
                      label: '영상 자르기',
                      enabled: hasVideo,
                      onPressed: _trimVideo,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _PrimaryButton(
                      label: 'AI 코칭 받기',
                      enabled: hasVideo && !_analyzing,
                      busy: _analyzing,
                      onPressed: _runCoaching,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _ResultBox(
                controller: _outputController,
                hasResult: _currentResult != null,
                analyzing: _analyzing,
              ),
              const SizedBox(height: 14),
              _FeedbackText(
                feedback: _currentResult?.feedback,
                hasResult: _currentResult != null,
                analyzing: _analyzing,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PickerBox extends StatelessWidget {
  const _PickerBox({required this.controller, required this.onTap});

  final VideoPlayerController? controller;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final placeholderBg = theme.colorScheme.surfaceContainerHighest;

    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Material(
        color: placeholderBg,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: controller != null && controller!.value.isInitialized
              ? _VideoTile(controller: controller!, onReplace: onTap)
              : Center(
                  child: Icon(
                    Icons.add,
                    size: 56,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
        ),
      ),
    );
  }
}

class _ResultBox extends StatelessWidget {
  const _ResultBox({
    required this.controller,
    required this.hasResult,
    required this.analyzing,
  });

  final VideoPlayerController? controller;
  final bool hasResult;
  final bool analyzing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: _resultBody(theme),
        ),
      ),
    );
  }

  Widget _resultBody(ThemeData theme) {
    if (analyzing) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
    if (controller != null && controller!.value.isInitialized) {
      return _VideoTile(controller: controller!);
    }
    return Center(
      child: Text(
        hasResult ? '분석 결과 영상 준비 중' : 'AI 코칭 결과가 여기에 표시돼요',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Single video surface that taps to toggle play/pause. Used for both the
/// picker preview and the result tile.
class _VideoTile extends StatefulWidget {
  const _VideoTile({required this.controller, this.onReplace});

  final VideoPlayerController controller;

  /// When non-null, long-press exposes a "replace" affordance.
  final VoidCallback? onReplace;

  @override
  State<_VideoTile> createState() => _VideoTileState();
}

class _VideoTileState extends State<_VideoTile> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTick);
  }

  @override
  void didUpdateWidget(covariant _VideoTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onTick);
      widget.controller.addListener(_onTick);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTick);
    super.dispose();
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  void _toggle() {
    final c = widget.controller;
    if (c.value.isPlaying) {
      c.pause();
    } else {
      c.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final showOverlay = !c.value.isPlaying;
    return GestureDetector(
      onTap: _toggle,
      onLongPress: widget.onReplace,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 16:9 frame; the picked video is cover-cropped to fill the box.
          FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: c.value.size.width,
              height: c.value.size.height,
              child: VideoPlayer(c),
            ),
          ),
          if (showOverlay)
            const ColoredBox(
              color: Color(0x33000000),
              child: Center(
                child: Icon(
                  Icons.play_arrow_rounded,
                  size: 56,
                  color: Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FeedbackText extends StatelessWidget {
  const _FeedbackText({
    required this.feedback,
    required this.hasResult,
    required this.analyzing,
  });

  final String? feedback;
  final bool hasResult;
  final bool analyzing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final String label;
    if (analyzing) {
      label = '분석 중...';
    } else if (feedback != null) {
      label = feedback!;
    } else if (hasResult) {
      label = '텍스트 피드백 준비 중';
    } else {
      label = 'text feedback';
    }
    return Text(
      label,
      style: theme.textTheme.bodyMedium?.copyWith(
        fontWeight: FontWeight.w700,
        color: theme.colorScheme.onSurface,
        height: 1.45,
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.onPressed,
    required this.enabled,
    required this.busy,
  });

  final String label;
  final VoidCallback onPressed;
  final bool enabled;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FilledButton(
      onPressed: enabled ? onPressed : null,
      style: FilledButton.styleFrom(
        backgroundColor: theme.colorScheme.onSurface,
        foregroundColor: theme.colorScheme.surface,
        disabledBackgroundColor:
            theme.colorScheme.onSurface.withValues(alpha: 0.35),
        disabledForegroundColor: theme.colorScheme.surface,
        minimumSize: const Size.fromHeight(56),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
      child: busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: Colors.white,
              ),
            )
          : Text(label),
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  const _SecondaryButton({
    required this.label,
    required this.onPressed,
    required this.enabled,
  });

  final String label;
  final VoidCallback onPressed;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FilledButton(
      onPressed: enabled ? onPressed : null,
      style: FilledButton.styleFrom(
        backgroundColor: theme.colorScheme.surfaceContainerHighest,
        foregroundColor: theme.colorScheme.onSurface,
        disabledBackgroundColor:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        disabledForegroundColor:
            theme.colorScheme.onSurface.withValues(alpha: 0.4),
        minimumSize: const Size.fromHeight(56),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
      child: Text(label),
    );
  }
}

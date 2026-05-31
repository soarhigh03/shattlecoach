import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

import '../../ml/shattle_ml.dart';
import '../../routing/app_router.dart';
import 'ai_coach_models.dart';
import 'ai_coach_providers.dart';
import 'ai_coach_widgets.dart';
import 'trim_screen.dart';

class AiCoachScreen extends ConsumerStatefulWidget {
  const AiCoachScreen({super.key});

  @override
  ConsumerState<AiCoachScreen> createState() => _AiCoachScreenState();
}

class _AiCoachScreenState extends ConsumerState<AiCoachScreen> {
  File? _inputVideo;
  VideoPlayerController? _inputController;

  /// Selected trim range (set via the trim screen). When non-null the input
  /// preview loops within `[_trimStart, _trimEnd]` and analysis is constrained
  /// to the same window.
  Duration? _trimStart;
  Duration? _trimEnd;

  AiCoachAnalysis? _currentResult;
  bool _analyzing = false;

  /// Progress / error string surfaced under the result box during analysis.
  String _statusMsg = '';

  @override
  void dispose() {
    _inputController?.removeListener(_enforceTrimLoop);
    _inputController?.dispose();
    super.dispose();
  }

  Future<void> _pickVideo() async {
    final picker = ImagePicker();
    final picked = await picker.pickVideo(source: ImageSource.gallery);
    if (picked == null) return;
    final file = File(picked.path);
    final controller = VideoPlayerController.file(file);
    await controller.initialize();
    // We run our own [_trimStart,_trimEnd] loop, so the controller must not
    // bounce back to 0 on its own.
    await controller.setLooping(false);
    if (!mounted) {
      await controller.dispose();
      return;
    }
    final prevInput = _inputController;
    prevInput?.removeListener(_enforceTrimLoop);
    controller.addListener(_enforceTrimLoop);
    setState(() {
      _inputVideo = file;
      _inputController = controller;
      // New clip → drop prior trim range, result, and any error state.
      _trimStart = null;
      _trimEnd = null;
      _currentResult = null;
      _statusMsg = '';
    });
    await prevInput?.dispose();

    // Drop the user straight into the trim screen — they almost always need
    // to pick the swing window before analysis. They can still re-trim later
    // via the "영상 자르기" button.
    if (mounted) {
      await _trimVideo();
    }
  }

  void _enforceTrimLoop() {
    final c = _inputController;
    final start = _trimStart;
    final end = _trimEnd;
    if (c == null || start == null || end == null) return;
    if (!c.value.isPlaying) return;
    if (c.value.position >= end) {
      c.seekTo(start);
    }
  }

  Future<void> _trimVideo() async {
    final file = _inputVideo;
    if (file == null) return;
    final result = await context.push<TrimResult>(
      AppRoute.aiCoachTrim,
      extra: TrimScreenArgs(
        file: file,
        initialStart: _trimStart,
        initialEnd: _trimEnd,
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      _trimStart = result.start;
      _trimEnd = result.end;
    });
    await _inputController?.seekTo(result.start);
  }

  Future<void> _onAnalyzePressed() async {
    if (_inputVideo == null || _analyzing) return;
    final stroke = await _showStrokeSheet();
    if (stroke == null) return;
    await _runAnalysis(stroke);
  }

  Future<String?> _showStrokeSheet() async {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => const _StrokeSheet(),
    );
  }

  Future<void> _runAnalysis(String stroke) async {
    final input = _inputVideo;
    if (input == null) return;
    setState(() {
      _analyzing = true;
      _statusMsg = '준비 중…';
      _currentResult = null;
    });

    try {
      final ShattleScore score = await ShattleMl.analyzeSwing(
        videoPath: input.path,
        stroke: stroke,
        startMs: _trimStart?.inMilliseconds,
        endMs: _trimEnd?.inMilliseconds,
        onStatus: (msg) {
          if (mounted) setState(() => _statusMsg = msg);
        },
      );
      if (!mounted) return;
      if (!score.isOk) {
        setState(() {
          _analyzing = false;
          _statusMsg = score.messageKo ?? '분석에 실패했어요.';
        });
        return;
      }
      final analysis = AiCoachAnalysis(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        createdAt: DateTime.now(),
        inputVideo: input,
        stroke: stroke,
        postureStars: score.postureStars,
        speedStars: score.speedStars,
        stepStars: score.stepStars,
        positives: score.positives,
        coachingParagraph: score.coachingParagraph,
        impactImage: score.annotatedImpactPngBase64 == null
            ? null
            : base64Decode(score.annotatedImpactPngBase64!),
      );
      ref.read(analysesProvider.notifier).add(analysis);
      setState(() {
        _currentResult = analysis;
        _analyzing = false;
        _statusMsg = '';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _analyzing = false;
        _statusMsg = '분석 중 오류가 발생했어요: $e';
      });
    }
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
              _PickerBox(controller: _inputController, onTap: _pickVideo),
              if (_trimStart != null && _trimEnd != null) ...[
                const SizedBox(height: 8),
                _TrimRangeLabel(start: _trimStart!, end: _trimEnd!),
              ],
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _SecondaryButton(
                      label: '영상 자르기',
                      enabled: hasVideo && !_analyzing,
                      onPressed: _trimVideo,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _PrimaryButton(
                      label: '영상 분석하기',
                      enabled: hasVideo && !_analyzing,
                      busy: _analyzing,
                      onPressed: _onAnalyzePressed,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _ResultSection(
                result: _currentResult,
                analyzing: _analyzing,
                statusMsg: _statusMsg,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Picker box ─────────────────────────────────────────────────────────────

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

class _VideoTile extends StatefulWidget {
  const _VideoTile({required this.controller, this.onReplace});

  final VideoPlayerController controller;
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

// ─── Result section ─────────────────────────────────────────────────────────

class _ResultSection extends StatelessWidget {
  const _ResultSection({
    required this.result,
    required this.analyzing,
    required this.statusMsg,
  });

  final AiCoachAnalysis? result;
  final bool analyzing;
  final String statusMsg;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (analyzing) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _ResultImageBox.placeholder(child: _Spinner()),
          const SizedBox(height: 12),
          Text(
            statusMsg.isEmpty ? '분석 중…' : statusMsg,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    final r = result;
    if (r == null) {
      // Either idle or surfacing the last error from a failed run.
      final isError = statusMsg.isNotEmpty;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ResultImageBox.placeholder(
            child: Center(
              child: Text(
                isError ? '분석을 다시 시도해 주세요' : 'AI 코칭 결과가 여기에 표시돼요',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          if (isError) ...[
            const SizedBox(height: 12),
            Text(
              statusMsg,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
                height: 1.4,
              ),
            ),
          ],
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ResultImageBox(image: r.impactImage),
        const SizedBox(height: 18),
        StarsBlock(analysis: r),
        const SizedBox(height: 20),
        if (r.positives.isNotEmpty) ...[
          const SectionHeader('잘한 점'),
          const SizedBox(height: 8),
          for (final p in r.positives) PositiveLine(p),
          const SizedBox(height: 20),
        ],
        const SectionHeader('코칭'),
        const SizedBox(height: 8),
        Text(
          r.coachingParagraph.isEmpty
              ? '코칭 문구를 생성하지 못했어요.'
              : r.coachingParagraph,
          style: theme.textTheme.bodyMedium?.copyWith(
            height: 1.55,
            color: theme.colorScheme.onSurface,
          ),
        ),
      ],
    );
  }
}

class _ResultImageBox extends StatelessWidget {
  const _ResultImageBox({required this.image}) : _placeholder = null;
  const _ResultImageBox.placeholder({required Widget child})
    : image = null,
      _placeholder = child;

  final Uint8List? image;
  final Widget? _placeholder;

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
          child: _body(theme),
        ),
      ),
    );
  }

  Widget _body(ThemeData theme) {
    if (_placeholder != null) return _placeholder;
    if (image != null) {
      return Image.memory(image!, fit: BoxFit.contain, gaplessPlayback: true);
    }
    return Center(
      child: Text(
        '임팩트 사진 준비 중',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();
  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      ),
    );
  }
}

// ─── Stroke selector bottom sheet ───────────────────────────────────────────

class _StrokeSheet extends StatelessWidget {
  const _StrokeSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              '어떤 동작을 분석할까요?',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '동작에 따라 평가하는 항목이 달라져요.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            for (final entry in kStrokeLabelKo.entries) ...[
              _StrokeOption(stroke: entry.key, label: entry.value),
              if (entry.key != kStrokeLabelKo.keys.last)
                const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}

class _StrokeOption extends StatelessWidget {
  const _StrokeOption({required this.stroke, required this.label});
  final String stroke;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).pop(stroke),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w700,
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
      ),
    );
  }
}

// ─── Buttons / labels ───────────────────────────────────────────────────────

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
        disabledBackgroundColor: theme.colorScheme.onSurface.withValues(
          alpha: 0.35,
        ),
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
        disabledBackgroundColor: theme.colorScheme.surfaceContainerHighest
            .withValues(alpha: 0.6),
        disabledForegroundColor: theme.colorScheme.onSurface.withValues(
          alpha: 0.4,
        ),
        minimumSize: const Size.fromHeight(56),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
      child: Text(label),
    );
  }
}

class _TrimRangeLabel extends StatelessWidget {
  const _TrimRangeLabel({required this.start, required this.end});

  final Duration start;
  final Duration end;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final len = end - start;
    return Row(
      children: [
        Icon(Icons.content_cut, size: 14, color: theme.colorScheme.primary),
        const SizedBox(width: 6),
        Text(
          '${_fmt(start)} → ${_fmt(end)}',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '(${(len.inMilliseconds / 1000).toStringAsFixed(1)}초)',
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  static String _fmt(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    final cs = (d.inMilliseconds ~/ 10) % 100;
    return '${two(m)}:${two(s)}.${two(cs)}';
  }
}

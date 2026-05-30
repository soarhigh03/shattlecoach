import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../ai_coach/ai_coach_models.dart';
import '../ai_coach/ai_coach_providers.dart';

class ReportScreen extends ConsumerStatefulWidget {
  const ReportScreen({super.key});

  @override
  ConsumerState<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends ConsumerState<ReportScreen> {
  /// First day of the month currently shown in the heatmap.
  late DateTime _month;

  /// Selected day inside [_month] (or null if nothing is tapped).
  DateTime? _selected;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
    _selected = DateTime(now.year, now.month, now.day);
  }

  void _shiftMonth(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta);
      _selected = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final byDay = ref.watch(analysesByDayProvider);
    final selectedAnalyses = _selected == null
        ? const <AiCoachAnalysis>[]
        : (byDay[_selected!] ?? const []);

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Text(
                  '리포트',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _MonthHeader(
                month: _month,
                onPrev: () => _shiftMonth(-1),
                onNext: () => _shiftMonth(1),
              ),
              const SizedBox(height: 12),
              _HeatmapCalendar(
                month: _month,
                countsByDay: {
                  for (final e in byDay.entries) e.key: e.value.length,
                },
                selected: _selected,
                onSelectDay: (d) {
                  setState(() {
                    _selected = (_selected == d) ? null : d;
                  });
                },
              ),
              const SizedBox(height: 20),
              _ColorLegend(),
              const SizedBox(height: 28),
              _DetailPanel(selected: _selected, analyses: selectedAnalyses),
            ],
          ),
        ),
      ),
    );
  }
}

class _MonthHeader extends StatelessWidget {
  const _MonthHeader({
    required this.month,
    required this.onPrev,
    required this.onNext,
  });

  final DateTime month;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        IconButton(
          onPressed: onPrev,
          icon: const Icon(Icons.chevron_left),
          tooltip: '이전 달',
        ),
        Expanded(
          child: Center(
            child: Text(
              '${month.year}년 ${month.month}월',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        IconButton(
          onPressed: onNext,
          icon: const Icon(Icons.chevron_right),
          tooltip: '다음 달',
        ),
      ],
    );
  }
}

class _HeatmapCalendar extends StatelessWidget {
  const _HeatmapCalendar({
    required this.month,
    required this.countsByDay,
    required this.selected,
    required this.onSelectDay,
  });

  final DateTime month;
  final Map<DateTime, int> countsByDay;
  final DateTime? selected;
  final ValueChanged<DateTime> onSelectDay;

  /// Use the same blue family as the bottom-nav selected color. Intensity
  /// ramps with count; 5+ analyses saturate.
  static const Color _heatBase = Color(0xFF0EA5E9);

  @override
  Widget build(BuildContext context) {
    final firstWeekday = month.weekday; // 1=Mon ... 7=Sun
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;

    // Leading blanks so day 1 lands under its weekday header.
    final leading = firstWeekday - 1;
    final cells = leading + daysInMonth;
    final rows = (cells / 7).ceil();

    return Column(
      children: [
        _WeekdayRow(),
        const SizedBox(height: 8),
        for (var r = 0; r < rows; r++) ...[
          Row(
            children: [
              for (var c = 0; c < 7; c++)
                Expanded(
                  child: _buildCell(context, r * 7 + c, leading, daysInMonth),
                ),
            ],
          ),
          if (r != rows - 1) const SizedBox(height: 6),
        ],
      ],
    );
  }

  Widget _buildCell(
    BuildContext context,
    int index,
    int leading,
    int daysInMonth,
  ) {
    final dayNum = index - leading + 1;
    if (dayNum < 1 || dayNum > daysInMonth) {
      return const AspectRatio(aspectRatio: 1, child: SizedBox.shrink());
    }
    final date = DateTime(month.year, month.month, dayNum);
    final count = countsByDay[date] ?? 0;
    final isSelected = selected != null && _sameDay(selected!, date);

    final theme = Theme.of(context);
    final bg = _bgForCount(count);
    final fg = count >= 3 ? Colors.white : theme.colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.all(2),
      child: AspectRatio(
        aspectRatio: 1,
        child: Material(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => onSelectDay(date),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: isSelected
                    ? Border.all(color: theme.colorScheme.onSurface, width: 2)
                    : Border.all(
                        color: theme.colorScheme.outlineVariant,
                        width: count == 0 ? 1 : 0,
                      ),
              ),
              alignment: Alignment.center,
              child: Text(
                '$dayNum',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Color _bgForCount(int count) {
    if (count <= 0) return Colors.transparent;
    // Step opacity: 1→0.18, 2→0.36, 3→0.55, 4→0.75, 5+→1.0
    final opacity = switch (count) {
      1 => 0.18,
      2 => 0.36,
      3 => 0.55,
      4 => 0.75,
      _ => 1.0,
    };
    return _heatBase.withValues(alpha: opacity);
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

class _WeekdayRow extends StatelessWidget {
  static const _labels = ['월', '화', '수', '목', '금', '토', '일'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        for (final l in _labels)
          Expanded(
            child: Center(
              child: Text(
                l,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ColorLegend extends StatelessWidget {
  static const _heatBase = _HeatmapCalendar._heatBase;
  static const _steps = [0.0, 0.18, 0.36, 0.55, 0.75, 1.0];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text(
          '적음',
          style: TextStyle(
            fontSize: 11,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 6),
        for (final s in _steps) ...[
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: s == 0
                  ? Colors.transparent
                  : _heatBase.withValues(alpha: s),
              borderRadius: BorderRadius.circular(3),
              border: s == 0
                  ? Border.all(color: theme.colorScheme.outlineVariant)
                  : null,
            ),
          ),
          const SizedBox(width: 3),
        ],
        const SizedBox(width: 3),
        Text(
          '많음',
          style: TextStyle(
            fontSize: 11,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _DetailPanel extends StatelessWidget {
  const _DetailPanel({required this.selected, required this.analyses});

  final DateTime? selected;
  final List<AiCoachAnalysis> analyses;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (selected == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text(
            '날짜를 선택하면 그날의 분석 결과를 볼 수 있어요.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    final label =
        '${selected!.year}.${_pad(selected!.month)}.${_pad(selected!.day)}';
    if (analyses.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 32),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Text(
                '이 날에는 분석 기록이 없어요.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '· 기록 ${analyses.length}개',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        for (var i = 0; i < analyses.length; i++) ...[
          _AnalysisCard(analysis: analyses[i], index: i + 1),
          if (i != analyses.length - 1) const SizedBox(height: 14),
        ],
      ],
    );
  }

  String _pad(int n) => n.toString().padLeft(2, '0');
}

class _AnalysisCard extends StatefulWidget {
  const _AnalysisCard({required this.analysis, required this.index});

  final AiCoachAnalysis analysis;
  final int index;

  @override
  State<_AnalysisCard> createState() => _AnalysisCardState();
}

class _AnalysisCardState extends State<_AnalysisCard> {
  VideoPlayerController? _controller;

  @override
  void initState() {
    super.initState();
    final out = widget.analysis.outputVideo ?? widget.analysis.inputVideo;
    final c = VideoPlayerController.file(out);
    c.initialize().then((_) {
      if (!mounted) {
        c.dispose();
        return;
      }
      setState(() => _controller = c);
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = widget.analysis;
    final feedback = a.feedback;
    final time = '${_pad(a.createdAt.hour)}:${_pad(a.createdAt.minute)}';

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '#${widget.index}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                time,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              if (a.outputVideo == null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '결과 영상 준비 중',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                color: theme.colorScheme.surfaceContainerHighest,
                child: _controller != null && _controller!.value.isInitialized
                    ? _PreviewSurface(controller: _controller!)
                    : const Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            feedback ?? '텍스트 피드백 준비 중',
            style: theme.textTheme.bodyMedium?.copyWith(
              height: 1.45,
              fontStyle: feedback == null ? FontStyle.italic : null,
              color: feedback == null
                  ? theme.colorScheme.onSurfaceVariant
                  : theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  String _pad(int n) => n.toString().padLeft(2, '0');
}

class _PreviewSurface extends StatefulWidget {
  const _PreviewSurface({required this.controller});

  final VideoPlayerController controller;

  @override
  State<_PreviewSurface> createState() => _PreviewSurfaceState();
}

class _PreviewSurfaceState extends State<_PreviewSurface> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTick);
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
                  size: 44,
                  color: Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

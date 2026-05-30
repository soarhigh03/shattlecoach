import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:video_player/video_player.dart';

/// Arguments handed to the trim screen via `GoRouter`'s `extra`.
class TrimScreenArgs {
  const TrimScreenArgs({
    required this.file,
    this.initialStart,
    this.initialEnd,
  });

  final File file;
  final Duration? initialStart;
  final Duration? initialEnd;
}

/// Selected trim range returned via `context.pop(TrimResult)`.
class TrimResult {
  const TrimResult({required this.start, required this.end});

  final Duration start;
  final Duration end;

  Duration get length => end - start;
}

class TrimScreen extends StatefulWidget {
  const TrimScreen({super.key, required this.args});
  final TrimScreenArgs args;

  @override
  State<TrimScreen> createState() => _TrimScreenState();
}

class _TrimScreenState extends State<TrimScreen> {
  VideoPlayerController? _controller;
  Duration _total = Duration.zero;
  Duration _start = Duration.zero;
  Duration _end = Duration.zero;

  /// While true, ignore controller ticks for trim-loop logic so the user's
  /// drag isn't fighting playback seeking.
  bool _scrubbing = false;

  static const Duration _minLen = Duration(milliseconds: 500);

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final c = VideoPlayerController.file(widget.args.file);
    await c.initialize();
    if (!mounted) {
      await c.dispose();
      return;
    }
    final total = c.value.duration;
    final start = _clamp(
      widget.args.initialStart ?? Duration.zero,
      Duration.zero,
      total - _minLen >= Duration.zero ? total - _minLen : Duration.zero,
    );
    final end = _clamp(widget.args.initialEnd ?? total, start + _minLen, total);
    c.addListener(_onTick);
    setState(() {
      _controller = c;
      _total = total;
      _start = start;
      _end = end;
    });
    await c.seekTo(start);
  }

  @override
  void dispose() {
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    super.dispose();
  }

  void _onTick() {
    final c = _controller;
    if (c == null) return;
    if (!_scrubbing && c.value.isPlaying && c.value.position >= _end) {
      c.seekTo(_start);
    }
    if (mounted) setState(() {});
  }

  void _togglePlay() {
    final c = _controller;
    if (c == null) return;
    if (c.value.isPlaying) {
      c.pause();
    } else {
      if (c.value.position < _start || c.value.position >= _end) {
        c.seekTo(_start);
      }
      c.play();
    }
  }

  void _setStart(Duration v) {
    final clamped = _clamp(v, Duration.zero, _end - _minLen);
    setState(() => _start = clamped);
    _controller?.seekTo(clamped);
  }

  void _setEnd(Duration v) {
    final clamped = _clamp(v, _start + _minLen, _total);
    setState(() => _end = clamped);
    // Show end frame so the user can confirm what they're cutting to.
    _controller?.seekTo(clamped - const Duration(milliseconds: 30));
  }

  void _save() {
    Navigator.of(context).pop(TrimResult(start: _start, end: _end));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = _controller;
    final ready = c != null && c.value.isInitialized;

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: const Text('영상 자르기'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => context.pop(),
          tooltip: '취소',
        ),
        actions: [
          TextButton(
            onPressed: ready ? _save : null,
            child: Text(
              '저장',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: ready
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ready
            ? _buildEditor(theme, c)
            : const Center(child: CircularProgressIndicator()),
      ),
    );
  }

  Widget _buildEditor(ThemeData theme, VideoPlayerController c) {
    final pos = c.value.position;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: ColoredBox(
                color: Colors.black,
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
                    if (!c.value.isPlaying)
                      Center(
                        child: IconButton(
                          iconSize: 56,
                          onPressed: _togglePlay,
                          icon: const Icon(
                            Icons.play_circle_fill,
                            color: Colors.white,
                          ),
                        ),
                      )
                    else
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _togglePlay,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Text(
                _fmt(pos),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              Text(
                _fmt(_total),
                style: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _TrimTrack(
            total: _total,
            start: _start,
            end: _end,
            playhead: pos,
            onStartChanged: _setStart,
            onEndChanged: _setEnd,
            onScrubStart: () {
              _scrubbing = true;
              _controller?.pause();
            },
            onScrubEnd: () => _scrubbing = false,
          ),
          const SizedBox(height: 20),
          _RangeSummary(start: _start, end: _end),
          const Spacer(),
          Row(
            children: [
              _ScrubIconButton(
                icon: Icons.skip_previous,
                tooltip: '시작점으로',
                onPressed: () => _controller?.seekTo(_start),
              ),
              const SizedBox(width: 6),
              _ScrubIconButton(
                icon: c.value.isPlaying ? Icons.pause : Icons.play_arrow,
                tooltip: c.value.isPlaying ? '일시정지' : '재생',
                onPressed: _togglePlay,
                emphasized: true,
              ),
              const SizedBox(width: 6),
              _ScrubIconButton(
                icon: Icons.skip_next,
                tooltip: '끝점으로',
                onPressed: () => _controller?.seekTo(
                  _end - const Duration(milliseconds: 30),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RangeSummary extends StatelessWidget {
  const _RangeSummary({required this.start, required this.end});

  final Duration start;
  final Duration end;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final len = end - start;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          _RangeChip(label: '시작', value: _fmt(start)),
          const SizedBox(width: 10),
          Icon(
            Icons.arrow_forward,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          _RangeChip(label: '끝', value: _fmt(end)),
          const Spacer(),
          Text(
            '${(len.inMilliseconds / 1000).toStringAsFixed(1)}초',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}

class _RangeChip extends StatelessWidget {
  const _RangeChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          value,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

class _ScrubIconButton extends StatelessWidget {
  const _ScrubIconButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.emphasized = false,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = emphasized
        ? theme.colorScheme.onSurface
        : theme.colorScheme.surfaceContainerHighest;
    final fg = emphasized
        ? theme.colorScheme.surface
        : theme.colorScheme.onSurface;
    return Expanded(
      child: SizedBox(
        height: 48,
        child: Material(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onPressed,
            child: Tooltip(
              message: tooltip,
              child: Center(child: Icon(icon, color: fg, size: 24)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Custom drag track. Width-bound, height ~72. Renders a base strip, dims the
/// regions outside the selected range, draws the playhead, and exposes two
/// draggable handles (start / end) with generous hit areas.
class _TrimTrack extends StatelessWidget {
  const _TrimTrack({
    required this.total,
    required this.start,
    required this.end,
    required this.playhead,
    required this.onStartChanged,
    required this.onEndChanged,
    required this.onScrubStart,
    required this.onScrubEnd,
  });

  final Duration total;
  final Duration start;
  final Duration end;
  final Duration playhead;
  final ValueChanged<Duration> onStartChanged;
  final ValueChanged<Duration> onEndChanged;
  final VoidCallback onScrubStart;
  final VoidCallback onScrubEnd;

  static const double _trackHeight = 72;
  static const double _handleWidth = 14;
  static const double _hitWidth = 40;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totalMs = total.inMilliseconds.toDouble();
    if (totalMs <= 0) {
      return const SizedBox(height: _trackHeight);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final usableWidth = constraints.maxWidth - _handleWidth * 2;
        if (usableWidth <= 0) return const SizedBox(height: _trackHeight);

        double xFor(Duration d) {
          final ratio = (d.inMilliseconds / totalMs).clamp(0.0, 1.0);
          return _handleWidth + ratio * usableWidth;
        }

        Duration durFor(double x) {
          final ratio = ((x - _handleWidth) / usableWidth).clamp(0.0, 1.0);
          return Duration(milliseconds: (ratio * totalMs).round());
        }

        final startX = xFor(start);
        final endX = xFor(end);
        final playX = xFor(playhead);

        return SizedBox(
          height: _trackHeight,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Base strip (full track background).
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              // Faint tick marks to suggest a timeline.
              Positioned.fill(
                child: CustomPaint(
                  painter: _TickPainter(
                    color: theme.colorScheme.outlineVariant,
                  ),
                ),
              ),
              // Dim outside the selected range.
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: startX,
                child: const _Dim(),
              ),
              Positioned(
                left: endX,
                right: 0,
                top: 0,
                bottom: 0,
                child: const _Dim(),
              ),
              // Selected range outline.
              Positioned(
                left: startX,
                top: 0,
                bottom: 0,
                width: (endX - startX).clamp(0.0, double.infinity),
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(
                          color: theme.colorScheme.primary,
                          width: 3,
                        ),
                        bottom: BorderSide(
                          color: theme.colorScheme.primary,
                          width: 3,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // Playhead (only meaningful when inside the range).
              if (playX >= startX && playX <= endX)
                Positioned(
                  left: playX - 1,
                  top: -4,
                  bottom: -4,
                  width: 2,
                  child: IgnorePointer(child: Container(color: Colors.white)),
                ),
              // Left handle.
              Positioned(
                left: startX - _hitWidth / 2,
                top: -4,
                bottom: -4,
                width: _hitWidth,
                child: _Handle(
                  alignment: Alignment.center,
                  onPanStart: (_) => onScrubStart(),
                  onPanUpdate: (d) {
                    final nx = startX + d.delta.dx;
                    onStartChanged(durFor(nx));
                  },
                  onPanEnd: (_) => onScrubEnd(),
                  color: theme.colorScheme.primary,
                ),
              ),
              // Right handle.
              Positioned(
                left: endX - _hitWidth / 2,
                top: -4,
                bottom: -4,
                width: _hitWidth,
                child: _Handle(
                  alignment: Alignment.center,
                  onPanStart: (_) => onScrubStart(),
                  onPanUpdate: (d) {
                    final nx = endX + d.delta.dx;
                    onEndChanged(durFor(nx));
                  },
                  onPanEnd: (_) => onScrubEnd(),
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Dim extends StatelessWidget {
  const _Dim();

  @override
  Widget build(BuildContext context) {
    return const IgnorePointer(child: ColoredBox(color: Color(0x66000000)));
  }
}

class _Handle extends StatelessWidget {
  const _Handle({
    required this.alignment,
    required this.onPanStart,
    required this.onPanUpdate,
    required this.onPanEnd,
    required this.color,
  });

  final Alignment alignment;
  final GestureDragStartCallback onPanStart;
  final GestureDragUpdateCallback onPanUpdate;
  final GestureDragEndCallback onPanEnd;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: onPanStart,
      onPanUpdate: onPanUpdate,
      onPanEnd: onPanEnd,
      child: Align(
        alignment: alignment,
        child: Container(
          width: 14,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 4,
                offset: Offset(0, 1),
              ),
            ],
          ),
          child: const Center(
            child: SizedBox(
              width: 3,
              height: 28,
              child: ColoredBox(color: Color(0x66FFFFFF)),
            ),
          ),
        ),
      ),
    );
  }
}

class _TickPainter extends CustomPainter {
  _TickPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const ticks = 12;
    for (var i = 1; i < ticks; i++) {
      final x = size.width * i / ticks;
      canvas.drawLine(
        Offset(x, size.height * 0.25),
        Offset(x, size.height * 0.75),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TickPainter old) => old.color != color;
}

Duration _clamp(Duration v, Duration lo, Duration hi) {
  if (v < lo) return lo;
  if (v > hi) return hi;
  return v;
}

String _fmt(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final ms = d.inMilliseconds.abs();
  final m = (ms ~/ 60000);
  final s = (ms ~/ 1000) % 60;
  final cs = (ms ~/ 10) % 100;
  return '${two(m)}:${two(s)}.${two(cs)}';
}

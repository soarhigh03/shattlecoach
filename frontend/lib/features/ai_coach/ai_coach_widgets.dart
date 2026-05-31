import 'package:flutter/material.dart';

import 'ai_coach_models.dart';

/// Vertical stack of star rows for the per-axis posture / speed / step
/// ratings. Skips axes the ML pipeline didn't score (null). Used by the AI
/// coach result screen and the expanded report card.
class StarsBlock extends StatelessWidget {
  const StarsBlock({super.key, required this.analysis});
  final AiCoachAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    void add(String label, int? stars) {
      if (stars == null) return;
      rows.add(StarRow(label: label, stars: stars));
    }

    add('자세', analysis.postureStars);
    add('스윙 속도', analysis.speedStars);
    add('풋워크', analysis.stepStars);

    if (rows.isEmpty) {
      final theme = Theme.of(context);
      return Text(
        '평가할 수 있는 축이 없었어요.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          rows[i],
          if (i != rows.length - 1) const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class StarRow extends StatelessWidget {
  const StarRow({super.key, required this.label, required this.stars});
  final String label;
  final int stars;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 76,
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ),
        for (var i = 1; i <= 5; i++) ...[
          Icon(
            i <= stars ? Icons.star_rounded : Icons.star_outline_rounded,
            size: 22,
            color: i <= stars
                ? theme.colorScheme.secondary
                : theme.colorScheme.outlineVariant,
          ),
          if (i != 5) const SizedBox(width: 2),
        ],
        const SizedBox(width: 8),
        Text(
          '$stars / 5',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// One "잘한 점" bullet (✓ + line of text).
class PositiveLine extends StatelessWidget {
  const PositiveLine(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.check_circle,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                height: 1.45,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w800,
        color: theme.colorScheme.onSurface,
      ),
    );
  }
}

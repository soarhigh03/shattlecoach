import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ai_coach_models.dart';

/// In-memory log of every analysis the user has produced this session.
/// Newest first.
class AnalysesNotifier extends StateNotifier<List<AiCoachAnalysis>> {
  AnalysesNotifier() : super(const []);

  void add(AiCoachAnalysis a) {
    state = [a, ...state];
  }

  void replace(AiCoachAnalysis a) {
    state = [
      for (final existing in state)
        if (existing.id == a.id) a else existing,
    ];
  }
}

final analysesProvider =
    StateNotifierProvider<AnalysesNotifier, List<AiCoachAnalysis>>(
      (_) => AnalysesNotifier(),
    );

/// Analyses grouped by calendar day. Used by the report heatmap and the
/// per-day detail panel.
final analysesByDayProvider =
    Provider<Map<DateTime, List<AiCoachAnalysis>>>((ref) {
  final all = ref.watch(analysesProvider);
  final map = <DateTime, List<AiCoachAnalysis>>{};
  for (final a in all) {
    map.putIfAbsent(a.day, () => []).add(a);
  }
  return map;
});

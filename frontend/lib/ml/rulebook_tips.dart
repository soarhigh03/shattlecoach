// Dart twin of scripts/rulebook.py — rulebook tip-bank selection + deterministic
// fallback. The LLM only STITCHES the sentences selected here; it never
// free-generates. With the LLM off/unavailable, composeFallback() emits the
// selected sentences verbatim. Selection key: stroke -> axis -> criterion/star
// -> severity bucket. MUST stay behaviourally equivalent to the Python twin.

import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;

// Canonical posture-criterion order (matches kCriteriaNames in rule_scorer.dart).
const List<String> kCriteriaOrder = <String>[
  'peak_wrist_above_shoulder',
  'elbow_extension_>=160deg',
  'hip_rotation_>=20deg',
  'knees_bent_at_prep',
]; // head_stable (C5) removed 2026-05-31
const double kMajorFailProb = 0.30;

/// One selected coaching sentence.
class RulebookSentence {
  final String axis; // 'posture' | 'speed' | 'step' | 'summary'
  final String criterion; // criterion name, axis name, or 'all_good'
  final String
  severity; // 'pass' | 'minor_fail' | 'major_fail' | 'na' | 'starN'
  final String text;
  RulebookSentence(this.axis, this.criterion, this.severity, this.text);
  Map<String, dynamic> toJson() => <String, dynamic>{
    'axis': axis,
    'criterion': criterion,
    'severity': severity,
    'text': text,
  };
}

class RulebookTips {
  final Map<String, dynamic> _cfg;
  RulebookTips(this._cfg);

  static Future<RulebookTips> load() async {
    final Map<String, dynamic> j =
        jsonDecode(await rootBundle.loadString('assets/rulebook_tips.json'))
            as Map<String, dynamic>;
    return RulebookTips(j);
  }

  String get naDefault => (_cfg['na_default'] as String?) ?? '이 항목은 측정하지 못했어요.';
  String get allGoodDefault =>
      (_cfg['all_good_default'] as String?) ?? '전반적으로 안정적인 자세예요. 지금 폼을 유지하세요.';

  List<String> forbiddenKeywords(String stroke) {
    final Map<String, dynamic> g =
        (_cfg['guardrails'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final Map<String, dynamic>? entry = g[stroke] as Map<String, dynamic>?;
    final List<dynamic> kw =
        (entry?['forbidden_keywords'] as List<dynamic>?) ?? const <dynamic>[];
    return kw.map((dynamic e) => e.toString()).toList();
  }

  /// severity(c): 'na' | 'pass' | 'minor_fail' | 'major_fail'.
  static String criterionSeverity(Map<String, dynamic> c) {
    if (c['measurement'] == null || c['pass'] == null) return 'na';
    if (c['pass'] == true) return 'pass';
    final double prob = ((c['probability'] as num?)?.toDouble()) ?? 0.5;
    return prob < kMajorFailProb ? 'major_fail' : 'minor_fail';
  }

  Map<String, dynamic> _strokeEntry(String stroke) {
    final Map<String, dynamic> strokes =
        (_cfg['strokes'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    return (strokes[stroke] as Map<String, dynamic>?) ??
        (strokes['unknown_ood'] as Map<String, dynamic>?) ??
        <String, dynamic>{};
  }

  // [idx] picks ONE variant from the bucket (seeded per clip), never two.
  String? _postureText(
    String stroke,
    String criterion,
    String severity, [
    int idx = 0,
  ]) {
    final Map<String, dynamic> entry = _strokeEntry(stroke);
    final Map<String, dynamic>? posture =
        entry['posture'] as Map<String, dynamic>?;
    final Map<String, dynamic>? crit =
        posture?[criterion] as Map<String, dynamic>?;
    final List<dynamic>? bucket = crit?[severity] as List<dynamic>?;
    if (bucket != null && bucket.isNotEmpty)
      return bucket[idx % bucket.length].toString();
    return null;
  }

  String? _axisText(String stroke, String axis, int star, [int idx = 0]) {
    final Map<String, dynamic> entry = _strokeEntry(stroke);
    final Map<String, dynamic>? axisMap = entry[axis] as Map<String, dynamic>?;
    final List<dynamic>? bucket = axisMap?['$star'] as List<dynamic>?;
    if (bucket != null && bucket.isNotEmpty)
      return bucket[idx % bucket.length].toString();
    return null;
  }

  /// Ordered selection from the bank, respecting axes_evaluated. Surfaces
  /// failing/NA posture criteria + non-average speed/step. Empty → all_good.
  List<RulebookSentence> selectSentences(
    Map<String, dynamic> payload, {
    int seed = 0,
  }) {
    final String stroke =
        ((payload['stroke'] as Map<String, dynamic>?)?['label']?.toString()) ??
        'unknown_ood';
    final List<String> axesEval =
        ((payload['axes_evaluated'] as List<dynamic>?) ??
                const <dynamic>['posture', 'speed', 'step'])
            .map((dynamic e) => e.toString())
            .toList();
    final List<RulebookSentence> out = <RulebookSentence>[];

    if (axesEval.contains('posture')) {
      final Map<String, Map<String, dynamic>> byName =
          <String, Map<String, dynamic>>{};
      for (final dynamic c
          in (payload['posture_criteria'] as List<dynamic>?) ??
              const <dynamic>[]) {
        final Map<String, dynamic> cm = c as Map<String, dynamic>;
        byName[cm['name']?.toString() ?? ''] = cm;
      }
      for (int pos = 0; pos < kCriteriaOrder.length; pos++) {
        final String name = kCriteriaOrder[pos];
        final Map<String, dynamic>? c = byName[name];
        if (c == null) continue;
        final String sev = criterionSeverity(c);
        // pass → positives; na (joint not tracked) → say nothing (confusing/repetitive).
        if (sev == 'pass' || sev == 'na') continue;
        final int idx =
            seed + pos; // per-criterion offset; one variant per cell
        final String? text =
            _postureText(stroke, name, sev, idx) ??
            _postureText(stroke, name, 'major_fail', idx);
        if (text != null) out.add(RulebookSentence('posture', name, sev, text));
      }
    }

    for (final List<String> axisKey in <List<String>>[
      <String>['speed', 'speed_stars'],
      <String>['step', 'step_stars'],
    ]) {
      final String axis = axisKey[0];
      if (!axesEval.contains(axis)) continue;
      final int? star = (payload[axisKey[1]] as num?)?.toInt();
      if (star == null || star >= 3)
        continue; // corrections only for 1-2; 4-5 → positives
      final String? text = _axisText(stroke, axis, star, seed + star);
      if (text != null)
        out.add(RulebookSentence(axis, axis, 'star$star', text));
    }

    if (out.isEmpty) {
      out.add(RulebookSentence('summary', 'all_good', 'pass', allGoodDefault));
    }
    return out;
  }

  /// "Doing well" notes for PASSING evaluated criteria + good (4-5★) speed/step.
  /// Surfaced separately so the user always sees what they did right.
  List<RulebookSentence> selectPositives(
    Map<String, dynamic> payload, {
    int seed = 0,
  }) {
    final String stroke =
        ((payload['stroke'] as Map<String, dynamic>?)?['label']?.toString()) ??
        'unknown_ood';
    final List<String> axesEval =
        ((payload['axes_evaluated'] as List<dynamic>?) ??
                const <dynamic>['posture', 'speed', 'step'])
            .map((dynamic e) => e.toString())
            .toList();
    final List<RulebookSentence> out = <RulebookSentence>[];
    if (axesEval.contains('posture')) {
      final Map<String, Map<String, dynamic>> byName =
          <String, Map<String, dynamic>>{};
      for (final dynamic c
          in (payload['posture_criteria'] as List<dynamic>?) ??
              const <dynamic>[]) {
        final Map<String, dynamic> cm = c as Map<String, dynamic>;
        byName[cm['name']?.toString() ?? ''] = cm;
      }
      for (int pos = 0; pos < kCriteriaOrder.length; pos++) {
        final String name = kCriteriaOrder[pos];
        final Map<String, dynamic>? c = byName[name];
        if (c == null || criterionSeverity(c) != 'pass') continue;
        final String? text = _postureText(stroke, name, 'pass', seed + pos);
        if (text != null)
          out.add(RulebookSentence('posture', name, 'pass', text));
      }
    }
    for (final List<String> axisKey in <List<String>>[
      <String>['speed', 'speed_stars'],
      <String>['step', 'step_stars'],
    ]) {
      final String axis = axisKey[0];
      if (!axesEval.contains(axis)) continue;
      final int? star = (payload[axisKey[1]] as num?)?.toInt();
      if (star == null || star < 4) continue;
      final String? text = _axisText(stroke, axis, star, seed + star);
      if (text != null)
        out.add(RulebookSentence(axis, axis, 'star$star', text));
    }
    return out;
  }

  /// Deterministic paragraph = selected bank sentences joined verbatim.
  static String composeFallback(List<RulebookSentence> sentences) {
    return sentences
        .map((RulebookSentence s) => s.text.trim())
        .where((String t) => t.isNotEmpty)
        .join(' ');
  }

  /// Forbidden tokens that appear in [smoothed] but NOT already in the
  /// deterministic [fallback] — i.e. newly introduced by the LLM. If non-empty,
  /// the smoothed paragraph must be discarded in favour of the fallback.
  /// Case-insensitive substring match. Twin of rulebook.py introduced_forbidden.
  static List<String> introducedForbidden(
    String smoothed,
    String fallback,
    List<String> forbidden,
  ) {
    final String sl = smoothed.toLowerCase();
    final String fl = fallback.toLowerCase();
    return forbidden
        .where(
          (String k) =>
              sl.contains(k.toLowerCase()) && !fl.contains(k.toLowerCase()),
        )
        .toList();
  }
}

/// Build the coaching block for [payload] — deterministic, no LLM. Each bank
/// sentence is a complete polite sentence, so the verbatim join already reads
/// as one natural paragraph. Mirrors what the server used to call `rulebook`.
/// Returns {sentences, positives, paragraph, source:'rulebook'}.
Map<String, dynamic> composeCoaching(
  RulebookTips bank,
  Map<String, dynamic> payload, {
  int seed = 0,
}) {
  final List<RulebookSentence> sentences = bank.selectSentences(
    payload,
    seed: seed,
  );
  final List<RulebookSentence> positives = bank.selectPositives(
    payload,
    seed: seed,
  );
  return <String, dynamic>{
    'sentences': sentences.map((RulebookSentence s) => s.toJson()).toList(),
    'positives': positives.map((RulebookSentence s) => s.toJson()).toList(),
    'paragraph': RulebookTips.composeFallback(sentences),
    'source': 'rulebook',
  };
}

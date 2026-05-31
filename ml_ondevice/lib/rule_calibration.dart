// Dart port of experiments/demo_v4/score_clip.py:apply_per_class_thresholds().
// Re-evaluates the 5 posture criteria against PER-STROKE calibrated thresholds
// (assets/rule_calibration.json) instead of the synth defaults baked into
// rule_scorer.dart. This is what makes the user-selected stroke actually drive
// the posture pass/fail decision (점5). Offline twin of the server path.

import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/services.dart' show rootBundle;

import 'rule_scorer.dart' show CriterionResult;

class RuleCalibration {
  final Map<String, dynamic> _cfg;
  RuleCalibration(this._cfg);

  static Future<RuleCalibration> load() async {
    final Map<String, dynamic> j =
        jsonDecode(await rootBundle.loadString('assets/rule_calibration.json'))
            as Map<String, dynamic>;
    return RuleCalibration(j);
  }

  /// Returns a new criteria list re-scored against the thresholds for
  /// [predictedClass] (falls back to the global table when the class is unknown
  /// or [isOod] is extreme). measurement==null criteria pass through untouched.
  /// Also returns the source label via [outSource] if provided.
  List<CriterionResult> apply(
    List<CriterionResult> criteria,
    String predictedClass, {
    bool isOod = false,
    double mdistRatio = 0.0,
    void Function(String source)? outSource,
  }) {
    final Map<String, dynamic> perClass = (_cfg['per_class'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final Map<String, dynamic> global = (_cfg['global'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final bool extreme = isOod && mdistRatio > 1e6;
    Map<String, dynamic> thrs;
    String source;
    if (perClass.containsKey(predictedClass) && !extreme) {
      thrs = perClass[predictedClass] as Map<String, dynamic>;
      source = 'per-class ($predictedClass)';
    } else {
      thrs = global;
      source = 'global';
    }
    outSource?.call(source);

    final List<CriterionResult> out = <CriterionResult>[];
    for (final CriterionResult c in criteria) {
      if (c.measurement == null || !thrs.containsKey(c.name)) {
        out.add(c);
        continue;
      }
      final Map<String, dynamic> t = thrs[c.name] as Map<String, dynamic>;
      final double thrV = (t['threshold'] as num).toDouble();
      final String dir = (t['direction'] as String?) ?? '>=';
      final double m = c.measurement!;
      final bool passed = dir == '>=' ? (m >= thrV) : (m < thrV);
      final double margin = dir == '>=' ? (m - thrV) : (thrV - m);
      final double scale = math.max(thrV.abs() * 0.2, 1e-3);
      final double prob = 1.0 / (1.0 + math.exp(-margin / scale));
      out.add(CriterionResult(
        name: c.name, pass: passed, measurement: m, unit: c.unit,
        threshold: thrV, probability: prob, reasonNa: c.reasonNa,
      ));
    }
    return out;
  }
}

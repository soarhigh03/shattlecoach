// Dart port of experiments/demo_v4/score_clip.py apply_stroke_axis_filter().
// Reads assets/stroke_axes.json and nulls out irrelevant axes per stroke.

import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;

class AxisFilter {
  final Map<String, dynamic> _cfg;
  AxisFilter(this._cfg);

  static Future<AxisFilter> load() async {
    final Map<String, dynamic> j =
        jsonDecode(await rootBundle.loadString('assets/stroke_axes.json'))
            as Map<String, dynamic>;
    return AxisFilter(j);
  }

  /// Mutates [payload] to null-out dropped axes + filter coaching_tips.
  /// Also adds 'axes_evaluated' (list) and 'axes_dropped' ({axis: reason}) fields.
  void apply(Map<String, dynamic> payload) {
    const List<String> all = <String>['posture', 'speed', 'step'];
    final String label =
        (payload['stroke'] as Map<String, dynamic>?)?['label']?.toString() ??
        '';
    Map<String, dynamic>? entry = _cfg[label] as Map<String, dynamic>?;
    entry ??= _cfg['unknown_ood'] as Map<String, dynamic>?;
    entry ??= <String, dynamic>{'axes': all, 'reasons': <String, dynamic>{}};

    final List<String> relevant = ((entry['axes'] as List<dynamic>?) ?? all)
        .map((dynamic e) => e.toString())
        .toList();
    final Map<String, String> reasons = <String, String>{
      for (final MapEntry<String, dynamic> e
          in ((entry['reasons'] as Map<String, dynamic>?) ??
                  <String, dynamic>{})
              .entries)
        e.key: e.value.toString(),
    };

    // Dropped axes: OMIT the keys entirely (no N/A shown). The reason still lives
    // in axes_dropped for optional display.
    for (final String axis in all) {
      if (relevant.contains(axis)) continue;
      payload.remove('${axis}_stars');
      payload.remove('${axis}_reason');
    }
    final List<dynamic> tips =
        (payload['coaching_tips'] as List<dynamic>?) ?? <dynamic>[];
    payload['coaching_tips'] = tips.where((dynamic t) {
      final String? a = (t as Map<String, dynamic>)['axis'] as String?;
      return a != null && relevant.contains(a);
    }).toList();
    payload['axes_evaluated'] = relevant;
    payload['axes_dropped'] = <String, String>{
      for (final String a in all)
        if (!relevant.contains(a))
          a: reasons[a] ?? '$a not relevant for $label',
    };
  }
}

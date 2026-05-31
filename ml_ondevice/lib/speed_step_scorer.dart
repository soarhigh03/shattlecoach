// Dart port of scripts/score_swing_speed.py + scripts/score_step.py.
// Looks up measurements against quantile tables bundled as assets.

import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/services.dart' show rootBundle;
import 'pose_extractor.dart' show kCocoNames;

final Map<String, int> _idx = <String, int>{
  for (int i = 0; i < kCocoNames.length; i++) kCocoNames[i]: i,
};

class AxisScoreResult {
  final int star;            // 1-5
  final double measurement;  // raw input measurement
  final double percentile;   // 0-100 lookup in BST
  final String calibrationSource;
  final Map<String, dynamic> details;
  AxisScoreResult({
    required this.star, required this.measurement, required this.percentile,
    required this.calibrationSource, this.details = const <String, dynamic>{},
  });
}

class PercentileTable {
  final List<double> quantilesPct;
  final List<double> quantilesValue;
  PercentileTable(this.quantilesPct, this.quantilesValue);

  /// Returns percentile (0-100) for a measurement value.
  double percentileOf(double value) {
    if (quantilesValue.isEmpty) return 50.0;
    // Find the insertion point in sorted quantiles
    int lo = 0, hi = quantilesValue.length;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (quantilesValue[mid] < value) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo >= quantilesValue.length) return 100.0;
    if (lo == 0) return quantilesPct.first;
    // Linear interpolate between quantiles[lo-1] and quantiles[lo]
    final double lowV = quantilesValue[lo - 1];
    final double highV = quantilesValue[lo];
    final double lowP = quantilesPct[lo - 1];
    final double highP = quantilesPct[lo];
    if (highV == lowV) return lowP;
    final double t = (value - lowV) / (highV - lowV);
    return lowP + t * (highP - lowP);
  }
}

PercentileTable _fromJson(Map<String, dynamic> j) {
  return PercentileTable(
    (j['quantiles_pct'] as List<dynamic>).map<double>((dynamic v) => (v as num).toDouble()).toList(),
    (j['quantiles_value'] as List<dynamic>).map<double>((dynamic v) => (v as num).toDouble()).toList(),
  );
}

class BstPercentiles {
  final PercentileTable speed;
  final PercentileTable step;
  BstPercentiles({required this.speed, required this.step});

  static Future<BstPercentiles> load() async {
    final Map<String, dynamic> s = jsonDecode(await rootBundle.loadString('assets/bst_speed_percentiles.json'))
        as Map<String, dynamic>;
    final Map<String, dynamic> k = jsonDecode(await rootBundle.loadString('assets/bst_step_percentiles.json'))
        as Map<String, dynamic>;
    return BstPercentiles(speed: _fromJson(s), step: _fromJson(k));
  }
}

int _percentileToStar(double p) {
  if (p >= 80) return 5;
  if (p >= 60) return 4;
  if (p >= 40) return 3;
  if (p >= 20) return 2;
  return 1;
}

// ---- swing speed ----

class _SpeedFeatures {
  final double maxVelocityNorm;
  final double meanVelocityAtImpact;
  final int impactFrame;
  _SpeedFeatures(this.maxVelocityNorm, this.meanVelocityAtImpact, this.impactFrame);
}

String _dominantWrist(List<List<List<double>>> kpts) {
  double rDisp = 0, lDisp = 0;
  for (int i = 1; i < kpts.length; i++) {
    final double rdx = kpts[i][_idx['right_wrist']!][0] - kpts[i-1][_idx['right_wrist']!][0];
    final double rdy = kpts[i][_idx['right_wrist']!][1] - kpts[i-1][_idx['right_wrist']!][1];
    rDisp += math.sqrt(rdx*rdx + rdy*rdy);
    final double ldx = kpts[i][_idx['left_wrist']!][0] - kpts[i-1][_idx['left_wrist']!][0];
    final double ldy = kpts[i][_idx['left_wrist']!][1] - kpts[i-1][_idx['left_wrist']!][1];
    lDisp += math.sqrt(ldx*ldx + ldy*ldy);
  }
  return rDisp >= lDisp ? 'right' : 'left';
}

double _bodyScale(List<List<List<double>>> kpts) {
  double total = 0;
  for (int i = 0; i < kpts.length; i++) {
    final double shX = (kpts[i][_idx['left_shoulder']!][0] + kpts[i][_idx['right_shoulder']!][0]) / 2;
    final double shY = (kpts[i][_idx['left_shoulder']!][1] + kpts[i][_idx['right_shoulder']!][1]) / 2;
    final double hpX = (kpts[i][_idx['left_hip']!][0] + kpts[i][_idx['right_hip']!][0]) / 2;
    final double hpY = (kpts[i][_idx['left_hip']!][1] + kpts[i][_idx['right_hip']!][1]) / 2;
    total += math.sqrt((shX - hpX)*(shX - hpX) + (shY - hpY)*(shY - hpY));
  }
  return total / kpts.length;
}

_SpeedFeatures _wristVelocityFeatures(List<List<List<double>>> kpts) {
  if (kpts.length < 2) return _SpeedFeatures(0, 0, 0);
  final String dom = _dominantWrist(kpts);
  final double body = math.max(_bodyScale(kpts), 1e-6);
  // impact = argmin of wrist_y
  double minY = double.infinity; int impact = 0;
  final int wristIdx = _idx['${dom}_wrist']!;
  for (int i = 0; i < kpts.length; i++) {
    if (kpts[i][wristIdx][1] < minY) { minY = kpts[i][wristIdx][1]; impact = i; }
  }
  final List<double> speeds = <double>[];
  for (int i = 1; i < kpts.length; i++) {
    final double dx = kpts[i][wristIdx][0] - kpts[i-1][wristIdx][0];
    final double dy = kpts[i][wristIdx][1] - kpts[i-1][wristIdx][1];
    speeds.add(math.sqrt(dx*dx + dy*dy) / body);
  }
  double maxV = 0;
  for (final double s in speeds) {
    if (s > maxV) maxV = s;
  }
  final int lo = math.max(0, impact - 1);
  final int hi = math.min(speeds.length, impact + 2);
  double meanImpact = 0;
  if (hi > lo) {
    for (int i = lo; i < hi; i++) {
      meanImpact += speeds[i];
    }
    meanImpact /= (hi - lo);
  }
  return _SpeedFeatures(maxV, meanImpact, impact);
}

AxisScoreResult scoreSpeed(List<List<List<double>>> kpts, PercentileTable speedTable) {
  final _SpeedFeatures f = _wristVelocityFeatures(kpts);
  final double p = speedTable.percentileOf(f.maxVelocityNorm);
  return AxisScoreResult(
    star: _percentileToStar(p),
    measurement: f.maxVelocityNorm,
    percentile: p,
    calibrationSource: 'bst_speed_percentiles.json',
    details: <String, dynamic>{
      'max_velocity_norm': f.maxVelocityNorm,
      'mean_velocity_at_impact': f.meanVelocityAtImpact,
      'impact_frame': f.impactFrame,
    },
  );
}

// ---- step ----

int _countPeaks(List<double> speeds, double minProm) {
  if (speeds.length < 3) return 0;
  double mx = 0;
  for (final double s in speeds) {
    if (s > mx) mx = s;
  }
  final double thr = minProm * (mx + 1e-9);
  int peaks = 0;
  for (int i = 1; i < speeds.length - 1; i++) {
    if (speeds[i] > speeds[i-1] && speeds[i] > speeds[i+1] && speeds[i] > thr) peaks++;
  }
  return peaks;
}

AxisScoreResult scoreStep(List<List<List<double>>> kpts, PercentileTable stepTable) {
  if (kpts.length < 2) {
    return AxisScoreResult(star: 1, measurement: 0, percentile: 0,
        calibrationSource: 'bst_step_percentiles.json',
        details: const <String, dynamic>{'total_foot_path_norm': 0, 'step_count': 0, 'hip_x_shift_norm': 0});
  }
  final double body = math.max(_bodyScale(kpts), 1e-6);
  final List<double> laS = <double>[]; final List<double> raS = <double>[];
  for (int i = 1; i < kpts.length; i++) {
    final double ldx = kpts[i][_idx['left_ankle']!][0] - kpts[i-1][_idx['left_ankle']!][0];
    final double ldy = kpts[i][_idx['left_ankle']!][1] - kpts[i-1][_idx['left_ankle']!][1];
    laS.add(math.sqrt(ldx*ldx + ldy*ldy) / body);
    final double rdx = kpts[i][_idx['right_ankle']!][0] - kpts[i-1][_idx['right_ankle']!][0];
    final double rdy = kpts[i][_idx['right_ankle']!][1] - kpts[i-1][_idx['right_ankle']!][1];
    raS.add(math.sqrt(rdx*rdx + rdy*rdy) / body);
  }
  double total = 0;
  for (final double v in laS) {
    total += v;
  }
  for (final double v in raS) {
    total += v;
  }
  final int stepCount = _countPeaks(laS, 0.05) + _countPeaks(raS, 0.05);
  // impact = argmin of min(rw_y, lw_y)
  double minMin = double.infinity; int impact = 0;
  for (int i = 0; i < kpts.length; i++) {
    final double m = math.min(kpts[i][_idx['right_wrist']!][1], kpts[i][_idx['left_wrist']!][1]);
    if (m < minMin) { minMin = m; impact = i; }
  }
  final int prep = math.max(1, (0.05 * kpts.length).floor());
  final double hipPrep = (kpts[prep][_idx['left_hip']!][0] + kpts[prep][_idx['right_hip']!][0]) / 2;
  final double hipImp = (kpts[impact][_idx['left_hip']!][0] + kpts[impact][_idx['right_hip']!][0]) / 2;
  final double hipShift = (hipImp - hipPrep).abs() / body;

  final double p = stepTable.percentileOf(total);
  return AxisScoreResult(
    star: _percentileToStar(p),
    measurement: total,
    percentile: p,
    calibrationSource: 'bst_step_percentiles.json',
    details: <String, dynamic>{
      'total_foot_path_norm': total,
      'step_count': stepCount,
      'hip_x_shift_norm': hipShift,
      'impact_frame': impact,
    },
  );
}

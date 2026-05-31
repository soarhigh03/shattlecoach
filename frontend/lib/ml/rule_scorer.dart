// Dart port of scripts/rule_based_scorer.py — 5-criteria geometric scorer.
// MUST produce numerically equivalent results to the Python original for the
// same keypoint input. Verified via test/rule_scorer_test.dart against fixture
// generated from test_skeleton.json.

import 'dart:math' as math;
import 'pose_extractor.dart' show kCocoNames;

const List<String> kCriteriaNames = <String>[
  'peak_wrist_above_shoulder',
  'elbow_extension_>=160deg',
  'hip_rotation_>=20deg',
  'knees_bent_at_prep',
]; // head_stable (C5) removed 2026-05-31

final Map<String, int> _idx = <String, int>{
  for (int i = 0; i < kCocoNames.length; i++) kCocoNames[i]: i,
};

class CriterionResult {
  final String name;
  final bool? pass;
  final double? measurement;
  final String unit;
  final double threshold;
  final double probability;
  final String? reasonNa;
  CriterionResult({
    required this.name, required this.pass, required this.measurement,
    required this.unit, required this.threshold, required this.probability,
    this.reasonNa,
  });
  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name, 'pass': pass, 'measurement': measurement,
    'unit': unit, 'threshold': threshold, 'probability': probability,
    if (reasonNa != null) 'reason_na': reasonNa,
  };
}

class RuleScoreResult {
  final List<CriterionResult> criteria;
  final int impactFrame;
  final int prepFrame;
  final String dominantArm; // 'right' | 'left'
  final double bodyScale;
  final int nFrames;
  RuleScoreResult({
    required this.criteria, required this.impactFrame, required this.prepFrame,
    required this.dominantArm, required this.bodyScale, required this.nFrames,
  });
}

/// kpts: List of T frames, each frame is List[17][3] = (x, y, conf).
RuleScoreResult scoreRules(List<List<List<double>>> kpts, {int smoothWindow = 5, double minJointConf = 0.3}) {
  if (kpts.isEmpty || kpts[0].length != 17 || kpts[0][0].length != 3) {
    throw ArgumentError('kpts must be (T, 17, 3); got T=${kpts.length}');
  }
  final int t = kpts.length;
  final List<List<List<double>>> sm = _temporalMedian(kpts, smoothWindow);
  final String dom = _dominantWrist(sm);
  final double body = _bodyScale(sm);
  final int impact = _detectImpactFrame(sm, dom);
  final int prep = math.max(1, (0.05 * t).floor());

  final List<CriterionResult> results = <CriterionResult>[];

  CriterionResult na(String name, String unit, double thr, String reason) =>
      CriterionResult(name: name, pass: null, measurement: null,
                      unit: unit, threshold: thr, probability: 0.5, reasonNa: reason);

  // C1: peak_wrist_above_shoulder.
  final List<int> need1 = <int>[_idx['${dom}_shoulder']!, _idx['${dom}_wrist']!];
  if (!_jointsVisible(sm, impact, need1, minJointConf)) {
    results.add(na(kCriteriaNames[0], 'ratio_of_shoulder_hip', 0.0, 'pose_conf_too_low'));
  } else {
    final double shY = sm[impact][_idx['${dom}_shoulder']!][1];
    final double wrY = sm[impact][_idx['${dom}_wrist']!][1];
    final double meas = (shY - wrY) / math.max(body, 1e-6);
    final bool passed = meas > 0.0;
    final double prob = _sigmoidMargin(meas, 0.0, scale: 0.10, direction: '>=');
    results.add(CriterionResult(name: kCriteriaNames[0], pass: passed,
        measurement: meas, unit: 'ratio_of_shoulder_hip', threshold: 0.0, probability: prob));
  }

  // C2: elbow_extension >= 160 deg.
  final List<int> need2 = <int>[_idx['${dom}_shoulder']!, _idx['${dom}_elbow']!, _idx['${dom}_wrist']!];
  if (!_jointsVisible(sm, impact, need2, minJointConf)) {
    results.add(na(kCriteriaNames[1], 'deg', 160.0, 'pose_conf_too_low'));
  } else {
    final double elbowAngle = _angleDeg(
      sm[impact][_idx['${dom}_shoulder']!],
      sm[impact][_idx['${dom}_elbow']!],
      sm[impact][_idx['${dom}_wrist']!],
    );
    final bool passed = elbowAngle >= 160.0;
    final double prob = _sigmoidMargin(elbowAngle, 160.0, scale: 8.0, direction: '>=');
    results.add(CriterionResult(name: kCriteriaNames[1], pass: passed,
        measurement: elbowAngle, unit: 'deg', threshold: 160.0, probability: prob));
  }

  // C3: hip_rotation >= 20 deg between prep (frame 0) and impact.
  final double hipImpact = _hipAngle(sm, impact);
  final double hipPrep = _hipAngle(sm, 0);
  double rot = (hipImpact - hipPrep).abs();
  if (rot > 180) rot = 360 - rot;
  final bool passed3 = rot >= 20.0;
  final double prob3 = _sigmoidMargin(rot, 20.0, scale: 8.0, direction: '>=');
  results.add(CriterionResult(name: kCriteriaNames[2], pass: passed3,
      measurement: rot, unit: 'deg', threshold: 20.0, probability: prob3));

  // C4: knees_bent_at_prep (<150 deg).
  final List<int> need4 = <int>[_idx['${dom}_hip']!, _idx['${dom}_knee']!, _idx['${dom}_ankle']!];
  if (!_jointsVisible(sm, prep, need4, minJointConf)) {
    results.add(na(kCriteriaNames[3], 'deg', 150.0, 'pose_conf_too_low'));
  } else {
    final double kneeAngle = _angleDeg(
      sm[prep][_idx['${dom}_hip']!],
      sm[prep][_idx['${dom}_knee']!],
      sm[prep][_idx['${dom}_ankle']!],
    );
    final bool passed = kneeAngle < 150.0;
    final double prob = _sigmoidMargin(kneeAngle, 150.0, scale: 8.0, direction: '<');
    results.add(CriterionResult(name: kCriteriaNames[3], pass: passed,
        measurement: kneeAngle, unit: 'deg', threshold: 150.0, probability: prob));
  }

  return RuleScoreResult(
    criteria: results, impactFrame: impact, prepFrame: prep,
    dominantArm: dom, bodyScale: body, nFrames: t,
  );
}

// ---------- helpers ----------

List<List<List<double>>> _temporalMedian(List<List<List<double>>> kpts, int window) {
  if (window <= 1 || kpts.length < window) return _copy3d(kpts);
  final int t = kpts.length;
  final int half = window ~/ 2;
  final List<List<List<double>>> out = _copy3d(kpts);
  for (int ti = 0; ti < t; ti++) {
    final int lo = math.max(0, ti - half);
    final int hi = math.min(t, ti + half + 1);
    for (int j = 0; j < 17; j++) {
      // median of x, y across the window
      final List<double> xs = <double>[for (int k = lo; k < hi; k++) kpts[k][j][0]];
      final List<double> ys = <double>[for (int k = lo; k < hi; k++) kpts[k][j][1]];
      xs.sort(); ys.sort();
      out[ti][j][0] = xs[xs.length ~/ 2];
      out[ti][j][1] = ys[ys.length ~/ 2];
      // conf left as-is from copy
    }
  }
  return out;
}

List<List<List<double>>> _copy3d(List<List<List<double>>> kpts) {
  return List<List<List<double>>>.generate(kpts.length, (int i) =>
      List<List<double>>.generate(17, (int j) =>
          <double>[kpts[i][j][0], kpts[i][j][1], kpts[i][j][2]]));
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

/// Valid [lo, hi) after excluding the first/last ~12% of frames (min 2). Start/end
/// frames are often pose noise; the impact is never there. Mirrors Python
/// rule_based_scorer._edge_trim (D4 — review round 1). Integer math for exact parity.
List<int> edgeTrim(int n) {
  final int m = math.max(2, (n * 12) ~/ 100);
  return (n - m) > m ? <int>[m, n - m] : <int>[0, n];
}

int _detectImpactFrame(List<List<List<double>>> kpts, String dom) {
  final List<int> r = edgeTrim(kpts.length);
  final int lo = r[0], hi = r[1];
  double minY = double.infinity;
  int idxBest = lo;
  final int wristIdx = _idx['${dom}_wrist']!;
  for (int i = lo; i < hi; i++) {
    if (kpts[i][wristIdx][1] < minY) {
      minY = kpts[i][wristIdx][1];
      idxBest = i;
    }
  }
  return idxBest;
}

bool _jointsVisible(List<List<List<double>>> kpts, int frame, List<int> jointIdxs, double minConf) {
  for (final int j in jointIdxs) {
    if (kpts[frame][j][2] < minConf) return false;
  }
  return true;
}

double _angleDeg(List<double> a, List<double> b, List<double> c) {
  final double bax = a[0] - b[0]; final double bay = a[1] - b[1];
  final double bcx = c[0] - b[0]; final double bcy = c[1] - b[1];
  final double na = math.sqrt(bax*bax + bay*bay);
  final double nc = math.sqrt(bcx*bcx + bcy*bcy);
  final double den = na * nc + 1e-9;
  double cosv = (bax*bcx + bay*bcy) / den;
  if (cosv < -1.0) cosv = -1.0;
  if (cosv > 1.0) cosv = 1.0;
  return math.acos(cosv) * 180.0 / math.pi;
}

double _hipAngle(List<List<List<double>>> kpts, int t) {
  final double vx = kpts[t][_idx['right_hip']!][0] - kpts[t][_idx['left_hip']!][0];
  final double vy = kpts[t][_idx['right_hip']!][1] - kpts[t][_idx['left_hip']!][1];
  return math.atan2(vy, vx) * 180.0 / math.pi;
}

double _sigmoidMargin(double measurement, double threshold, {required double scale, required String direction}) {
  double margin = measurement - threshold;
  if (direction == '<') margin = -margin;
  final double x = margin / math.max(scale, 1e-6);
  return 1.0 / (1.0 + math.exp(-x));
}

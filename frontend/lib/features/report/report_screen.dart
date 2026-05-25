import 'package:flutter/material.dart';

import '../shell/feature_placeholder.dart';

class ReportScreen extends StatelessWidget {
  const ReportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const FeaturePlaceholder(
      title: 'Report',
      icon: Icons.bar_chart,
      tagline: '내 폼이 어떻게 늘고 있는지\n한눈에 확인해 보세요.',
      bullets: [
        '스트로크별 평균 점수 추이',
        '약점 기준(5개 항목) 히트맵',
        '최근 분석 기록 타임라인',
        '동아리 평균과 익명 비교',
      ],
    );
  }
}

import 'package:flutter/material.dart';

import '../shell/feature_placeholder.dart';

class AiCoachScreen extends StatelessWidget {
  const AiCoachScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const FeaturePlaceholder(
      title: 'AI Coach',
      icon: Icons.sports_tennis,
      tagline: '스트로크를 고르고\n5초 스윙을 녹화해 보세요.',
      bullets: [
        '하이 클리어 · 로 클리어 · 숏 서브 · 포핸드 드라이브 4종 지원',
        'MoveNet 기반 실시간 포즈 오버레이 (≥25 fps)',
        '5개 항목 레이더 차트 + 프레임별 코칭 마커',
        '시니어 부원 시범 영상과 나란히 비교',
      ],
    );
  }
}

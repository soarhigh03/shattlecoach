import 'package:flutter/material.dart';

import '../shell/feature_placeholder.dart';

class SessionsScreen extends StatelessWidget {
  const SessionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const FeaturePlaceholder(
      title: '운동 신청',
      icon: Icons.event_available,
      tagline: '정기 / 비정기 운동 세션을\n바로 신청하고 관리해요.',
      bullets: [
        '운영진이 올린 세션 목록 (날짜 / 장소 / 정원)',
        '신청하기 · 신청 취소',
        '내 신청 내역 (예정 / 지난 세션)',
        '정원 마감 시 대기열 자동 등록',
      ],
    );
  }
}

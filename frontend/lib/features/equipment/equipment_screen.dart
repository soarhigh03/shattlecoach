import 'package:flutter/material.dart';

import '../shell/feature_placeholder.dart';

class EquipmentScreen extends StatelessWidget {
  const EquipmentScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const FeaturePlaceholder(
      title: '장비 공구',
      icon: Icons.shopping_bag,
      tagline: '셔틀콕 · 장비 공동구매에\n간편하게 참여해 보세요.',
      bullets: [
        '진행 중인 공구 목록 (품목 / 단가 / 마감일)',
        '신청 수량과 이름만 입력 (결제·정산은 별도 채널)',
        '내 신청 현황 확인 및 수정',
        '지난 공구 이력 보기',
      ],
    );
  }
}

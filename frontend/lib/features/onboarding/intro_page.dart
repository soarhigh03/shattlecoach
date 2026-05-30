import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../routing/app_router.dart';

class IntroPage extends StatelessWidget {
  const IntroPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => context.go(AppRoute.onboardingProfile),
        child: ClipRect(
          child: SizedBox.expand(
            child: Image.asset(
              'assets/images/onboarding-1.png',
              fit: BoxFit.cover,
              alignment: Alignment.bottomCenter,
            ),
          ),
        ),
      ),
    );
  }
}

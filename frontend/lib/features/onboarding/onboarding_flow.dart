import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../routing/app_router.dart';

/// Step indicator + back-button wrapper shared by all onboarding pages.
class OnboardingFlow extends StatelessWidget {
  const OnboardingFlow({super.key, required this.child});

  final Widget child;

  static const _steps = <String>[
    AppRoute.onboardingProfile,
    AppRoute.onboardingPermissions,
  ];

  int _currentStep(BuildContext context) {
    final loc = GoRouterState.of(context).matchedLocation;
    final i = _steps.indexOf(loc);
    return i < 0 ? 0 : i;
  }

  @override
  Widget build(BuildContext context) {
    final step = _currentStep(context);
    final isFirst = step == 0;
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        leading: isFirst
            ? const SizedBox.shrink()
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  if (context.canPop()) {
                    context.pop();
                  } else {
                    context.go(_steps[step - 1]);
                  }
                },
              ),
        title: _StepIndicator(
          current: step,
          total: _steps.length,
          color: colors.primary,
        ),
        centerTitle: true,
      ),
      body: SafeArea(child: child),
    );
  }
}

class _StepIndicator extends StatelessWidget {
  const _StepIndicator({
    required this.current,
    required this.total,
    required this.color,
  });

  final int current;
  final int total;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < total; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 240),
            width: i == current ? 24 : 8,
            height: 8,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
              color: i <= current ? color : color.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
      ],
    );
  }
}

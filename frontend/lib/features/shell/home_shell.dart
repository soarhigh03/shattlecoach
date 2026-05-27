import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../routing/app_router.dart';

/// 5-tab bottom navigation shell. The active tab is derived from the current
/// route so deep links and programmatic navigation stay in sync.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.child});

  final Widget child;

  static const _tabs = <_NavTab>[
    _NavTab(
      route: AppRoute.aiCoach,
      label: 'AI Coach',
      icon: Icons.sports_tennis_outlined,
      selectedIcon: Icons.sports_tennis,
    ),
    _NavTab(
      route: AppRoute.report,
      label: 'Report',
      icon: Icons.bar_chart_outlined,
      selectedIcon: Icons.bar_chart,
    ),
    _NavTab(
      route: AppRoute.sessions,
      label: '운동 신청',
      icon: Icons.event_available_outlined,
      selectedIcon: Icons.event_available,
    ),
    _NavTab(
      route: AppRoute.equipment,
      label: '장비 공구',
      icon: Icons.shopping_bag_outlined,
      selectedIcon: Icons.shopping_bag,
    ),
    _NavTab(
      route: AppRoute.settings,
      label: 'Settings',
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
    ),
  ];

  int _indexForLocation(String location) {
    final i = _tabs.indexWhere((t) => location.startsWith(t.route));
    return i < 0 ? 0 : i;
  }

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).matchedLocation;
    final selectedIndex = _indexForLocation(location);

    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: (i) => context.go(_tabs[i].route),
        destinations: [
          for (final tab in _tabs)
            NavigationDestination(
              icon: Icon(tab.icon),
              selectedIcon: Icon(tab.selectedIcon),
              label: tab.label,
            ),
        ],
      ),
    );
  }
}

class _NavTab {
  const _NavTab({
    required this.route,
    required this.label,
    required this.icon,
    required this.selectedIcon,
  });

  final String route;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

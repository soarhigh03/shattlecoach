import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../routing/app_router.dart';

/// 5-tab bottom navigation shell. The active tab is derived from the current
/// route so deep links and programmatic navigation stay in sync.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.child});

  final Widget child;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  @override
  void initState() {
    super.initState();
    // Onboarding hides the status bar; bring it back when the user lands here.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  static const _tabs = <_NavTab>[
    _NavTab(
      route: AppRoute.aiCoach,
      label: 'AI코치',
      icon: _SvgIcon('assets/icons/badminton-player.svg'),
      selectedIcon: _SvgIcon(
        'assets/icons/badminton-player.svg',
        selected: true,
      ),
    ),
    _NavTab(
      route: AppRoute.report,
      label: '리포트',
      icon: Icon(Icons.bar_chart_outlined),
      selectedIcon: Icon(Icons.bar_chart),
    ),
    _NavTab(
      route: AppRoute.sessions,
      label: '운동 신청',
      icon: Icon(Icons.event_available_outlined),
      selectedIcon: Icon(Icons.event_available),
    ),
    _NavTab(
      route: AppRoute.equipment,
      label: '장비 공구',
      icon: _SvgIcon('assets/icons/shuttlecock.svg'),
      selectedIcon: _SvgIcon('assets/icons/shuttlecock.svg', selected: true),
    ),
    _NavTab(
      route: AppRoute.settings,
      label: '설정',
      icon: Icon(Icons.settings_outlined),
      selectedIcon: Icon(Icons.settings),
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
      body: widget.child,
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainer,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 16,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: NavigationBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            surfaceTintColor: Colors.transparent,
            selectedIndex: selectedIndex,
            onDestinationSelected: (i) => context.go(_tabs[i].route),
            destinations: [
              for (final tab in _tabs)
                NavigationDestination(
                  icon: tab.icon,
                  selectedIcon: tab.selectedIcon,
                  label: tab.label,
                ),
            ],
          ),
        ),
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
  final Widget icon;
  final Widget selectedIcon;
}

/// Renders an SVG asset at Material's default icon size, tinted to match the
/// surrounding [IconTheme] so it picks up NavigationBar's selected/unselected
/// colors automatically.
class _SvgIcon extends StatelessWidget {
  const _SvgIcon(this.asset, {this.selected = false});

  final String asset;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final color = iconTheme.color ?? Theme.of(context).colorScheme.onSurface;
    return SvgPicture.asset(
      asset,
      width: iconTheme.size ?? 24,
      height: iconTheme.size ?? 24,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
  }
}

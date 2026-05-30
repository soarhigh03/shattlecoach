import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/ai_coach/ai_coach_screen.dart';
import '../features/equipment/equipment_screen.dart';
import '../features/equipment/post_compose_screen.dart';
import '../features/equipment/post_detail_screen.dart';
import '../features/equipment/post_models.dart';
import '../features/onboarding/onboarding_flow.dart';
import '../features/onboarding/permission_primers_page.dart';
import '../features/onboarding/profile_setup_page.dart';
import '../features/onboarding/sign_in_page.dart';
import '../features/onboarding/welcome_page.dart';
import '../features/report/report_screen.dart';
import '../features/sessions/sessions_screen.dart';
import '../features/settings/licenses_page.dart';
import '../features/settings/settings_screen.dart';
import '../features/settings/sign_out_page.dart';
import '../features/shell/home_shell.dart';
import '../services/auth_service.dart';
import '../services/onboarding_service.dart';

/// Route paths — referenced both by the router and by navigation callers.
class AppRoute {
  AppRoute._();

  static const splash = '/';

  static const onboardingWelcome = '/onboarding/welcome';
  static const onboardingSignIn = '/onboarding/sign-in';
  static const onboardingProfile = '/onboarding/profile';
  static const onboardingPermissions = '/onboarding/permissions';

  static const home = '/home';
  static const aiCoach = '/home/ai-coach';
  static const report = '/home/report';
  static const sessions = '/home/sessions';
  static const equipment = '/home/equipment';
  static const equipmentCompose = '/home/equipment/compose';
  static String equipmentDetail(String id) => '/home/equipment/$id';
  static const settings = '/home/settings';
  static const settingsSignOut = '/settings/sign-out';
  static const settingsLicenses = '/settings/licenses';
}

final _rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'root');
final _shellNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'shell');

/// Minimum time the splash screen stays visible on cold start, regardless of
/// how quickly prefs and auth resolve. Keeps the launch from feeling jarring.
final splashMinDelayProvider = FutureProvider<void>((ref) async {
  await Future<void>.delayed(const Duration(seconds: 1));
});

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: _rootNavigatorKey,
    initialLocation: AppRoute.splash,
    debugLogDiagnostics: true,
    redirect: (context, state) {
      final onboardingAsync = ref.read(onboardingCompletedProvider);
      final splashDelay = ref.read(splashMinDelayProvider);
      final user = ref.read(currentUserProvider);

      // Hold at splash until prefs are loaded AND the minimum splash time
      // elapsed.
      if (onboardingAsync.isLoading || splashDelay.isLoading) {
        return state.matchedLocation == AppRoute.splash
            ? null
            : AppRoute.splash;
      }
      final onboardingDone = onboardingAsync.value ?? false;
      final loc = state.matchedLocation;
      final inOnboarding = loc.startsWith('/onboarding');
      final atSplash = loc == AppRoute.splash;

      if (!onboardingDone) {
        // Force onboarding flow start until completion.
        if (!inOnboarding) return AppRoute.onboardingWelcome;
        return null;
      }

      // Onboarding complete but signed out → bounce to sign-in.
      if (user == null) {
        if (loc == AppRoute.onboardingSignIn) return null;
        return AppRoute.onboardingSignIn;
      }

      // Signed in + onboarded → no business at splash or onboarding.
      if (atSplash || inOnboarding) return AppRoute.aiCoach;
      return null;
    },
    refreshListenable: _RouterRefresh(ref),
    routes: [
      GoRoute(path: AppRoute.splash, builder: (_, _) => const _SplashScreen()),
      ShellRoute(
        builder: (context, state, child) => OnboardingFlow(child: child),
        routes: [
          GoRoute(
            path: AppRoute.onboardingWelcome,
            builder: (_, _) => const WelcomePage(),
          ),
          GoRoute(
            path: AppRoute.onboardingSignIn,
            builder: (_, _) => const SignInPage(),
          ),
          GoRoute(
            path: AppRoute.onboardingProfile,
            builder: (_, _) => const ProfileSetupPage(),
          ),
          GoRoute(
            path: AppRoute.onboardingPermissions,
            builder: (_, _) => const PermissionPrimersPage(),
          ),
        ],
      ),
      ShellRoute(
        navigatorKey: _shellNavigatorKey,
        builder: (context, state, child) => HomeShell(child: child),
        routes: [
          GoRoute(
            path: AppRoute.aiCoach,
            pageBuilder: (_, _) => _noTransition(const AiCoachScreen()),
          ),
          GoRoute(
            path: AppRoute.report,
            pageBuilder: (_, _) => _noTransition(const ReportScreen()),
          ),
          GoRoute(
            path: AppRoute.sessions,
            pageBuilder: (_, _) => _noTransition(const SessionsScreen()),
          ),
          GoRoute(
            path: AppRoute.equipment,
            pageBuilder: (_, _) => _noTransition(const EquipmentScreen()),
          ),
          GoRoute(
            path: AppRoute.settings,
            pageBuilder: (_, _) => _noTransition(const SettingsScreen()),
          ),
        ],
      ),
      GoRoute(
        path: AppRoute.settingsSignOut,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, _) => const SignOutPage(),
      ),
      GoRoute(
        path: AppRoute.settingsLicenses,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, _) => const LicensesPage(),
      ),
      GoRoute(
        path: AppRoute.equipmentCompose,
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, state) {
          final extra = state.extra;
          if (extra is Post) {
            return PostComposeScreen(editing: extra);
          }
          return PostComposeScreen(
            initialKind: extra is PostKind ? extra : null,
          );
        },
      ),
      GoRoute(
        path: '/home/equipment/:id',
        parentNavigatorKey: _rootNavigatorKey,
        builder: (_, state) =>
            PostDetailScreen(postId: state.pathParameters['id']!),
      ),
    ],
  );
});

NoTransitionPage<T> _noTransition<T>(Widget child) =>
    NoTransitionPage<T>(child: child);

/// Drives router refresh when auth or onboarding state changes.
class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(this._ref) {
    _ref.listen(authStateProvider, (_, _) => notifyListeners());
    _ref.listen(onboardingCompletedProvider, (_, _) => notifyListeners());
    _ref.listen(splashMinDelayProvider, (_, _) => notifyListeners());
  }
  final Ref _ref;
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: SizedBox.expand(
        child: Image(
          image: AssetImage('assets/images/splash_v1.png'),
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}

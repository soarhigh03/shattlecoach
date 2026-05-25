import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tracks whether the user has finished the local onboarding flow.
///
/// Stored separately from auth state because a returning user with a valid
/// Supabase session should not see the welcome carousel again, even after a
/// reinstall is irrelevant — but a fresh install always starts over.
class OnboardingService {
  static const _kCompletedKey = 'onboarding.completed';

  Future<bool> isCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kCompletedKey) ?? false;
  }

  Future<void> markCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kCompletedKey, true);
  }

  Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kCompletedKey);
  }
}

final onboardingServiceProvider = Provider<OnboardingService>(
  (ref) => OnboardingService(),
);

/// Async snapshot of onboarding-completed state — drives the router redirect.
final onboardingCompletedProvider = FutureProvider<bool>((ref) async {
  return ref.watch(onboardingServiceProvider).isCompleted();
});

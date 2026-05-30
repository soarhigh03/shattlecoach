import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'auth_service.dart';
import 'supabase_service.dart';

/// Snapshot of the current user's `public.profiles` row.
class UserProfile {
  const UserProfile({
    required this.id,
    required this.email,
    required this.name,
    required this.handedness,
    required this.role,
  });

  final String id;
  final String email;
  final String name;
  final String? handedness;
  final String role;

  factory UserProfile.fromRow(Map<String, dynamic> row) => UserProfile(
        id: row['id'] as String,
        email: (row['email'] as String?) ?? '',
        name: (row['name'] as String?) ?? '',
        handedness: row['handedness'] as String?,
        role: (row['role'] as String?) ?? 'member',
      );
}

class ProfileService {
  ProfileService();

  Future<UserProfile?> fetchMine() async {
    if (!SupabaseBootstrap.isInitialized) return null;
    final user = SupabaseBootstrap.client.auth.currentUser;
    if (user == null) return null;
    final row = await SupabaseBootstrap.client
        .from('profiles')
        .select('id, email, name, handedness, role')
        .eq('id', user.id)
        .maybeSingle();
    if (row == null) return null;
    return UserProfile.fromRow(row);
  }

  /// Persists onboarding fields and stamps `onboarded_at`. `handedness` must
  /// be `'left'` or `'right'` to match the `handedness` Postgres enum.
  Future<void> completeOnboarding({
    required String name,
    required String handedness,
  }) async {
    if (!SupabaseBootstrap.isInitialized) {
      throw StateError('Supabase is not initialized.');
    }
    final user = SupabaseBootstrap.client.auth.currentUser;
    if (user == null) throw StateError('Not signed in.');
    await SupabaseBootstrap.client.from('profiles').update({
      'name': name,
      'handedness': handedness,
      'onboarded_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', user.id);
  }
}

final profileServiceProvider = Provider<ProfileService>(
  (_) => ProfileService(),
);

/// Current user's profile row. Rebuilds when auth changes.
final myProfileProvider = FutureProvider<UserProfile?>((ref) async {
  ref.watch(currentUserProvider);
  return ref.watch(profileServiceProvider).fetchMine();
});

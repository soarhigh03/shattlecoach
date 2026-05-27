import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_service.dart';

/// Sign-in surface. Only Google OAuth via Supabase is supported.
class AuthService {
  AuthService();

  GoTrueClient get _auth => SupabaseBootstrap.client.auth;

  Stream<AuthState> get authStateChanges => _auth.onAuthStateChange;

  Session? get currentSession => _auth.currentSession;
  User? get currentUser => _auth.currentUser;

  /// Native Google sign-in → exchange ID token with Supabase.
  ///
  /// On iOS/Android we use `google_sign_in` to get the ID token natively rather
  /// than the OAuth web flow. The web client ID is required for Supabase to
  /// accept the ID token; the iOS client ID is required for the native iOS SDK.
  Future<AuthResponse> signInWithGoogle() async {
    if (!SupabaseBootstrap.isInitialized) {
      throw StateError(
        'Supabase is not initialized. Fill in SUPABASE_URL and SUPABASE_ANON_KEY in .env.',
      );
    }

    final webClientId = dotenv.maybeGet('GOOGLE_WEB_CLIENT_ID') ?? '';
    final iosClientId = dotenv.maybeGet('GOOGLE_IOS_CLIENT_ID') ?? '';

    if (webClientId.isEmpty) {
      throw StateError(
        'GOOGLE_WEB_CLIENT_ID is empty. Register an OAuth client at console.cloud.google.com and add it to .env.',
      );
    }

    final googleSignIn = GoogleSignIn(
      clientId: defaultTargetPlatform == TargetPlatform.iOS
          ? iosClientId
          : null,
      serverClientId: webClientId,
    );

    final account = await googleSignIn.signIn();
    if (account == null) {
      throw const _AuthCancelledException();
    }
    final auth = await account.authentication;
    final idToken = auth.idToken;
    final accessToken = auth.accessToken;

    if (idToken == null) {
      throw StateError('Google sign-in returned no ID token.');
    }

    return _auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: idToken,
      accessToken: accessToken,
    );
  }

  Future<void> signOut() async {
    if (!SupabaseBootstrap.isInitialized) return;
    await _auth.signOut();
    await GoogleSignIn().signOut();
  }
}

class _AuthCancelledException implements Exception {
  const _AuthCancelledException();
  @override
  String toString() => 'Google sign-in cancelled by user.';
}

final authServiceProvider = Provider<AuthService>((ref) => AuthService());

/// Emits auth state changes; null when signed out.
final authStateProvider = StreamProvider<AuthState?>((ref) {
  if (!SupabaseBootstrap.isInitialized) {
    return Stream<AuthState?>.value(null);
  }
  return ref.watch(authServiceProvider).authStateChanges;
});

/// Convenience: current signed-in user (null when signed out / unconfigured).
final currentUserProvider = Provider<User?>((ref) {
  ref.watch(authStateProvider);
  if (!SupabaseBootstrap.isInitialized) return null;
  return SupabaseBootstrap.client.auth.currentUser;
});

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Initializes the Supabase client from .env values.
///
/// Call this once in `main()` before runApp. Reads SUPABASE_URL and
/// SUPABASE_ANON_KEY from the bundled .env. If either is empty (e.g. the
/// developer hasn't filled in .env yet), initialization is skipped so the app
/// still boots — only auth-dependent features will fail at call time.
class SupabaseBootstrap {
  SupabaseBootstrap._();

  static bool _initialized = false;

  static bool get isInitialized => _initialized;

  static Future<void> init() async {
    final url = dotenv.maybeGet('SUPABASE_URL') ?? '';
    final anonKey = dotenv.maybeGet('SUPABASE_ANON_KEY') ?? '';

    if (url.isEmpty || anonKey.isEmpty) {
      // Skip silently — surfaced to the user by auth flows when they try to sign in.
      return;
    }

    await Supabase.initialize(url: url, anonKey: anonKey);
    _initialized = true;
  }

  static SupabaseClient get client => Supabase.instance.client;
}

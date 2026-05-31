import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'services/supabase_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Hide both system bars (status + bottom nav) so the app renders fully
  // edge-to-edge. Sticky immersive re-hides them automatically after a swipe.
  // The Android side also pins this from the splash screen via MainActivity.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {}

  await SupabaseBootstrap.init();

  runApp(const ProviderScope(child: ShattlecoachApp()));
}

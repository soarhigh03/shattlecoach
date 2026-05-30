import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'services/supabase_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Hide the OS status bar so onboarding screens render fully edge-to-edge.
  // HomeShell restores it once the user reaches the tabbed home shell.
  await SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.manual,
    overlays: [SystemUiOverlay.bottom],
  );

  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {}

  await SupabaseBootstrap.init();

  runApp(const ProviderScope(child: ShattlecoachApp()));
}

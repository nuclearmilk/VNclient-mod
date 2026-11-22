import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/user_info.dart';

/// Synchronous access to [SharedPreferences], preloaded before `runApp`.
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError(
    'sharedPreferencesProvider must be overridden in main()',
  );
});

/// Authentication metadata preloaded before `runApp` so the first frame
/// already knows whether a persisted session exists.
class PreloadedAuth {
  const PreloadedAuth({this.token, this.user});

  final String? token;
  final UserInfo? user;
}

/// Provides the preloaded authentication state (overridden in `main()`).
final preloadedAuthProvider = Provider<PreloadedAuth>((ref) {
  return const PreloadedAuth();
});

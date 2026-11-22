import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/constants/app_constants.dart';
import 'core/models/user_info.dart';
import 'core/providers/prefs_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  const storage = FlutterSecureStorage();
  final results = await Future.wait<dynamic>([
    SharedPreferences.getInstance(),
    storage
        .read(key: AppConstants.tokenKey)
        .then<String?>((v) => v, onError: (_, __) => null),
  ]);

  final prefs = results[0] as SharedPreferences;
  final token = results[1] as String?;
  final preloadedAuth = await _loadPreloadedAuth(prefs, storage, token);

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        preloadedAuthProvider.overrideWithValue(preloadedAuth),
      ],
      child: const VndbApp(),
    ),
  );
}

Future<PreloadedAuth> _loadPreloadedAuth(
  SharedPreferences prefs,
  FlutterSecureStorage storage,
  String? token,
) async {
  if (token == null || token.isEmpty) {
    return const PreloadedAuth();
  }

  var uid = prefs.getString(AppConstants.userIdKey);
  var uname = prefs.getString(AppConstants.usernameKey);
  final perms = prefs.getStringList(AppConstants.userPermissionsKey);

  // Upgrade migration fallback: v1.3.10 wrote userId/username only to secure storage.
  if (uid == null || uid.isEmpty) {
    final legacy = await Future.wait<String?>([
      storage
          .read(key: AppConstants.userIdKey)
          .then<String?>((v) => v, onError: (_, __) => null),
      storage
          .read(key: AppConstants.usernameKey)
          .then<String?>((v) => v, onError: (_, __) => null),
    ]);
    uid = legacy[0];
    uname ??= legacy[1];
    if (uid != null && uid.isNotEmpty) {
      await prefs.setString(AppConstants.userIdKey, uid);
      if (uname != null && uname.isNotEmpty) {
        await prefs.setString(AppConstants.usernameKey, uname);
      }
    }
  }

  final user = (uid != null && uid.isNotEmpty)
      ? UserInfo(
          id: uid,
          username: uname ?? '',
          permissions: perms ?? const [],
        )
      : null;

  return PreloadedAuth(token: token, user: user);
}

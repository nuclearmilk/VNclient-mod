import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/vndb_client.dart';
import '../constants/app_constants.dart';
import '../models/user_info.dart';
import 'client_provider.dart';
import 'prefs_provider.dart';

/// Riverpod provider for [AuthNotifier].
final authNotifierProvider =
    StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  final client = ref.watch(vndbClientProvider);
  final prefs = ref.watch(sharedPreferencesProvider);
  final preloaded = ref.watch(preloadedAuthProvider);
  return AuthNotifier(client, prefs, preloaded);
});

/// Persisted authentication state for the current session.
class AuthState {
  const AuthState({
    this.token,
    this.user,
    this.status = AuthStatus.unknown,
    this.error,
  });

  final String? token;
  final UserInfo? user;
  final AuthStatus status;
  final String? error;

  bool get isAuthenticated => user != null && token != null;
  bool get canWriteList => user?.canWriteList ?? false;

  AuthState copyWith({
    String? token,
    UserInfo? user,
    AuthStatus? status,
    String? error,
    bool clearToken = false,
    bool clearUser = false,
  }) {
    return AuthState(
      token: clearToken ? null : (token ?? this.token),
      user: clearUser ? null : (user ?? this.user),
      status: status ?? this.status,
      error: error,
    );
  }
}

enum AuthStatus { unknown, authenticated, unauthenticated, loading, error }

/// Notifier that owns the API token, validates it against `/authinfo`
/// and persists it across [FlutterSecureStorage] (token) and [SharedPreferences]
/// (non-sensitive user metadata for instant startup).
class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier(this._client, this._prefs, PreloadedAuth preloaded)
      : super(_initialState(_client, preloaded)) {
    // Wire the HTTP layer's 401 callback back to this notifier.
    _client.onAuthInvalid = () {
      Future.microtask(() => handleAuthInvalid());
    };
    if (state.status == AuthStatus.authenticated && state.token != null) {
      Future.microtask(() => _verifyInBackground(state.token!));
    } else if (state.status == AuthStatus.loading && state.token != null) {
      Future.microtask(() => _applyToken(state.token!));
    }
  }

  final VndbClient _client;
  final SharedPreferences _prefs;
  static const _storage = FlutterSecureStorage();
  bool _clearing = false;

  static AuthState _initialState(VndbClient client, PreloadedAuth preloaded) {
    final token = preloaded.token;
    if (token != null && token.isNotEmpty) {
      client.setToken(token);
      final user = preloaded.user;
      if (user != null && user.id.isNotEmpty) {
        return AuthState(
          token: token,
          user: user,
          status: AuthStatus.authenticated,
        );
      }
      return AuthState(token: token, status: AuthStatus.loading);
    }
    return const AuthState(status: AuthStatus.unauthenticated);
  }

  Future<void> _verifyInBackground(String token) async {
    try {
      final json = await _client.get('/authinfo');
      if (!mounted || state.token != token) return;
      final user = UserInfo.fromJson(json);
      await _persistUserMetaIfChanged(user);
      if (!mounted || state.token != token) return;
      if (_userChanged(state.user, user)) {
        state = AuthState(
          token: token,
          user: user,
          status: AuthStatus.authenticated,
        );
      }
    } on VndbApiException catch (e) {
      if (!mounted || state.token != token) return;
      if (e.isUnauthorized) {
        await handleAuthInvalid();
      }
      // Transient 5xx/rate-limit/network errors keep existing optimistic session.
    } catch (_) {
      // Transient errors keep existing optimistic session.
    }
  }

  bool _userChanged(UserInfo? a, UserInfo b) {
    if (a == null) return true;
    return a.id != b.id ||
        a.username != b.username ||
        !listEquals(a.permissions, b.permissions);
  }

  Future<void> _persistUserMetaIfChanged(UserInfo user) async {
    final prevId = _prefs.getString(AppConstants.userIdKey);
    final prevName = _prefs.getString(AppConstants.usernameKey);
    final prevPerms = _prefs.getStringList(AppConstants.userPermissionsKey);

    if (prevId != user.id) {
      await _prefs.setString(AppConstants.userIdKey, user.id);
    }
    if (prevName != user.username) {
      await _prefs.setString(AppConstants.usernameKey, user.username);
    }
    if (prevPerms == null || !listEquals(prevPerms, user.permissions)) {
      await _prefs.setStringList(
        AppConstants.userPermissionsKey,
        user.permissions,
      );
    }
  }

  Future<void> _applyToken(String token) async {
    _client.setToken(token);
    state = AuthState(
      token: token,
      status: AuthStatus.loading,
    );
    try {
      final json = await _client.get('/authinfo');
      if (!mounted) return;
      final user = UserInfo.fromJson(json);
      await _storage.write(key: AppConstants.tokenKey, value: token);
      await _persistUserMetaIfChanged(user);
      if (!mounted) return;
      state = AuthState(
        token: token,
        user: user,
        status: AuthStatus.authenticated,
      );
    } on VndbApiException catch (e) {
      if (!mounted) return;
      if (e.isUnauthorized) {
        await _clearStorage();
        _client.setToken(null);
        state = const AuthState(status: AuthStatus.unauthenticated);
      } else {
        state = AuthState(
          token: token,
          status: AuthStatus.error,
          error: e.message,
        );
      }
    } catch (e) {
      if (!mounted) return;
      state = AuthState(
        token: token,
        status: AuthStatus.error,
        error: e.toString(),
      );
    }
  }

  /// Validates and stores the given token.
  Future<bool> login(String token) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) {
      state = state.copyWith(
        status: AuthStatus.error,
        error: 'Token cannot be empty',
      );
      return false;
    }
    await _applyToken(trimmed);
    return state.status == AuthStatus.authenticated;
  }

  /// Clears the stored token and signs the user out.
  Future<void> logout() async {
    await _clearStorage();
    _client.setToken(null);
    if (!mounted) return;
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  /// Called by the HTTP layer when a 401 is observed.
  Future<void> handleAuthInvalid() async {
    if (_clearing) return;
    _clearing = true;
    try {
      await _clearStorage();
      _client.setToken(null);
      if (!mounted) return;
      state = const AuthState(status: AuthStatus.unauthenticated);
    } finally {
      _clearing = false;
    }
  }

  Future<void> _clearStorage() async {
    await Future.wait([
      _storage.delete(key: AppConstants.tokenKey).then<void>(
            (_) {},
            onError: (_, __) {},
          ),
      _storage.delete(key: AppConstants.userIdKey).then<void>(
            (_) {},
            onError: (_, __) {},
          ),
      _storage.delete(key: AppConstants.usernameKey).then<void>(
            (_) {},
            onError: (_, __) {},
          ),
      _prefs.remove(AppConstants.userIdKey),
      _prefs.remove(AppConstants.usernameKey),
      _prefs.remove(AppConstants.userPermissionsKey),
    ]);
  }
}

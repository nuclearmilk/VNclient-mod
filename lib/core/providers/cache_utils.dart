import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Keeps an `autoDispose` provider alive for [duration] after its last
/// listener is removed, preventing redundant network fetches on rapid
/// page back-and-forth navigation.
void keepAliveFor(Ref ref, Duration duration) {
  final link = ref.keepAlive();
  Timer? timer;
  ref.onCancel(() {
    timer?.cancel();
    timer = Timer(duration, link.close);
  });
  ref.onResume(() {
    timer?.cancel();
    timer = null;
  });
  ref.onDispose(() {
    timer?.cancel();
  });
}

/// Stale-While-Revalidate (SWR) notifier backed by [SharedPreferences].
///
/// Immediately hydrates `AsyncValue.data(...)` from the locally cached JSON
/// payload if present, then refreshes in the background. In-flight refreshes
/// are deduplicated, and background failures preserve existing cached data.
class SwrNotifier<T> extends StateNotifier<AsyncValue<T>> {
  SwrNotifier({
    required SharedPreferences prefs,
    required String cacheKey,
    required Future<Map<String, dynamic>> Function() fetcher,
    required T Function(Map<String, dynamic> json) parser,
    bool Function(SharedPreferences prefs)? shouldSkipInitialRefresh,
    void Function(SharedPreferences prefs)? onCacheSaved,
  })  : _prefs = prefs,
        _cacheKey = cacheKey,
        _fetcher = fetcher,
        _parser = parser,
        _onCacheSaved = onCacheSaved,
        super(_readInitial(prefs, cacheKey, parser)) {
    final skip =
        shouldSkipInitialRefresh?.call(prefs) == true && state.hasValue;
    if (!skip) {
      refresh();
    }
  }

  final SharedPreferences _prefs;
  final String _cacheKey;
  final Future<Map<String, dynamic>> Function() _fetcher;
  final T Function(Map<String, dynamic> json) _parser;
  final void Function(SharedPreferences prefs)? _onCacheSaved;
  Future<void>? _inFlight;

  static AsyncValue<T> _readInitial<T>(
    SharedPreferences prefs,
    String cacheKey,
    T Function(Map<String, dynamic> json) parser,
  ) {
    final raw = prefs.getString(cacheKey);
    if (raw == null || raw.isEmpty) {
      return const AsyncValue.loading();
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return AsyncValue.data(parser(decoded));
      }
      if (decoded is Map) {
        return AsyncValue.data(parser(Map<String, dynamic>.from(decoded)));
      }
    } catch (_) {
      // Corrupt cache falls back to loading and will be overwritten on refresh.
    }
    return const AsyncValue.loading();
  }

  /// Fetches fresh data from the network and updates both state and cache.
  Future<void> refresh({bool force = false}) {
    if (_inFlight != null) return _inFlight!;
    final future = _doRefresh();
    _inFlight = future;
    future.whenComplete(() {
      if (identical(_inFlight, future)) {
        _inFlight = null;
      }
    });
    return future;
  }

  Future<void> _doRefresh() async {
    try {
      final raw = await _fetcher();
      final parsed = _parser(raw);
      try {
        await _prefs.setString(_cacheKey, jsonEncode(raw));
        _onCacheSaved?.call(_prefs);
      } catch (_) {
        // Cache persistence is best-effort.
      }
      if (!mounted) return;
      state = AsyncValue.data(parsed);
    } catch (e, st) {
      if (!mounted) return;
      // Preserve stale cached data on refresh error so offline/flaky startup
      // still displays usable content.
      if (!state.hasValue) {
        state = AsyncValue.error(e, st);
      }
    }
  }
}

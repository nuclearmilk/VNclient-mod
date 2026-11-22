import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api/endpoints/list_endpoint.dart';
import '../../core/api/endpoints/vn_endpoint.dart';
import '../../core/constants/app_constants.dart';
import '../../core/models/query_result.dart';
import '../../core/models/release.dart';
import '../../core/models/stats.dart';
import '../../core/models/vn.dart';
import '../../core/providers/auth_provider.dart';
import '../../core/providers/cache_utils.dart';
import '../../core/providers/endpoints_provider.dart';
import '../../core/providers/prefs_provider.dart';

/// Independent SWR provider for database statistics on the home page.
final homeStatsProvider =
    StateNotifierProvider.autoDispose<SwrNotifier<Stats>, AsyncValue<Stats>>(
        (ref) {
  keepAliveFor(ref, const Duration(minutes: 10));
  final prefs = ref.watch(sharedPreferencesProvider);
  final endpoint = ref.watch(statsEndpointProvider);
  return SwrNotifier<Stats>(
    prefs: prefs,
    cacheKey: AppConstants.cacheHomeStatsKey,
    fetcher: endpoint.getStatsRaw,
    parser: Stats.fromJson,
  );
});

/// Independent SWR provider for recently added VNs on the home page.
final homeRecentVnsProvider = StateNotifierProvider.autoDispose<
    SwrNotifier<List<Vn>>, AsyncValue<List<Vn>>>((ref) {
  keepAliveFor(ref, const Duration(minutes: 10));
  final prefs = ref.watch(sharedPreferencesProvider);
  final endpoint = ref.watch(vnEndpointProvider);
  return SwrNotifier<List<Vn>>(
    prefs: prefs,
    cacheKey: AppConstants.cacheHomeRecentKey,
    fetcher: () => endpoint.getRecentRaw(limit: 10),
    parser: (json) => QueryResult.fromJson(json, Vn.fromJson).results,
  );
});

/// Independent SWR provider for just-released items on the home page.
final homeJustReleasedProvider = StateNotifierProvider.autoDispose<
    SwrNotifier<List<Release>>, AsyncValue<List<Release>>>((ref) {
  keepAliveFor(ref, const Duration(minutes: 10));
  final prefs = ref.watch(sharedPreferencesProvider);
  final endpoint = ref.watch(releaseEndpointProvider);
  return SwrNotifier<List<Release>>(
    prefs: prefs,
    cacheKey: AppConstants.cacheHomeJustReleasedKey,
    fetcher: () => endpoint.getJustReleasedRaw(limit: 10),
    parser: (json) => QueryResult.fromJson(json, Release.fromJson).results,
  );
});

/// Independent SWR provider for upcoming releases on the home page.
final homeUpcomingProvider = StateNotifierProvider.autoDispose<
    SwrNotifier<List<Release>>, AsyncValue<List<Release>>>((ref) {
  keepAliveFor(ref, const Duration(minutes: 10));
  final prefs = ref.watch(sharedPreferencesProvider);
  final endpoint = ref.watch(releaseEndpointProvider);
  return SwrNotifier<List<Release>>(
    prefs: prefs,
    cacheKey: AppConstants.cacheHomeUpcomingKey,
    fetcher: () => endpoint.getUpcomingRaw(limit: 10),
    parser: (json) => QueryResult.fromJson(json, Release.fromJson).results,
  );
});

/// Personalized recommendations with local SWR cache + in-memory candidate pool
/// so "换一批" shuffles instantly without re-fetching 200 entries each time.
class RecommendationsNotifier extends StateNotifier<AsyncValue<List<Vn>>> {
  RecommendationsNotifier({
    required SharedPreferences prefs,
    required ListEndpoint listEndpoint,
    required VnEndpoint vnEndpoint,
    required String? userId,
  })  : _prefs = prefs,
        _listEndpoint = listEndpoint,
        _vnEndpoint = vnEndpoint,
        _userId = userId,
        super(_readInitial(prefs, userId)) {
    if (_userId != null) {
      refresh();
    }
  }

  final SharedPreferences _prefs;
  final ListEndpoint _listEndpoint;
  final VnEndpoint _vnEndpoint;
  final String? _userId;
  final _rng = Random();

  List<String>? _topTags;
  Set<String>? _ownedVnIds;
  List<Vn> _pool = const [];
  int _poolOffset = 0;
  Future<void>? _inFlight;

  static const int _displayCount = 10;

  static AsyncValue<List<Vn>> _readInitial(
    SharedPreferences prefs,
    String? userId,
  ) {
    if (userId == null) return const AsyncValue.data([]);
    final raw = prefs.getString('${AppConstants.cacheRecommendationsPrefix}$userId');
    if (raw == null || raw.isEmpty) {
      return const AsyncValue.loading();
    }
    try {
      final list = jsonDecode(raw) as List;
      final vns = list
          .map((e) => Vn.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      return AsyncValue.data(vns);
    } catch (_) {
      return const AsyncValue.loading();
    }
  }

  Future<void> _saveCache(List<Vn> items) async {
    final userId = _userId;
    if (userId == null) return;
    try {
      final encoded = jsonEncode(
        items
            .map((vn) => {
                  'id': vn.id,
                  'title': vn.title,
                  if (vn.alttitle != null) 'alttitle': vn.alttitle,
                  if (vn.released != null) 'released': vn.released,
                  if (vn.image != null) 'image': vn.image!.toJson(),
                })
            .toList(),
      );
      await _prefs.setString(
        '${AppConstants.cacheRecommendationsPrefix}$userId',
        encoded,
      );
    } catch (_) {
      // Cache persistence is best-effort.
    }
  }

  /// Refreshes recommendations. When [forceReloadProfile] is true (or profile
  /// hasn't been loaded yet), reloads the user's lightweight tag profile in
  /// one `/ulist` call; otherwise reuses the in-memory tag profile.
  Future<void> refresh({bool forceReloadProfile = false}) {
    final userId = _userId;
    if (userId == null) return Future.value();
    if (_inFlight != null) return _inFlight!;
    final future = _doRefresh(userId, forceReloadProfile: forceReloadProfile);
    _inFlight = future;
    future.whenComplete(() {
      if (identical(_inFlight, future)) {
        _inFlight = null;
      }
    });
    return future;
  }

  Future<void> _doRefresh(
    String userId, {
    required bool forceReloadProfile,
  }) async {
    try {
      if (forceReloadProfile || _topTags == null || _ownedVnIds == null) {
        final res = await _listEndpoint.getTagProfile(
          userId,
          labelIds: const [
            AppConstants.labelWishlist,
            AppConstants.labelFinished,
          ],
          results: 100,
        );
        if (!mounted) return;
        final owned = <String>{};
        final tagCounts = <String, int>{};
        for (final entry in res.results) {
          final vn = entry.vn;
          if (vn == null) continue;
          owned.add(vn.id);
          final seenTags = <String>{};
          for (final tag in vn.tags) {
            if (seenTags.add(tag.id)) {
              tagCounts[tag.id] = (tagCounts[tag.id] ?? 0) + 1;
            }
          }
        }
        final sortedTags = tagCounts.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        _ownedVnIds = owned;
        _topTags = sortedTags.take(12).map((e) => e.key).toList();
      }

      final topTags = _topTags ?? const <String>[];
      if (topTags.isEmpty) {
        if (!mounted) return;
        state = const AsyncValue.data([]);
        return;
      }

      final shuffledTags = topTags.toList()..shuffle(_rng);
      final pickCount = (4 + _rng.nextInt(5)).clamp(1, shuffledTags.length);
      final selectedTags = shuffledTags.take(pickCount).toList();

      final result = await _vnEndpoint.byTags(selectedTags, results: 50);
      if (!mounted) return;

      final owned = _ownedVnIds ?? const <String>{};
      final pool =
          result.results.where((vn) => !owned.contains(vn.id)).toList();
      pool.shuffle(_rng);
      _pool = pool;
      _poolOffset = 0;

      final batch = _takeNextBatch();
      await _saveCache(batch);
      if (!mounted) return;
      state = AsyncValue.data(batch);
    } catch (_) {
      if (!mounted) return;
      if (!state.hasValue) {
        state = const AsyncValue.data([]);
      }
    }
  }

  List<Vn> _takeNextBatch() {
    if (_pool.isEmpty) return const [];
    final end = (_poolOffset + _displayCount).clamp(0, _pool.length);
    final batch = _pool.sublist(_poolOffset, end);
    _poolOffset = end;
    return batch;
  }

  /// Immediately serves the next 10 items from the in-memory pool, or fetches
  /// a fresh sample using the cached tag profile once the pool is exhausted.
  Future<void> shuffleNext() async {
    if (_userId == null) return;
    if (_pool.length - _poolOffset >= _displayCount) {
      final batch = _takeNextBatch();
      state = AsyncValue.data(batch);
      await _saveCache(batch);
      return;
    }
    await refresh(forceReloadProfile: false);
  }
}

final recommendationsProvider = StateNotifierProvider.autoDispose<
    RecommendationsNotifier, AsyncValue<List<Vn>>>((ref) {
  keepAliveFor(ref, const Duration(minutes: 15));
  final prefs = ref.watch(sharedPreferencesProvider);
  final userId = ref.watch(authNotifierProvider.select((s) => s.user?.id));
  final listEndpoint = ref.watch(listEndpointProvider);
  final vnEndpoint = ref.watch(vnEndpointProvider);
  return RecommendationsNotifier(
    prefs: prefs,
    listEndpoint: listEndpoint,
    vnEndpoint: vnEndpoint,
    userId: userId,
  );
});

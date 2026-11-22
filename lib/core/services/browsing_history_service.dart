import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/app_constants.dart';
import '../providers/prefs_provider.dart';

/// A browsing history entry: a VN id plus the timestamp it was viewed.
class HistoryEntry {
  const HistoryEntry({
    required this.vnId,
    required this.viewedAt,
  });

  final String vnId;
  final int viewedAt;

  Map<String, dynamic> toJson() => {
        'vnId': vnId,
        'viewedAt': viewedAt,
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> json) {
    return HistoryEntry(
      vnId: json['vnId'] as String? ?? '',
      viewedAt: json['viewedAt'] as int? ?? 0,
    );
  }
}

/// State notifier that owns the browsing history list.
///
/// History is persisted to [SharedPreferences] as a JSON array of
/// [HistoryEntry] objects. When a VN detail page is opened, [record] is
/// called which moves the entry to the front (most-recent-first order),
/// deduplicates, and trims to [AppConstants.browsingHistoryLimit].
class BrowsingHistoryService extends StateNotifier<List<HistoryEntry>> {
  BrowsingHistoryService(this._prefs) : super(_readInitial(_prefs));

  final SharedPreferences _prefs;

  static List<HistoryEntry> _readInitial(SharedPreferences prefs) {
    final raw = prefs.getString(AppConstants.browsingHistoryKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => HistoryEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _persist() async {
    await _prefs.setString(
      AppConstants.browsingHistoryKey,
      jsonEncode(state.map((e) => e.toJson()).toList()),
    );
  }

  /// Records a VN view, moving it to the front of the history list.
  Future<void> record(String vnId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final filtered =
        state.where((e) => e.vnId != vnId).toList(growable: true);
    filtered.insert(0, HistoryEntry(vnId: vnId, viewedAt: now));
    // Trim to the configured limit.
    if (filtered.length > AppConstants.browsingHistoryLimit) {
      filtered.removeRange(
          AppConstants.browsingHistoryLimit, filtered.length);
    }
    state = filtered;
    await _persist();
  }

  /// Removes a single entry from the history.
  Future<void> remove(String vnId) async {
    state = state.where((e) => e.vnId != vnId).toList();
    await _persist();
  }

  /// Clears the entire history.
  Future<void> clear() async {
    state = const [];
    await _persist();
  }
}

final browsingHistoryProvider =
    StateNotifierProvider<BrowsingHistoryService, List<HistoryEntry>>((ref) {
  return BrowsingHistoryService(ref.watch(sharedPreferencesProvider));
});

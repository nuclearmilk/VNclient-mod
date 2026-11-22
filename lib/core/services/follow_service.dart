import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/endpoints/vn_endpoint.dart';
import '../constants/app_constants.dart';
import '../providers/endpoints_provider.dart';
import '../providers/prefs_provider.dart';

/// A producer the user follows. Tracks the timestamp of the last new-work
/// check so that only releases dated after that point generate notifications.
class FollowedProducer {
  const FollowedProducer({
    required this.id,
    required this.name,
    this.lastSeenAt = 0,
    this.followedAt = 0,
  });

  final String id;
  final String name;
  /// MillisecondsSinceEpoch of the last check for new works. When the user
  /// first follows a producer this is set to "now"; after each check it is
  /// updated to the check time so subsequent checks only surface newer
  /// releases.
  final int lastSeenAt;
  final int followedAt;

  FollowedProducer copyWith({
    String? name,
    int? lastSeenAt,
    int? followedAt,
  }) {
    return FollowedProducer(
      id: id,
      name: name ?? this.name,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      followedAt: followedAt ?? this.followedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'lastSeenAt': lastSeenAt,
        'followedAt': followedAt,
      };

  factory FollowedProducer.fromJson(Map<String, dynamic> json) {
    return FollowedProducer(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      lastSeenAt: json['lastSeenAt'] as int? ?? 0,
      followedAt: json['followedAt'] as int? ?? 0,
    );
  }
}

/// A notification about a new work from a followed producer.
class ProducerNotification {
  const ProducerNotification({
    required this.id,
    required this.producerId,
    required this.producerName,
    required this.vnId,
    required this.vnTitle,
    this.released,
    this.createdAt = 0,
    this.read = false,
  });

  /// Unique id: `notif_<vnId>_<producerId>`.
  final String id;
  final String producerId;
  final String producerName;
  final String vnId;
  final String vnTitle;
  final String? released;
  final int createdAt;
  final bool read;

  ProducerNotification copyWith({bool? read}) {
    return ProducerNotification(
      id: id,
      producerId: producerId,
      producerName: producerName,
      vnId: vnId,
      vnTitle: vnTitle,
      released: released,
      createdAt: createdAt,
      read: read ?? this.read,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'producerId': producerId,
        'producerName': producerName,
        'vnId': vnId,
        'vnTitle': vnTitle,
        'released': released,
        'createdAt': createdAt,
        'read': read,
      };

  factory ProducerNotification.fromJson(Map<String, dynamic> json) {
    return ProducerNotification(
      id: json['id'] as String? ?? '',
      producerId: json['producerId'] as String? ?? '',
      producerName: json['producerName'] as String? ?? '',
      vnId: json['vnId'] as String? ?? '',
      vnTitle: json['vnTitle'] as String? ?? '',
      released: json['released'] as String?,
      createdAt: json['createdAt'] as int? ?? 0,
      read: json['read'] as bool? ?? false,
    );
  }
}

/// Formats a millisecond timestamp as `YYYY-MM-DD` for the VNDB `released`
/// filter, which accepts partial date strings.
String _millisToDateStr(int millis) {
  final dt = DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  final y = dt.year.toString();
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// Formats a millisecond timestamp as `YYYY-MM-DD HH:mm` for display.
String _millisToDisplay(int millis) {
  final dt = DateTime.fromMillisecondsSinceEpoch(millis);
  final y = dt.year.toString();
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  final h = dt.hour.toString().padLeft(2, '0');
  final min = dt.minute.toString().padLeft(2, '0');
  return '$y-$m-$d $h:$min';
}

/// State notifier owning the followed-producers list and the notifications.
///
/// Both collections are loaded synchronously from [SharedPreferences] to avoid
/// startup races, and new-work checks are batched and rate-limited with a
/// 30-minute cooldown.
class FollowService extends StateNotifier<FollowState> {
  FollowService(this._vnEndpoint, this._prefs) : super(_readInitial(_prefs));

  final VnEndpoint _vnEndpoint;
  final SharedPreferences _prefs;
  bool _checking = false;

  static const Duration _checkCooldown = Duration(minutes: 30);
  static const int _batchSize = 20;

  static FollowState _readInitial(SharedPreferences prefs) {
    final followedRaw = prefs.getString(AppConstants.followedProducersKey);
    final notifRaw = prefs.getString(AppConstants.producerNotificationsKey);
    final followed = <FollowedProducer>[];
    if (followedRaw != null && followedRaw.isNotEmpty) {
      try {
        final list = jsonDecode(followedRaw) as List;
        followed.addAll(
          list.map((e) => FollowedProducer.fromJson(e as Map<String, dynamic>)),
        );
      } catch (_) {
        // Ignore corrupt stored JSON.
      }
    }
    final notifs = <ProducerNotification>[];
    if (notifRaw != null && notifRaw.isNotEmpty) {
      try {
        final list = jsonDecode(notifRaw) as List;
        notifs.addAll(
          list.map(
            (e) => ProducerNotification.fromJson(e as Map<String, dynamic>),
          ),
        );
      } catch (_) {
        // Ignore corrupt stored JSON.
      }
    }
    return FollowState(followed: followed, notifications: notifs);
  }

  Future<void> _persist() async {
    await _prefs.setString(
      AppConstants.followedProducersKey,
      jsonEncode(state.followed.map((e) => e.toJson()).toList()),
    );
    await _prefs.setString(
      AppConstants.producerNotificationsKey,
      jsonEncode(state.notifications.map((e) => e.toJson()).toList()),
    );
  }

  bool isFollowing(String producerId) {
    return state.followed.any((p) => p.id == producerId);
  }

  Future<void> follow(String producerId, String name) async {
    if (isFollowing(producerId)) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final entry = FollowedProducer(
      id: producerId,
      name: name,
      lastSeenAt: now,
      followedAt: now,
    );
    state = FollowState(
      followed: [...state.followed, entry],
      notifications: state.notifications,
    );
    await _persist();
  }

  Future<void> unfollow(String producerId) async {
    state = FollowState(
      followed: state.followed.where((p) => p.id != producerId).toList(),
      notifications: state.notifications,
    );
    await _persist();
  }

  /// Marks all notifications as read (clears the red-dot badge).
  Future<void> markAllRead() async {
    if (state.notifications.every((n) => n.read)) return;
    state = FollowState(
      followed: state.followed,
      notifications:
          state.notifications.map((n) => n.copyWith(read: true)).toList(),
    );
    await _persist();
  }

  Future<void> dismissNotification(String notificationId) async {
    state = FollowState(
      followed: state.followed,
      notifications: state.notifications
          .where((n) => n.id != notificationId)
          .toList(),
    );
    await _persist();
  }

  Future<void> clearAllNotifications() async {
    state = FollowState(
      followed: state.followed,
      notifications: const [],
    );
    await _persist();
  }

  /// Checks followed producers in batches for VNs released after their last
  /// check time. Respects a 30-minute cooldown unless [force] is true.
  Future<int> checkForNewWorks({bool force = false}) async {
    if (_checking) return 0;
    final currentFollowed = state.followed;
    if (currentFollowed.isEmpty) return 0;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force) {
      final lastCheck = _prefs.getInt(AppConstants.followLastCheckKey) ?? 0;
      if (now - lastCheck < _checkCooldown.inMilliseconds) {
        return 0;
      }
    }

    _checking = true;
    int newCount = 0;
    try {
      final chunks = <List<FollowedProducer>>[];
      for (var i = 0; i < currentFollowed.length; i += _batchSize) {
        final end = (i + _batchSize).clamp(0, currentFollowed.length);
        chunks.add(currentFollowed.sublist(i, end));
      }

      final newNotifs = <ProducerNotification>[];
      final updatedById = <String, FollowedProducer>{
        for (final p in currentFollowed) p.id: p,
      };

      await Future.wait(chunks.map((chunk) async {
        try {
          var minThreshold = now;
          final dateByProducer = <String, String>{};
          for (final p in chunk) {
            final threshold = p.lastSeenAt > 0 ? p.lastSeenAt : now;
            if (threshold < minThreshold) minThreshold = threshold;
            dateByProducer[p.id] = _millisToDateStr(threshold);
          }
          final minDateStr = _millisToDateStr(minThreshold);
          final Object devFilter = chunk.length == 1
              ? ['developer', '=', ['id', '=', chunk.first.id]]
              : [
                  'or',
                  ...chunk.map((p) => ['developer', '=', ['id', '=', p.id]]),
                ];

          final result = await _vnEndpoint.query(
            filters: [
              'and',
              devFilter,
              ['released', '>=', minDateStr],
            ],
            fields: 'title, released, developers{id}',
            sort: 'released',
            reverse: true,
            results: 100,
            page: 1,
          );

          final chunkById = {for (final p in chunk) p.id: p};
          for (final vn in result.results) {
            for (final dev in vn.developers) {
              final producer = chunkById[dev.id];
              if (producer == null) continue;
              final pDateStr = dateByProducer[producer.id]!;
              if (vn.released != null &&
                  vn.released!.compareTo(pDateStr) < 0) {
                continue;
              }
              newNotifs.add(ProducerNotification(
                id: 'notif_${vn.id}_${producer.id}',
                producerId: producer.id,
                producerName: producer.name,
                vnId: vn.id,
                vnTitle: vn.title,
                released: vn.released,
                createdAt: now,
              ));
            }
          }
          for (final p in chunk) {
            updatedById[p.id] = p.copyWith(lastSeenAt: now);
          }
        } catch (_) {
          // Network/API errors for a chunk shouldn't abort other chunks.
        }
      }));

      if (!mounted) return 0;

      final updatedFollowed =
          state.followed.map((p) => updatedById[p.id] ?? p).toList();
      await _prefs.setInt(AppConstants.followLastCheckKey, now);

      if (newNotifs.isNotEmpty) {
        final existing = state.notifications;
        final existingIds = existing.map((e) => e.id).toSet();
        final toAdd =
            newNotifs.where((n) => !existingIds.contains(n.id)).toList();
        if (toAdd.isNotEmpty) {
          newCount = toAdd.length;
          final merged = [...toAdd, ...existing]
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
          state = FollowState(
            followed: updatedFollowed,
            notifications: merged,
          );
          await _persist();
          return newCount;
        }
      }

      state = FollowState(
        followed: updatedFollowed,
        notifications: state.notifications,
      );
      await _persist();
    } finally {
      _checking = false;
    }
    return newCount;
  }
}

/// Immutable view of the followed-producers and notifications state.
class FollowState {
  const FollowState({
    this.followed = const [],
    this.notifications = const [],
  });

  final List<FollowedProducer> followed;
  final List<ProducerNotification> notifications;

  bool get hasUnread => notifications.any((n) => !n.read);
  int get unreadCount => notifications.where((n) => !n.read).length;
}

final followServiceProvider =
    StateNotifierProvider<FollowService, FollowState>((ref) {
  return FollowService(
    ref.watch(vnEndpointProvider),
    ref.watch(sharedPreferencesProvider),
  );
});

/// Helper exposed for the follow-list page to render the last-check time.
String formatLastSeenAt(int millis) => _millisToDisplay(millis);

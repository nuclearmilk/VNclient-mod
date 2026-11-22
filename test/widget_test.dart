import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:vndb_app/core/api/vndb_client.dart';
import 'package:vndb_app/core/models/user_info.dart';
import 'package:vndb_app/core/models/vn.dart';
import 'package:vndb_app/core/providers/auth_provider.dart';
import 'package:vndb_app/core/providers/cache_utils.dart';
import 'package:vndb_app/core/providers/prefs_provider.dart';
import 'package:vndb_app/core/providers/theme_provider.dart';
import 'package:vndb_app/core/services/update_checker.dart';
import 'package:vndb_app/core/services/vndb_web_length_service.dart';
import 'package:vndb_app/core/theme/title_resolver.dart';

class _FakeVndbClient extends VndbClient {
  _FakeVndbClient(this._handler);

  final Future<Map<String, dynamic>> Function(String path) _handler;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) {
    return _handler(path);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureChannel, (call) async => null);

  group('TitleResolver.resolve', () {
    const vn = Vn(
      id: 'v1',
      title: 'Subahibi',
      alttitle: '素晴らしき日々',
      titles: [
        VnTitle(lang: 'en', title: 'Wonderful Everyday', main: false),
        VnTitle(lang: 'ja', title: '素晴らしき日々', main: true),
        VnTitle(lang: 'zh-Hans', title: '美好的每一天', main: false),
      ],
    );

    test('respects romanized mode even when Chinese title exists', () {
      expect(
        TitleResolver.resolve(vn, TitleDisplayMode.romanized),
        'Subahibi',
      );
    });

    test('respects japanese mode even when Chinese title exists', () {
      expect(
        TitleResolver.resolve(vn, TitleDisplayMode.japanese),
        '素晴らしき日々',
      );
    });

    test('returns Chinese title in chinese mode', () {
      expect(
        TitleResolver.resolve(vn, TitleDisplayMode.chinese),
        '美好的每一天',
      );
    });
  });

  group('SwrNotifier', () {
    test('emits cached data synchronously and updates after refresh', () async {
      SharedPreferences.setMockInitialValues({
        'test_key': '{"value":"stale"}',
      });
      final prefs = await SharedPreferences.getInstance();

      final notifier = SwrNotifier<String>(
        prefs: prefs,
        cacheKey: 'test_key',
        fetcher: () async => {'value': 'fresh'},
        parser: (json) => json['value'] as String,
      );

      expect(notifier.state.valueOrNull, 'stale');
      await Future<void>.delayed(Duration.zero);
      expect(notifier.state.valueOrNull, 'fresh');
      expect(prefs.getString('test_key'), '{"value":"fresh"}');
      notifier.dispose();
    });

    test('keeps cached data when refresh fails', () async {
      SharedPreferences.setMockInitialValues({
        'test_key': '{"value":"cached"}',
      });
      final prefs = await SharedPreferences.getInstance();

      final notifier = SwrNotifier<String>(
        prefs: prefs,
        cacheKey: 'test_key',
        fetcher: () async => throw VndbApiException(500, 'Server error'),
        parser: (json) => json['value'] as String,
      );

      expect(notifier.state.valueOrNull, 'cached');
      await notifier.refresh();
      expect(notifier.state.hasValue, isTrue);
      expect(notifier.state.valueOrNull, 'cached');
      notifier.dispose();
    });
  });

  group('AuthNotifier optimistic startup', () {
    test('starts authenticated immediately from PreloadedAuth and keeps session on non-401 error', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final client = _FakeVndbClient(
        (_) async => throw VndbApiException(0, 'Network timeout'),
      );
      const preloaded = PreloadedAuth(
        token: 'tok-123',
        user: UserInfo(
          id: 'u1',
          username: 'tester',
          permissions: ['listread', 'listwrite'],
        ),
      );

      final notifier = AuthNotifier(client, prefs, preloaded);
      expect(notifier.state.status, AuthStatus.authenticated);
      expect(notifier.state.isAuthenticated, isTrue);
      expect(notifier.state.user?.id, 'u1');
      expect(client.token, 'tok-123');

      await Future<void>.delayed(Duration.zero);
      expect(notifier.state.status, AuthStatus.authenticated);
      expect(notifier.state.isAuthenticated, isTrue);
      notifier.dispose();
    });

    test('clears session when background /authinfo returns 401', () async {
      SharedPreferences.setMockInitialValues({
        'vndb_user_id': 'u1',
        'vndb_username': 'tester',
      });
      final prefs = await SharedPreferences.getInstance();
      final client = _FakeVndbClient(
        (_) async => throw VndbApiException(401, 'Unauthorized'),
      );
      const preloaded = PreloadedAuth(
        token: 'bad-tok',
        user: UserInfo(id: 'u1', username: 'tester', permissions: ['listread']),
      );

      final notifier = AuthNotifier(client, prefs, preloaded);
      expect(notifier.state.status, AuthStatus.authenticated);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(notifier.state.status, AuthStatus.unauthenticated);
      expect(notifier.state.isAuthenticated, isFalse);
      expect(client.token, isNull);
      expect(prefs.getString('vndb_user_id'), isNull);
      notifier.dispose();
    });
  });

  group('VndbWebLengthService helpers', () {
    test('formatVndbIntDate formats partial and TBA dates', () {
      expect(formatVndbIntDate(20200131), '2020-01-31');
      expect(formatVndbIntDate(20200599), '2020-05');
      expect(formatVndbIntDate(20209999), '2020');
      expect(formatVndbIntDate(99999999), 'TBA');
      expect(formatVndbIntDate(0), 'TBA');
      expect(formatVndbIntDate(null), 'TBA');
    });

    test('parseLengthVoteHtml extracts VNLengthVote payload from pagevars', () {
      const sampleHtml = '''
<html><head><title>Edit play time</title></head><body>
<div id="widget1"></div>
<script type="application/json" id="pagevars">{"widget":{"VNLengthVote":[[1,{"vid":"v23740","title":"9-nine-","maycount":true,"votes":[{"id":123,"rid":["r66012"],"lang":["zh-Hans"],"length":630,"speed":1,"private":false,"notes":"all routes"}],"releases":[{"id":"r66012","title":"9-nine- Episode 1","alttitle":"","released":20200131,"rtype":"complete","lang":["zh-Hans","en"],"platforms":["win"]}]}]]}}</script>
</body></html>
''';
      final parsed = parseLengthVoteHtml(sampleHtml);
      expect(parsed, isNotNull);
      expect(parsed!.vid, 'v23740');
      expect(parsed.maycount, isTrue);
      expect(parsed.votes, hasLength(1));
      expect(parsed.votes.first.id, 123);
      expect(parsed.votes.first.hours, 10);
      expect(parsed.votes.first.minutes, 30);
      expect(parsed.votes.first.speed, 1);
      expect(parsed.releases, hasLength(1));
      expect(parsed.releases.first.formattedDate, '2020-01-31');

      expect(
        parseLengthVoteHtml('<html><body>No widget</body></html>'),
        isNull,
      );
    });

    test('LengthVoteEntry.toSubmitJson clears speed when private', () {
      const privateEntry = LengthVoteEntry(
        id: -1,
        rid: ['r1'],
        lang: ['ja'],
        length: 120,
        speed: 1,
        private: true,
        notes: 'secret',
      );
      expect(privateEntry.toSubmitJson()['speed'], isNull);
      expect(privateEntry.toSubmitJson()['private'], isTrue);

      const countedEntry = LengthVoteEntry(
        id: 10,
        rid: ['r1'],
        lang: ['ja'],
        length: 120,
        speed: 2,
        private: false,
        notes: 'fast',
      );
      expect(countedEntry.toSubmitJson()['speed'], 2);
      expect(countedEntry.toSubmitJson()['private'], isFalse);
    });

    test('extractAuthCookieFromHeaders parses vndb_auth cleanly', () {
      final cookie = extractAuthCookieFromHeaders([
        'vndb_samesite=1; Path=/; HttpOnly',
        'vndb_auth=0123456789abcdef0123456789abcdef01234567.u123; Path=/; Secure; HttpOnly',
      ]);
      expect(
        cookie,
        '0123456789abcdef0123456789abcdef01234567.u123',
      );
      expect(extractAuthCookieFromHeaders(['other=1']), isNull);
    });
  });

  group('UpdateChecker.compareVersions', () {
    test('compares semantic versions with optional prefixes and suffixes', () {
      expect(UpdateChecker.compareVersions('1.3.11', '1.3.10'), greaterThan(0));
      expect(
        UpdateChecker.compareVersions('v1.3.11-mod', '1.3.10'),
        greaterThan(0),
      );
      expect(UpdateChecker.compareVersions('1.3.11', 'v1.3.11+16'), 0);
      expect(UpdateChecker.compareVersions('1.3.9', '1.3.10'), lessThan(0));
    });
  });
}

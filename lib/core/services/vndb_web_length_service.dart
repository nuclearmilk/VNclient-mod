import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../constants/app_constants.dart';

/// Thrown when the user needs to sign in to the VNDB website before editing
/// play time votes.
class VndbWebAuthRequiredException implements Exception {
  VndbWebAuthRequiredException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Thrown when a visual novel has no eligible releases for play time voting.
class VndbLengthVoteUnavailableException implements Exception {
  VndbLengthVoteUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Thrown when a play time vote request fails.
class VndbLengthVoteException implements Exception {
  VndbLengthVoteException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A release eligible for play time voting on a visual novel.
class LengthVoteRelease {
  const LengthVoteRelease({
    required this.id,
    required this.title,
    this.alttitle = '',
    this.released = 0,
    this.rtype = '',
    this.lang = const [],
    this.platforms = const [],
  });

  final String id;
  final String title;
  final String alttitle;
  final int released;
  final String rtype;
  final List<String> lang;
  final List<String> platforms;

  String get formattedDate => formatVndbIntDate(released);

  factory LengthVoteRelease.fromJson(Map<String, dynamic> json) {
    return LengthVoteRelease(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      alttitle: json['alttitle']?.toString() ?? '',
      released: (json['released'] as num?)?.toInt() ?? 0,
      rtype: json['rtype']?.toString() ?? '',
      lang: (json['lang'] as List? ?? [])
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toList(),
      platforms: (json['platforms'] as List? ?? [])
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toList(),
    );
  }
}

/// A single playthrough / length vote entry on VNDB.
class LengthVoteEntry {
  const LengthVoteEntry({
    required this.id,
    this.rid = const [],
    this.lang = const [],
    this.length = 0,
    this.speed,
    this.private = false,
    this.notes = '',
  });

  /// Positive for existing server entries; negative (`-1, -2, ...`) for new ones.
  final int id;
  final List<String> rid;
  final List<String> lang;

  /// Total play time in minutes (1..26159).
  final int length;

  /// `0` = Slow, `1` = Normal, `2` = Fast, `null` = Uncounted / Private.
  final int? speed;
  final bool private;
  final String notes;

  int get hours => length ~/ 60;
  int get minutes => length % 60;

  factory LengthVoteEntry.fromJson(Map<String, dynamic> json) {
    return LengthVoteEntry(
      id: (json['id'] as num?)?.toInt() ?? -1,
      rid: (json['rid'] as List? ?? [])
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toList(),
      lang: (json['lang'] as List? ?? [])
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toList(),
      length: (json['length'] as num?)?.toInt() ?? 0,
      speed: (json['speed'] as num?)?.toInt(),
      private: json['private'] as bool? ?? false,
      notes: json['notes']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toSubmitJson() => {
        'id': id,
        'rid': rid,
        'lang': lang,
        'length': length,
        'speed': private ? null : speed,
        'private': private,
        'notes': notes,
      };
}

/// Form payload embedded by VNDB on `/<vid>/lengthvote`.
class LengthVoteFormData {
  const LengthVoteFormData({
    required this.vid,
    required this.title,
    required this.maycount,
    required this.votes,
    required this.releases,
  });

  final String vid;
  final String title;
  final bool maycount;
  final List<LengthVoteEntry> votes;
  final List<LengthVoteRelease> releases;

  factory LengthVoteFormData.fromJson(Map<String, dynamic> json) {
    return LengthVoteFormData(
      vid: json['vid']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      maycount: json['maycount'] as bool? ?? true,
      votes: (json['votes'] as List? ?? [])
          .whereType<Map>()
          .map((e) => LengthVoteEntry.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      releases: (json['releases'] as List? ?? [])
          .whereType<Map>()
          .map((e) => LengthVoteRelease.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
    );
  }
}

/// Formats VNDB integer release dates (e.g. `20200131`, `20200599`, `20209999`, `99999999`).
String formatVndbIntDate(int? dateInt) {
  if (dateInt == null || dateInt <= 0 || dateInt >= 99990000) return 'TBA';
  final y = dateInt ~/ 10000;
  final m = (dateInt ~/ 100) % 100;
  final d = dateInt % 100;
  if (m >= 99 || m == 0) return '$y';
  final mStr = m.toString().padLeft(2, '0');
  if (d >= 99 || d == 0) return '$y-$mStr';
  final dStr = d.toString().padLeft(2, '0');
  return '$y-$mStr-$dStr';
}

/// Parses `<script type="application/json" id="pagevars">` from VNDB HTML and
/// extracts the `VNLengthVote` widget data, or returns `null` when absent.
LengthVoteFormData? parseLengthVoteHtml(String html) {
  final match = RegExp(
    r'<script[^>]*\bid="pagevars"[^>]*>([\s\S]*?)</script>',
    caseSensitive: false,
  ).firstMatch(html);
  if (match == null) return null;

  final rawJson = match.group(1)?.trim();
  if (rawJson == null || rawJson.isEmpty) return null;

  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map) return null;
    final widgets = decoded['widget'];
    if (widgets is! Map) return null;
    final list = widgets['VNLengthVote'];
    if (list is! List || list.isEmpty) return null;
    final first = list.first;
    if (first is! List || first.length < 2) return null;
    final payload = first[1];
    if (payload is! Map) return null;
    return LengthVoteFormData.fromJson(Map<String, dynamic>.from(payload));
  } catch (_) {
    return null;
  }
}

/// Extracts `vndb_auth` cookie value from HTTP `Set-Cookie` header lines.
String? extractAuthCookieFromHeaders(List<String>? setCookies) {
  if (setCookies == null) return null;
  for (final header in setCookies) {
    final firstPart = header.split(';').first.trim();
    if (firstPart.startsWith('vndb_auth=')) {
      final val = firstPart.substring('vndb_auth='.length).trim();
      if (val.isNotEmpty) return val;
    }
  }
  return null;
}

/// Extracts `vndb_auth` value from a serialized `name=value; ...` cookie string.
String? extractAuthCookieFromHeaderString(String? cookieHeader) {
  if (cookieHeader == null || cookieHeader.isEmpty) return null;
  for (final part in cookieHeader.split(';')) {
    final trimmed = part.trim();
    final eq = trimmed.indexOf('=');
    if (eq <= 0) continue;
    final name = trimmed.substring(0, eq).trim();
    final val = trimmed.substring(eq + 1).trim();
    if (name == 'vndb_auth' && val.isNotEmpty) {
      return val;
    }
  }
  return null;
}

/// Human-readable label for a VNDB language code.
String vndbLanguageLabel(String code) {
  const map = <String, String>{
    'ja': '日语 (ja)',
    'zh-Hans': '简体中文 (zh-Hans)',
    'zh-Hant': '繁体中文 (zh-Hant)',
    'zh': '中文 (zh)',
    'en': '英语 (en)',
    'ko': '韩语 (ko)',
    'ru': '俄语 (ru)',
    'fr': '法语 (fr)',
    'de': '德语 (de)',
    'es': '西班牙语 (es)',
    'pt-br': '葡萄牙语-巴西 (pt-br)',
    'pt-pt': '葡萄牙语 (pt-pt)',
    'vi': '越南语 (vi)',
    'th': '泰语 (th)',
    'it': '意大利语 (it)',
    'pl': '波兰语 (pl)',
    'uk': '乌克兰语 (uk)',
    'id': '印尼语 (id)',
  };
  return map[code] ?? code;
}

/// Bridges the official VNDB website endpoints (`/u/login`, `/<vid>/lengthvote`,
/// `/js/UserLogin.json`, `/js/VNLengthVote.json`) so play time voting works
/// natively with full official parity.
class VndbWebLengthService {
  VndbWebLengthService({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: AppConstants.siteBaseUrl,
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 30),
                validateStatus: (s) => s != null && s < 500,
                followRedirects: true,
              ),
            )..transformer = BackgroundTransformer();

  final Dio _dio;
  static const _storage = FlutterSecureStorage();
  static const _cookieKey = 'vndb_web_cookies';
  static const _webUserKey = 'vndb_web_user';
  static const _webPassKey = 'vndb_web_pass';

  Future<({String user, String pass})?> readSavedCredentials() async {
    try {
      final results = await Future.wait<String?>([
        _storage
            .read(key: _webUserKey)
            .then<String?>((v) => v, onError: (_, __) => null),
        _storage
            .read(key: _webPassKey)
            .then<String?>((v) => v, onError: (_, __) => null),
      ]);
      final u = results[0]?.trim() ?? '';
      final p = results[1] ?? '';
      if (u.isEmpty || p.isEmpty) return null;
      return (user: u, pass: p);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _getAuthCookie() async {
    try {
      final raw = await _storage.read(key: _cookieKey);
      final fromStorage = extractAuthCookieFromHeaderString(raw);
      if (fromStorage != null) return fromStorage;
    } catch (_) {
      // Ignore secure storage error and check WebView cookie jar.
    }

    try {
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri(AppConstants.siteBaseUrl),
      );
      if (cookies.isNotEmpty) {
        final raw = cookies.map((c) => '${c.name}=${c.value}').join('; ');
        final fromWebView = extractAuthCookieFromHeaderString(raw);
        if (fromWebView != null) {
          await _storage
              .write(key: _cookieKey, value: raw)
              .then<void>((_) {}, onError: (_, __) {});
          return fromWebView;
        }
      }
    } catch (_) {
      // CookieManager may be unavailable in headless tests or before WebView init.
    }
    return null;
  }

  Future<void> _saveAuthCookie(String authValue) async {
    try {
      final existing = await _storage.read(key: _cookieKey);
      final pairs = <String, String>{};
      if (existing != null && existing.isNotEmpty) {
        for (final part in existing.split(';')) {
          final trimmed = part.trim();
          final eq = trimmed.indexOf('=');
          if (eq <= 0) continue;
          pairs[trimmed.substring(0, eq).trim()] =
              trimmed.substring(eq + 1).trim();
        }
      }
      pairs['vndb_auth'] = authValue;
      pairs['vndb_samesite'] = '1';
      final serialized =
          pairs.entries.map((e) => '${e.key}=${e.value}').join('; ');
      await _storage.write(key: _cookieKey, value: serialized);
    } catch (_) {
      // Best-effort persistence.
    }

    try {
      await CookieManager.instance().setCookie(
        url: WebUri(AppConstants.siteBaseUrl),
        name: 'vndb_auth',
        value: authValue,
        domain: '.vndb.org',
        isSecure: true,
        isHttpOnly: true,
      );
    } catch (_) {
      // Best-effort WebView cookie sync.
    }
  }

  Future<void> _clearAuthCookie() async {
    try {
      final existing = await _storage.read(key: _cookieKey);
      if (existing != null && existing.isNotEmpty) {
        final filtered = existing
            .split(';')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty && !e.startsWith('vndb_auth='))
            .join('; ');
        if (filtered.isEmpty) {
          await _storage.delete(key: _cookieKey);
        } else {
          await _storage.write(key: _cookieKey, value: filtered);
        }
      }
    } catch (_) {
      // Ignore storage error.
    }
  }

  /// Signs in to the VNDB website via `/js/UserLogin.json` and stores the
  /// resulting `vndb_auth` session cookie.
  Future<void> login(
    String username,
    String password, {
    bool saveCredentials = false,
  }) async {
    final trimmedUser = username.trim();
    if (trimmedUser.isEmpty || password.isEmpty) {
      throw VndbLengthVoteException('请输入用户名和密码');
    }
    try {
      final response = await _dio.post<dynamic>(
        '/js/UserLogin.json',
        data: {'username': trimmedUser, 'password': password},
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'Origin': AppConstants.siteBaseUrl,
            'Referer': '${AppConstants.siteBaseUrl}/u/login',
            'Sec-Fetch-Site': 'same-origin',
          },
        ),
      );
      if (response.statusCode == 429) {
        throw VndbLengthVoteException('登录请求过于频繁，请稍后再试');
      }
      if (response.statusCode != 200) {
        throw VndbLengthVoteException('登录失败 (HTTP ${response.statusCode})');
      }
      final data = response.data;
      if (data is Map) {
        if (data['_err'] != null) {
          throw VndbLengthVoteException(data['_err'].toString());
        }
        if (data['insecurepass'] == 1) {
          throw VndbLengthVoteException(
            'VNDB 提示该密码存在泄露风险，请先在网页端修改密码后再登录',
          );
        }
        if (data['_redir'] != null) {
          throw VndbLengthVoteException('账号需要前往 VNDB 网页端确认状态');
        }
      }
      final setCookies = response.headers['set-cookie'];
      final authCookie = extractAuthCookieFromHeaders(setCookies);
      if (authCookie == null) {
        throw VndbLengthVoteException('未获取到网页会话 Cookie，请尝试使用内嵌浏览器登录');
      }
      await _saveAuthCookie(authCookie);
      if (saveCredentials) {
        await Future.wait([
          _storage.write(key: _webUserKey, value: trimmedUser),
          _storage.write(key: _webPassKey, value: password),
        ]);
      }
    } on DioException catch (e) {
      throw VndbLengthVoteException('网络错误: ${e.message ?? e.type.name}');
    }
  }

  /// Fetches the user's current play time votes and eligible releases for [vnId].
  Future<LengthVoteFormData> fetchForm(String vnId) async {
    var autoLoggedIn = false;
    var authCookie = await _getAuthCookie();
    if (authCookie == null) {
      final creds = await readSavedCredentials();
      if (creds == null) {
        throw VndbWebAuthRequiredException('请先登录 VNDB 网页账号以提交游玩时长');
      }
      await login(creds.user, creds.pass);
      autoLoggedIn = true;
      authCookie = await _getAuthCookie();
      if (authCookie == null) {
        throw VndbWebAuthRequiredException('请先登录 VNDB 网页账号以提交游玩时长');
      }
    }

    try {
      var response = await _requestLengthVotePage(vnId, authCookie);
      var html = response.data?.toString() ?? '';
      var needsAuth = response.statusCode == 403 ||
          html.contains('You need to be logged in to perform this action');

      if (needsAuth && !autoLoggedIn) {
        await _clearAuthCookie();
        final creds = await readSavedCredentials();
        if (creds != null) {
          await login(creds.user, creds.pass);
          final refreshedCookie = await _getAuthCookie();
          if (refreshedCookie != null) {
            response = await _requestLengthVotePage(vnId, refreshedCookie);
            html = response.data?.toString() ?? '';
            needsAuth = response.statusCode == 403 ||
                html.contains('You need to be logged in to perform this action');
          }
        }
      }

      if (needsAuth) {
        await _clearAuthCookie();
        throw VndbWebAuthRequiredException('网页会话已过期，请重新登录 VNDB 账号');
      }
      if (response.statusCode == 404) {
        throw VndbLengthVoteUnavailableException('未找到作品 $vnId');
      }
      if (response.statusCode != 200) {
        throw VndbLengthVoteException('加载失败 (HTTP ${response.statusCode})');
      }

      final parsed = parseLengthVoteHtml(html);
      if (parsed == null) {
        if (html.contains('not (yet) available') ||
            html.contains('eligible for voting')) {
          throw VndbLengthVoteUnavailableException(
            '该作品暂无可投票的已发行版本（未发售或仅有试玩版）',
          );
        }
        throw VndbLengthVoteException('无法解析游玩时长页面数据');
      }
      return parsed;
    } on DioException catch (e) {
      throw VndbLengthVoteException('网络错误: ${e.message ?? e.type.name}');
    }
  }

  Future<Response<String>> _requestLengthVotePage(
    String vnId,
    String authCookie,
  ) {
    return _dio.get<String>(
      '/$vnId/lengthvote',
      options: Options(
        responseType: ResponseType.plain,
        headers: {
          'Cookie': 'vndb_auth=$authCookie; vndb_samesite=1',
          'Accept': 'text/html',
          'Referer': '${AppConstants.siteBaseUrl}/$vnId',
          'Sec-Fetch-Site': 'same-origin',
        },
      ),
    );
  }

  /// Submits the complete list of playthrough entries for [vnId] via
  /// `POST /js/VNLengthVote.json`.
  Future<void> submitVotes(
    String vnId,
    List<LengthVoteEntry> votes,
  ) async {
    final authCookie = await _getAuthCookie();
    if (authCookie == null) {
      throw VndbWebAuthRequiredException('请先登录 VNDB 网页账号');
    }

    try {
      final response = await _dio.post<dynamic>(
        '/js/VNLengthVote.json',
        data: {
          'vid': vnId,
          'votes': votes.map((v) => v.toSubmitJson()).toList(),
        },
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'Cookie': 'vndb_auth=$authCookie; vndb_samesite=1',
            'Origin': AppConstants.siteBaseUrl,
            'Referer': '${AppConstants.siteBaseUrl}/$vnId/lengthvote',
            'Sec-Fetch-Site': 'same-origin',
          },
        ),
      );

      if (response.statusCode == 403) {
        await _clearAuthCookie();
        throw VndbWebAuthRequiredException('网页会话已过期或缺少权限，请重新登录');
      }
      if (response.statusCode == 429) {
        throw VndbLengthVoteException('操作过于频繁，请稍后再试');
      }
      if (response.statusCode != 200) {
        throw VndbLengthVoteException('提交失败 (HTTP ${response.statusCode})');
      }
      final data = response.data;
      if (data is Map && data['_err'] != null) {
        throw VndbLengthVoteException(data['_err'].toString());
      }
    } on DioException catch (e) {
      throw VndbLengthVoteException('网络错误: ${e.message ?? e.type.name}');
    }
  }
}

final vndbWebLengthServiceProvider = Provider<VndbWebLengthService>((ref) {
  return VndbWebLengthService();
});

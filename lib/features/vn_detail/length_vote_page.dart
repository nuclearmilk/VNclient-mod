import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';
import '../../core/services/vndb_web_length_service.dart';
import '../../widgets/vndb_icons.dart';

enum _VoteType { counted, uncounted, private }

class _EditablePlaythrough {
  _EditablePlaythrough({
    required this.id,
    required List<String> rid,
    required List<String> lang,
    required int initialMinutes,
    required _VoteType voteType,
    required this.speed,
    required String notes,
  })  : rid = List<String>.from(rid),
        lang = List<String>.from(lang),
        _voteType = voteType,
        hoursController = TextEditingController(
          text: initialMinutes > 0 && (initialMinutes ~/ 60) > 0
              ? '${initialMinutes ~/ 60}'
              : '',
        ),
        minutesController = TextEditingController(
          text: initialMinutes > 0 && (initialMinutes % 60) > 0
              ? '${initialMinutes % 60}'
              : '',
        ),
        notesController = TextEditingController(text: notes);

  final int id;
  final List<String> rid;
  final List<String> lang;
  _VoteType _voteType;
  int? speed; // 0 = Slow, 1 = Normal, 2 = Fast, null = unselected
  final TextEditingController hoursController;
  final TextEditingController minutesController;
  final TextEditingController notesController;

  _VoteType get voteType => _voteType;
  set voteType(_VoteType next) {
    _voteType = next;
    if (next != _VoteType.counted) {
      speed = null;
    }
  }

  int get hours => int.tryParse(hoursController.text.trim()) ?? 0;
  int get minutes => int.tryParse(minutesController.text.trim()) ?? 0;
  int get totalMinutes => hours * 60 + minutes;

  String? validateTime() {
    if (totalMinutes <= 0) return '请输入游玩时长';
    if (hours > 435 || totalMinutes > 26159) {
      return '时长不能超过 435 小时 59 分钟';
    }
    if (minutes >= 60) return '分钟数需小于 60';
    return null;
  }

  String? validate() {
    if (rid.isEmpty) return '请选择至少一个游玩版本';
    if (lang.isEmpty) return '请选择至少一种游玩语言';
    final timeErr = validateTime();
    if (timeErr != null) return timeErr;
    if (voteType == _VoteType.counted &&
        (speed == null || speed! < 0 || speed! > 2)) {
      return '请选择阅读速度';
    }
    return null;
  }

  LengthVoteEntry toEntry() {
    return LengthVoteEntry(
      id: id,
      rid: List<String>.from(rid),
      lang: List<String>.from(lang),
      length: totalMinutes,
      speed: voteType == _VoteType.counted ? speed : null,
      private: voteType == _VoteType.private,
      notes: notesController.text.trim(),
    );
  }

  void dispose() {
    hoursController.dispose();
    minutesController.dispose();
    notesController.dispose();
  }
}

/// Full-featured native VNDB play time voting & editing page, matching the
/// official website (`/v<id>/lengthvote`).
class LengthVotePage extends ConsumerStatefulWidget {
  const LengthVotePage({
    super.key,
    required this.vnId,
    required this.vnTitle,
    this.currentLengthMinutes,
    this.currentLengthVotes,
  });

  final String vnId;
  final String vnTitle;
  final int? currentLengthMinutes;
  final int? currentLengthVotes;

  @override
  ConsumerState<LengthVotePage> createState() => _LengthVotePageState();
}

class _LengthVotePageState extends ConsumerState<LengthVotePage> {
  bool _loading = true;
  bool _needsLogin = false;
  bool _unavailable = false;
  String? _loadError;

  LengthVoteFormData? _formData;
  final List<_EditablePlaythrough> _items = [];
  int _nextTempId = -1;

  bool _submitting = false;
  String? _submitError;

  // Web login form state
  final _userController = TextEditingController();
  final _passController = TextEditingController();
  bool _saveCredentials = true;
  bool _loggingIn = false;
  String? _loginError;

  @override
  void initState() {
    super.initState();
    _prefillSavedCredentials();
    _load();
  }

  @override
  void dispose() {
    _clearPlaythroughs();
    _userController.dispose();
    _passController.dispose();
    super.dispose();
  }

  void _clearPlaythroughs() {
    for (final item in _items) {
      item.dispose();
    }
    _items.clear();
  }

  Future<void> _prefillSavedCredentials() async {
    final creds =
        await ref.read(vndbWebLengthServiceProvider).readSavedCredentials();
    if (!mounted || creds == null) return;
    if (_userController.text.isEmpty) _userController.text = creds.user;
    if (_passController.text.isEmpty) _passController.text = creds.pass;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _needsLogin = false;
      _unavailable = false;
      _loadError = null;
      _submitError = null;
    });

    try {
      final data =
          await ref.read(vndbWebLengthServiceProvider).fetchForm(widget.vnId);
      if (!mounted) return;
      _initFromFormData(data);
    } on VndbWebAuthRequiredException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _needsLogin = true;
        _loadError = e.message;
      });
    } on VndbLengthVoteUnavailableException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _unavailable = true;
        _loadError = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = e.toString();
      });
    }
  }

  void _initFromFormData(LengthVoteFormData data) {
    _clearPlaythroughs();
    _nextTempId = -1;
    _formData = data;

    if (data.votes.isEmpty) {
      _addPlaythrough(data);
    } else {
      for (final vote in data.votes) {
        final voteType = vote.private
            ? _VoteType.private
            : (vote.speed != null && data.maycount
                ? _VoteType.counted
                : _VoteType.uncounted);
        final item = _EditablePlaythrough(
          id: vote.id,
          rid: vote.rid,
          lang: vote.lang,
          initialMinutes: vote.length,
          voteType: voteType,
          speed: voteType == _VoteType.counted ? vote.speed : null,
          notes: vote.notes,
        );
        _syncLanguages(item, data.releases);
        _items.add(item);
      }
    }

    setState(() {
      _loading = false;
      _needsLogin = false;
      _unavailable = false;
      _loadError = null;
    });
  }

  void _addPlaythrough([LengthVoteFormData? explicitData]) {
    final data = explicitData ?? _formData;
    if (data == null || _items.length >= 5) return;

    final defaultRids = data.releases.length == 1
        ? <String>[data.releases.first.id]
        : <String>[];
    final item = _EditablePlaythrough(
      id: _nextTempId--,
      rid: defaultRids,
      lang: const [],
      initialMinutes: 0,
      voteType: data.maycount ? _VoteType.counted : _VoteType.uncounted,
      speed: null,
      notes: '',
    );
    _syncLanguages(item, data.releases);
    _items.add(item);
  }

  Set<String> _availableLangsFor(
    _EditablePlaythrough item,
    List<LengthVoteRelease> releases,
  ) {
    final langs = <String>{};
    for (final r in releases) {
      if (item.rid.contains(r.id)) {
        langs.addAll(r.lang);
      }
    }
    return langs;
  }

  void _syncLanguages(
    _EditablePlaythrough item,
    List<LengthVoteRelease> releases,
  ) {
    final avail = _availableLangsFor(item, releases);
    item.lang.removeWhere((l) => !avail.contains(l));
    if (avail.length == 1) {
      final only = avail.first;
      if (!item.lang.contains(only)) {
        item.lang
          ..clear()
          ..add(only);
      }
    }
  }

  Future<void> _performLogin() async {
    setState(() {
      _loggingIn = true;
      _loginError = null;
    });
    try {
      await ref.read(vndbWebLengthServiceProvider).login(
            _userController.text,
            _passController.text,
            saveCredentials: _saveCredentials,
          );
      if (!mounted) return;
      setState(() => _loggingIn = false);
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loggingIn = false;
        _loginError = e.toString();
      });
    }
  }

  Future<void> _openWebViewLogin() async {
    final url = Uri.encodeComponent('https://vndb.org/u/login');
    final title = Uri.encodeComponent('登录 VNDB');
    await context.push('/webview?url=$url&title=$title');
    if (mounted) {
      await _load();
    }
  }

  Future<void> _pickReleases(_EditablePlaythrough item) async {
    final data = _formData;
    if (data == null) return;
    final selected = Set<String>.from(item.rid);

    final updated = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => _ReleasePickerSheet(
        releases: data.releases,
        initialSelected: selected,
      ),
    );
    if (updated == null || !mounted) return;
    setState(() {
      item.rid
        ..clear()
        ..addAll(updated);
      _syncLanguages(item, data.releases);
    });
  }

  bool get _canSubmit {
    if (_submitting || _formData == null) return false;
    for (final item in _items) {
      if (item.validate() != null) return false;
    }
    return true;
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _submitting = true;
      _submitError = null;
    });

    try {
      final entries = _items.map((e) => e.toEntry()).toList();
      await ref
          .read(vndbWebLengthServiceProvider)
          .submitVotes(widget.vnId, entries);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            entries.isEmpty ? '已删除该作品的游玩时长记录' : '游玩时长已保存',
          ),
        ),
      );
      Navigator.of(context).pop(true);
    } on VndbWebAuthRequiredException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _needsLogin = true;
        _loadError = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitError = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('游玩时长投票'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bar_chart),
            tooltip: '查看官网统计与投票列表',
            onPressed: () => openWebView(
              context,
              'https://vndb.org/${widget.vnId}/lengthvotes',
              title: '时长投票统计',
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          _HeaderCard(
            vnId: widget.vnId,
            vnTitle: widget.vnTitle,
            currentLengthMinutes: widget.currentLengthMinutes,
            currentLengthVotes: widget.currentLengthVotes,
          ),
          Expanded(child: _buildContent()),
        ],
      ),
      bottomNavigationBar: _loading || _needsLogin || _unavailable || _formData == null
          ? null
          : SafeArea(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  border: Border(
                    top: BorderSide(
                      color: Theme.of(context).dividerColor,
                    ),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_submitError != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          _submitError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    Row(
                      children: [
                        OutlinedButton(
                          onPressed: _submitting
                              ? null
                              : () => Navigator.of(context).pop(false),
                          child: const Text('取消'),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _canSubmit ? _submit : null,
                            icon: _submitting
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.check),
                            label: Text(
                              _items.isEmpty ? '提交（清空记录）' : '提交保存',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildContent() {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('正在加载游玩时长数据…'),
          ],
        ),
      );
    }

    if (_needsLogin) {
      return _buildLoginView();
    }

    if (_unavailable || (_loadError != null && _formData == null)) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _unavailable ? Icons.schedule_outlined : Icons.error_outline,
                size: 48,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 12),
              Text(
                _loadError ?? '加载失败',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              if (!_unavailable)
                FilledButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
            ],
          ),
        ),
      );
    }

    final data = _formData!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      children: [
        if (!data.maycount)
          Card(
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '该作品仍在开发中，你提交的游玩时长不会计入公开平均值。',
                      style: TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (_items.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  const Text('暂无周目记录'),
                  const SizedBox(height: 6),
                  Text(
                    '点击下方"提交（清空记录）"将删除你在这部作品上的全部时长记录，或添加新的周目记录。',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        for (var i = 0; i < _items.length; i++)
          _buildPlaythroughCard(data, _items[i], i),
        if (_items.length < 5)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.add),
              label: Text('添加周目 (${_items.length}/5)'),
              onPressed: () => setState(() => _addPlaythrough()),
            ),
          ),
      ],
    );
  }

  Widget _buildLoginView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.login,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '登录 VNDB 网页账号',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _loadError ??
                    'VNDB 官方 API 暂不支持游玩时长接口，需要登录 VNDB 网页账号（会话长期有效，登录一次即可）。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _userController,
                decoration: const InputDecoration(
                  labelText: '用户名或邮箱',
                  prefixIcon: Icon(Icons.person),
                ),
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passController,
                decoration: const InputDecoration(
                  labelText: '密码',
                  prefixIcon: Icon(Icons.lock),
                ),
                obscureText: true,
                onSubmitted: (_) => _loggingIn ? null : _performLogin(),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('保存账号密码到本地安全存储（与设置页共享）'),
                value: _saveCredentials,
                onChanged: (v) =>
                    setState(() => _saveCredentials = v ?? true),
              ),
              if (_loginError != null) ...[
                const SizedBox(height: 8),
                Text(
                  _loginError!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _loggingIn ? null : _performLogin,
                icon: _loggingIn
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.login),
                label: Text(_loggingIn ? '登录中…' : '登录并加载'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _loggingIn ? null : _openWebViewLogin,
                icon: const Icon(Icons.open_in_browser),
                label: const Text('使用内嵌浏览器登录'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlaythroughCard(
    LengthVoteFormData data,
    _EditablePlaythrough item,
    int index,
  ) {
    final releaseById = {for (final r in data.releases) r.id: r};
    final availLangs = _availableLangsFor(item, data.releases).toList()..sort();
    final canChangeRelease = !(data.releases.length == 1 &&
        item.rid.length == 1 &&
        item.rid.first == data.releases.first.id);
    final timeError = item.validateTime();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  _items.length > 1 ? '周目 #${index + 1}' : '游玩记录',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('删除此周目'),
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  onPressed: () {
                    setState(() {
                      _items.removeAt(index);
                      item.dispose();
                    });
                  },
                ),
              ],
            ),
            const Divider(height: 16),

            // 1. Releases
            const Text(
              '游玩版本 (Release)',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const SizedBox(height: 6),
            if (item.rid.isEmpty)
              Text(
                '请选择你游玩的发行版本',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.error,
                ),
              )
            else
              Column(
                children: [
                  for (final rid in item.rid)
                    Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest
                            .withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: _ReleaseSummaryRow(
                              rid: rid,
                              release: releaseById[rid],
                            ),
                          ),
                          if (canChangeRelease)
                            IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              tooltip: '移除版本',
                              visualDensity: VisualDensity.compact,
                              onPressed: () {
                                setState(() {
                                  item.rid.remove(rid);
                                  _syncLanguages(item, data.releases);
                                });
                              },
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            if (canChangeRelease)
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.album_outlined, size: 18),
                  label: Text(item.rid.isEmpty ? '选择版本' : '增删版本'),
                  onPressed: () => _pickReleases(item),
                ),
              ),

            // 2. Languages
            if (item.rid.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text(
                '游玩语言 (Language)',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
              const SizedBox(height: 6),
              if (availLangs.isEmpty)
                const Text('所选版本未标注语言', style: TextStyle(fontSize: 12))
              else if (availLangs.length == 1)
                Chip(
                  avatar: VndbIcons.langImage(availLangs.first, size: 16),
                  label: Text(vndbLanguageLabel(availLangs.first)),
                )
              else ...[
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final code in availLangs)
                      FilterChip(
                        avatar: VndbIcons.langImage(code, size: 16),
                        label: Text(vndbLanguageLabel(code)),
                        selected: item.lang.contains(code),
                        onSelected: (selected) {
                          setState(() {
                            if (selected) {
                              if (!item.lang.contains(code)) {
                                item.lang.add(code);
                              }
                            } else {
                              item.lang.remove(code);
                            }
                          });
                        },
                      ),
                  ],
                ),
                if (item.lang.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '请选择至少一种游玩语言',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ],

            // 3. Play time (hours + minutes)
            const SizedBox(height: 14),
            const Text(
              '游玩时长 (Play time)',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const SizedBox(height: 2),
            Text(
              '你通关这部作品花了多长时间？（精确计时最佳，估算也可以）',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: item.hoursController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: '小时',
                      suffixText: 'h',
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: item.minutesController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: '分钟',
                      suffixText: 'm',
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ],
            ),
            if (timeError != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  timeError,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),

            // 4. Vote type
            const SizedBox(height: 14),
            const Text(
              '投票类型 (Vote type)',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const SizedBox(height: 4),
            if (data.maycount)
              _RadioOptionTile(
                selected: item.voteType == _VoteType.counted,
                title: '计入平均 (Counted)',
                subtitle: '你的游玩时长将计入公开平均值',
                onTap: () => setState(() => item.voteType = _VoteType.counted),
              ),
            _RadioOptionTile(
              selected: item.voteType == _VoteType.uncounted,
              title: '不计入平均 (Uncounted)',
              subtitle: '仍会公开展示在列表，但不计入公开平均值',
              onTap: () => setState(() => item.voteType = _VoteType.uncounted),
            ),
            _RadioOptionTile(
              selected: item.voteType == _VoteType.private,
              title: '私密 (Private)',
              subtitle: '不计入平均值，且仅自己可见',
              onTap: () => setState(() => item.voteType = _VoteType.private),
            ),
            if (item.voteType == _VoteType.counted) ...[
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '提示：仅在通关全部普通/真结局后再选择"计入平均"；如果尚未通关，请选择"不计入平均"。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                '阅读速度 (Reading speed)',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
              const SizedBox(height: 4),
              _RadioOptionTile(
                selected: item.speed == 0,
                title: '较慢 (Slow)',
                subtitle: '例如语言熟练度较低，或在游戏玩法上花费了额外时间',
                onTap: () => setState(() => item.speed = 0),
              ),
              _RadioOptionTile(
                selected: item.speed == 1,
                title: '正常 (Normal)',
                subtitle: '未跳过内容，完整听完所有语音',
                onTap: () => setState(() => item.speed = 1),
              ),
              _RadioOptionTile(
                selected: item.speed == 2,
                title: '较快 (Fast)',
                subtitle: '阅读速度较快，或跳过语音与玩法',
                onTap: () => setState(() => item.speed = 2),
              ),
              if (item.speed == null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '请选择阅读速度',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],

            // 5. Notes
            const SizedBox(height: 14),
            const Text(
              '备注 (Notes)',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: item.notesController,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: '（可选）可补充说明：是否完成坏结局、是否使用攻略、如何计时等',
                isDense: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({
    required this.vnId,
    required this.vnTitle,
    this.currentLengthMinutes,
    this.currentLengthVotes,
  });

  final String vnId;
  final String vnTitle;
  final int? currentLengthMinutes;
  final int? currentLengthVotes;

  @override
  Widget build(BuildContext context) {
    final avgText = currentLengthMinutes != null
        ? '${currentLengthMinutes! ~/ 60}h ${currentLengthMinutes! % 60}m'
        : null;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.timer_outlined),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$vnId · $vnTitle',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  if (avgText != null || currentLengthVotes != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        [
                          if (avgText != null) '公开平均时长: $avgText',
                          if (currentLengthVotes != null)
                            '共 $currentLengthVotes 票',
                        ].join(' · '),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReleaseSummaryRow extends StatelessWidget {
  const _ReleaseSummaryRow({required this.rid, this.release});

  final String rid;
  final LengthVoteRelease? release;

  @override
  Widget build(BuildContext context) {
    final r = release;
    if (r == null) {
      return Text('已移动或删除的版本: $rid', style: const TextStyle(fontSize: 13));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (r.lang.isNotEmpty) ...[
              VndbIcons.langRow(r.lang, size: 14),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                r.title.isNotEmpty ? r.title : r.id,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Wrap(
          spacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              [
                r.id,
                r.formattedDate,
                if (r.rtype.isNotEmpty) r.rtype,
              ].join(' · '),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (r.platforms.isNotEmpty) VndbIcons.platRow(r.platforms, size: 12),
          ],
        ),
      ],
    );
  }
}

class _RadioOptionTile extends StatelessWidget {
  const _RadioOptionTile({
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool selected;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 20,
              color: color,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReleasePickerSheet extends StatefulWidget {
  const _ReleasePickerSheet({
    required this.releases,
    required this.initialSelected,
  });

  final List<LengthVoteRelease> releases;
  final Set<String> initialSelected;

  @override
  State<_ReleasePickerSheet> createState() => _ReleasePickerSheetState();
}

class _ReleasePickerSheetState extends State<_ReleasePickerSheet> {
  late final Set<String> _selected = Set<String>.from(widget.initialSelected);
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = widget.releases.where((r) {
      if (_query.isEmpty) return true;
      final q = _query.toLowerCase();
      return r.title.toLowerCase().contains(q) ||
          r.alttitle.toLowerCase().contains(q) ||
          r.id.toLowerCase().contains(q) ||
          r.lang.any((l) => l.toLowerCase().contains(q));
    }).toList();

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.78,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '选择游玩的发行版本',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(_selected),
                  child: Text('确定 (${_selected.length})'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '搜索版本名称、ID 或语言代码…',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                suffixIcon: _query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      )
                    : null,
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
          ),
          Expanded(
            child: filtered.isEmpty
                ? const Center(child: Text('没有匹配的版本'))
                : ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (context, i) {
                      final r = filtered[i];
                      final checked = _selected.contains(r.id);
                      return CheckboxListTile(
                        value: checked,
                        controlAffinity: ListTileControlAffinity.leading,
                        onChanged: (v) {
                          setState(() {
                            if (v == true) {
                              _selected.add(r.id);
                            } else {
                              _selected.remove(r.id);
                            }
                          });
                        },
                        title: Text(
                          r.title.isNotEmpty ? r.title : r.id,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (r.alttitle.isNotEmpty && r.alttitle != r.title)
                              Text(
                                r.alttitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            const SizedBox(height: 2),
                            Wrap(
                              spacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                if (r.lang.isNotEmpty)
                                  VndbIcons.langRow(r.lang, size: 13),
                                Text(
                                  '${r.id} · ${r.formattedDate}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                if (r.platforms.isNotEmpty)
                                  VndbIcons.platRow(r.platforms, size: 12),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

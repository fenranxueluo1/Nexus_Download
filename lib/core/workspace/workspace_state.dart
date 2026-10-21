import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../api/service_exception.dart';
import '../api/bili_gateway.dart';
import '../transfer/transfer_coordinator.dart';
import '../postprocess/media_packager.dart';
import '../domain/output_profile.dart';
import '../domain/preferences.dart';
import '../domain/catalog.dart';
import '../pathing/path_template.dart';
import '../compose/job_composer.dart';
import '../intake/catalog_intake.dart';
import '../repository/job_repository.dart';
import '../repository/credential_vault.dart';
import '../repository/preferences_repository.dart';
import '../util/storage_paths.dart';
import '../util/privacy.dart';

class AccountCollections {
  const AccountCollections({
    required this.ownFolders,
    required this.collectedFolders,
    required this.collections,
  });

  final List<FavoriteFolder> ownFolders;
  final List<FavoriteFolder> collectedFolders;
  final List<SpaceCollection> collections;
}

class WorkspaceState extends ChangeNotifier {
  static const MethodChannel _androidPlatform = MethodChannel('nexus/platform');

  WorkspaceState._({
    required this.preferencesRepository,
    required this.jobRepository,
    required this.credentialVault,
    required this.client,
    required this.preferences,
    required this.coordinator,
  }) : intake = CatalogIntake(client),
       composer = JobComposer(client);

  final PreferencesRepository preferencesRepository;
  final JobRepository jobRepository;
  final CredentialVault credentialVault;
  final BiliGateway client;
  final CatalogIntake intake;
  final JobComposer composer;
  final TransferCoordinator coordinator;
  final ValueNotifier<int> tabIndex = ValueNotifier<int>(0);

  Preferences preferences;
  AccountSnapshot account = AccountSnapshot.empty;
  String? accountError;
  MediaCatalog? catalog;
  final Set<String> _pickedTrackIds = {};

  bool collecting = false;
  bool composing = false;
  String? collectError;
  int composeDone = 0;
  int composeTotal = 0;
  String? pageError;

  AccountCollections? accountCollections;
  bool collectionsLoading = false;
  String? collectionsError;

  String? notice;
  bool noticeIsError = false;
  int noticeSeq = 0;

  static Future<WorkspaceState> create() async {
    await StoragePaths.init();
    final preferencesRepository = PreferencesRepository();
    var preferences = await preferencesRepository.load();
    if (Platform.isAndroid &&
        !await PreferencesRepository.directoryIsWritable(
          preferences.destinationRoot,
        )) {
      preferences = preferences.copyWith(
        destinationRoot: StoragePaths.defaultDownloadDir,
      );
      await preferencesRepository.save(preferences);
    }
    final credentialVault = CredentialVault();
    await credentialVault.load();
    BiliGateway client;
    try {
      client = BiliGateway(
        cookie: credentialVault.cookie,
        proxy: preferences.proxy,
      );
    } on ApiException {
      client = BiliGateway(cookie: credentialVault.cookie);
    }
    final jobRepository = JobRepository();
    final coordinator = TransferCoordinator(
      client: client,
      preferencesRepository: preferencesRepository,
      jobRepository: jobRepository,
    );
    await coordinator.init(preferences);
    final state = WorkspaceState._(
      preferencesRepository: preferencesRepository,
      jobRepository: jobRepository,
      credentialVault: credentialVault,
      client: client,
      preferences: preferences,
      coordinator: coordinator,
    );
    unawaited(state.refreshAccount(silent: true));
    return state;
  }

  bool get isLoggedIn => account.isLogin;
  bool get isBusy => collecting || composing;
  double get composeProgress {
    if (composeTotal <= 0) {
      return 0;
    }
    return (composeDone / composeTotal).clamp(0.0, 1.0);
  }

  List<CatalogTrack> get allTracks => [
    for (final item in catalog?.items ?? const <CatalogEntry>[]) ...item.tracks,
  ];

  int get selectedCount => _pickedTrackIds.length;

  bool get allSelected {
    final tracks = allTracks;
    return tracks.isNotEmpty &&
        tracks.every((track) => _pickedTrackIds.contains(track.id));
  }

  bool isTrackSelected(String partId) => _pickedTrackIds.contains(partId);

  void toggleTrack(String partId) {
    if (_pickedTrackIds.contains(partId)) {
      _pickedTrackIds.remove(partId);
    } else {
      _pickedTrackIds.add(partId);
    }
    notifyListeners();
  }

  void setTracksSelected(Iterable<String> partIds, bool selected) {
    for (final id in partIds) {
      if (selected) {
        _pickedTrackIds.add(id);
      } else {
        _pickedTrackIds.remove(id);
      }
    }
    notifyListeners();
  }

  void selectAll() {
    _pickedTrackIds
      ..clear()
      ..addAll(allTracks.map((track) => track.id));
    notifyListeners();
  }

  void clearSelection() {
    _pickedTrackIds.clear();
    notifyListeners();
  }

  List<PickedTrack> get pickedTracks {
    final result = <PickedTrack>[];
    for (final item in catalog?.items ?? const <CatalogEntry>[]) {
      for (final track in item.tracks) {
        if (_pickedTrackIds.contains(track.id)) {
          result.add(PickedTrack(item: item, track: track));
        }
      }
    }
    return result;
  }

  Future<void> collectLink(String input) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty || collecting) {
      return;
    }
    collecting = true;
    collectError = null;
    pageError = null;
    catalog = null;
    _pickedTrackIds.clear();
    notifyListeners();
    try {
      catalog = await intake.ingest(trimmed);
      if (catalog != null &&
          catalog!.items.length == 1 &&
          catalog!.items.first.tracks.length == 1) {
        _pickedTrackIds.add(catalog!.items.first.tracks.first.id);
      }
    } on ApiException catch (error) {
      collectError = error.message;
    } on Object catch (error) {
      collectError = '解析失败：$error';
    } finally {
      collecting = false;
      notifyListeners();
    }
  }

  Future<void> fetchNextPage() async {
    final current = catalog;
    if (current == null || !current.hasMore || collecting) {
      return;
    }
    collecting = true;
    pageError = null;
    notifyListeners();
    try {
      catalog = await intake.fetchNextPage(current);
    } on ApiException catch (error) {
      pageError = error.message;
    } on Object catch (error) {
      pageError = '加载失败：$error';
    } finally {
      collecting = false;
      notifyListeners();
    }
  }

  Future<BuildReport?> enqueueJobs({
    required OutputProfile profile,
    String? quality,
    String? codec,
  }) async {
    final current = catalog;
    if (current == null || _pickedTrackIds.isEmpty || composing) {
      return null;
    }
    if (preferences.destinationRoot.trim().isEmpty) {
      showNotice('请先在设置中选择保存位置', isError: true);
      return null;
    }
    composing = true;
    composeDone = 0;
    composeTotal = _pickedTrackIds.length;
    notifyListeners();
    try {
      final options = BuildOptions(
        profile: profile,
        preferences: preferences,
        qualityOverride: quality,
        codecOverride: codec,
        existingDuplicateKeys: coordinator.jobs
            .map((job) => job.duplicateKey)
            .toSet(),
        reservedPaths: coordinator.jobs.map((job) => job.destination).toSet(),
      );
      final outcome = await composer.compose(
        catalogKind: current.kind,
        tracks: pickedTracks,
        options: options,
        onProgress: (done, total) {
          composeDone = done;
          composeTotal = total;
          notifyListeners();
        },
      );
      final added = coordinator.admitJobs(outcome.jobs);
      final summary = <String>['已创建 $added 个任务'];
      if (outcome.skipped.isNotEmpty) {
        summary.add('跳过 ${outcome.skipped.length} 个');
      }
      if (outcome.failures.isNotEmpty) {
        summary.add('失败 ${outcome.failures.length} 个');
      }
      showNotice(summary.join('，'), isError: outcome.failures.isNotEmpty);
      if (outcome.jobs.isNotEmpty) {
        tabIndex.value = 1;
      }
      return outcome;
    } on ApiException catch (error) {
      showNotice(error.message, isError: true);
      return null;
    } on Object catch (error) {
      showNotice('创建任务失败：$error', isError: true);
      return null;
    } finally {
      composing = false;
      notifyListeners();
    }
  }

  Future<void> refreshAccount({bool silent = false}) async {
    try {
      account = await client.fetchAccount(force: true);
      accountError = null;
    } on Object catch (error) {
      accountError = '$error';
      if (!silent) {
        showNotice('账号信息获取失败：$error', isError: true);
      }
    }
    notifyListeners();
  }

  Future<bool> loginWithCookie(String raw) async {
    final cookie = CredentialVault.sanitizeCookieInput(raw);
    if (!CredentialVault.looksLikeCookie(cookie)) {
      showNotice('Cookie 中需要包含 SESSDATA 或 bili_jct。', isError: true);
      return false;
    }
    client.cookie = cookie;
    try {
      final snapshot = await client.fetchAccount(force: true);
      if (!snapshot.isLogin) {
        client.cookie = '';
        showNotice('Cookie 无效或已过期，请重新获取。', isError: true);
        return false;
      }
      account = snapshot;
      accountError = null;
      await credentialVault.saveCookie(cookie);
      showNotice('已登录：${snapshot.name}');
      notifyListeners();
      return true;
    } on ApiException catch (error) {
      showNotice('登录失败：${error.message}', isError: true);
      return false;
    } on Object catch (error) {
      showNotice('登录失败：$error', isError: true);
      return false;
    }
  }

  Future<QrLoginTicket> startQrLogin() => client.qrGenerate();

  Future<QrPollResult> pollQrLogin(String key) async {
    final result = await client.qrPoll(key);
    if (result.isSuccess && result.cookie != null) {
      client.cookie = result.cookie!;
      await credentialVault.saveCookie(result.cookie!);
      try {
        account = await client.fetchAccount(force: true);
      } on Object {
        // The cookie is still valid even if the profile refresh fails.
      }
      showNotice('扫码登录成功');
      notifyListeners();
    }
    return result;
  }

  Future<void> logout() async {
    client.cookie = '';
    account = AccountSnapshot.empty;
    accountCollections = null;
    await credentialVault.clear();
    showNotice('已退出登录');
    notifyListeners();
  }

  Future<void> loadCollections() async {
    if (!isLoggedIn || collectionsLoading) {
      return;
    }
    collectionsLoading = true;
    collectionsError = null;
    notifyListeners();
    final own = <FavoriteFolder>[];
    final collected = <FavoriteFolder>[];
    final collections = <SpaceCollection>[];
    try {
      try {
        own.addAll(await client.ownFavoriteFolders(account.mid));
      } on Object catch (error) {
        collectionsError = '收藏夹加载失败：$error';
      }
      try {
        collected.addAll((await client.collectedFolders(account.mid)).items);
      } on Object catch (error) {
        collectionsError ??= '订阅合集加载失败：$error';
      }
      try {
        collections.addAll(await client.spaceCollections(account.mid));
      } on Object catch (error) {
        collectionsError ??= '合集列表加载失败：$error';
      }
      accountCollections = AccountCollections(
        ownFolders: own,
        collectedFolders: collected,
        collections: collections,
      );
    } finally {
      collectionsLoading = false;
      notifyListeners();
    }
  }

  Future<void> openFolder(FavoriteFolder folder) async {
    tabIndex.value = 0;
    await collectLink('https://www.bilibili.com/medialist/play/ml${folder.id}');
  }

  Future<void> openCollection(SpaceCollection collection) async {
    final mid = account.mid;
    final path = collection.kind == 'season'
        ? 'collectiondetail'
        : 'seriesdetail';
    tabIndex.value = 0;
    await collectLink(
      'https://space.bilibili.com/$mid/channel/$path?sid=${collection.id}',
    );
  }

  Future<void> savePreferences(Preferences next) async {
    final directory = next.destinationRoot.trim();
    if (directory.isEmpty) {
      throw const ApiException('保存位置不能为空。');
    }
    if (!await PreferencesRepository.directoryIsWritable(directory)) {
      throw ApiException(
        Platform.isAndroid
            ? 'Android 暂不支持写入该系统目录，请使用默认的应用专属目录。'
            : '保存位置不可写，请选择其他目录。',
      );
    }
    if (next.proxy.trim().isNotEmpty) {
      client.proxy = next.proxy;
    } else {
      client.proxy = '';
    }
    await preferencesRepository.save(next);
    preferences = next;
    coordinator.updateSettings(next);
    notifyListeners();
  }

  Future<void> exportReport(String path) async {
    final settingsJson = preferences.toJson();
    if ((preferences.proxy).trim().isNotEmpty) {
      settingsJson['proxy'] = '<configured>';
    }
    final tasksJson = <Map<String, dynamic>>[];
    final journalBuffer = StringBuffer();
    for (final job in coordinator.jobs) {
      final json = job.toJson(includeLogs: false);
      final assets =
          (json['assets'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
      for (final asset in assets) {
        final urls = (asset['urls'] as List?) ?? const [];
        asset['urls'] = urls.map((url) => scrubSecrets('$url')).toList();
        asset['headers'] = {'redacted': true};
      }
      tasksJson.add(json);
      journalBuffer.writeln('## ${job.id} ${job.title} (${job.state.wire})');
      for (final log in job.journal) {
        journalBuffer.writeln(
          '[${log.at.toIso8601String()}] [${log.level.wire}] ${scrubSecrets(log.message)}',
        );
      }
      journalBuffer.writeln();
    }
    final payload = const JsonEncoder.withIndent('  ').convert({
      'app': 'Nexus',
      'version': '1.0.0',
      'platform': Platform.operatingSystem,
      'generatedAt': DateTime.now().toIso8601String(),
      'preferences': settingsJson,
      'jobs': tasksJson,
      'journal': journalBuffer.toString(),
    });
    final bytes = utf8.encode(payload);
    final archive = Archive()
      ..addFile(ArchiveFile('nexus-diagnostics.json', bytes.length, bytes));
    final encoded = ZipEncoder().encode(archive)!;
    await File(path).writeAsBytes(encoded, flush: true);
    showNotice('诊断包已导出：$path');
  }

  Future<PackagerProbe> probePackager(String path) async {
    final packager = MediaPackager(packagerPath: path);
    return packager.probe();
  }

  void showNotice(String message, {bool isError = false}) {
    notice = message;
    noticeIsError = isError;
    noticeSeq += 1;
    notifyListeners();
  }

  Future<void> openPath(String path) async {
    if (path.trim().isEmpty) {
      return;
    }
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', [path], runInShell: false);
      } else if (Platform.isMacOS) {
        await Process.run('open', [path], runInShell: false);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [path], runInShell: false);
      } else if (Platform.isIOS) {
        final uri = Uri.tryParse(path);
        if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
          await _openAndroidUrl(path);
        } else {
          final isDirectory = await Directory(path).exists();
          await _openAndroidPath(path, folder: isDirectory);
        }
      } else if (Platform.isAndroid) {
        final uri = Uri.tryParse(path);
        if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
          await _openAndroidUrl(path);
        } else {
          final isDirectory = await Directory(path).exists();
          await _openAndroidPath(path, folder: isDirectory);
        }
      } else {
        showNotice('当前平台暂不支持打开文件', isError: true);
      }
    } on ProcessException catch (error) {
      showNotice('无法打开：${error.message}', isError: true);
    }
  }

  Future<void> revealInFolder(String path) async {
    final value = path.trim();
    if (value.isEmpty) {
      showNotice('没有可定位的路径', isError: true);
      return;
    }
    final normalized = p.normalize(p.absolute(value));
    final fileExists = await File(normalized).exists();
    final directoryExists = await Directory(normalized).exists();
    final directory = fileExists || !directoryExists
        ? p.dirname(normalized)
        : normalized;
    try {
      if (Platform.isWindows) {
        if (fileExists) {
          await Process.run('explorer.exe', [
            '/select,',
            normalized,
          ], runInShell: false);
        } else if (await Directory(directory).exists()) {
          await Process.run('explorer.exe', [directory], runInShell: false);
        } else {
          showNotice('目标文件或文件夹不存在：$normalized', isError: true);
        }
      } else if (Platform.isMacOS) {
        if (fileExists) {
          await Process.run('open', ['-R', normalized], runInShell: false);
        } else if (await Directory(directory).exists()) {
          await Process.run('open', [directory], runInShell: false);
        } else {
          showNotice('目标文件或文件夹不存在：$normalized', isError: true);
        }
      } else if (Platform.isLinux) {
        await openPath(directory);
      } else if (Platform.isIOS) {
        showNotice('iOS 请在“文件”App 的 Nexus 文件夹中查看下载内容');
      } else if (Platform.isAndroid) {
        if (await Directory(directory).exists()) {
          await _openAndroidPath(directory, folder: true);
        } else {
          showNotice('目标文件或文件夹不存在：$normalized', isError: true);
        }
      } else {
        showNotice('当前平台暂不支持定位文件', isError: true);
      }
    } on ProcessException catch (error) {
      showNotice('无法打开所在文件夹：${error.message}', isError: true);
    }
  }

  Future<void> _openAndroidPath(String path, {required bool folder}) async {
    try {
      final opened = await _androidPlatform.invokeMethod<bool>(
        folder ? 'openFolder' : 'openFile',
        {'path': path},
      );
      if (opened != true) {
        showNotice(folder ? '没有可打开该文件夹的应用' : '没有可打开该文件的应用', isError: true);
      }
    } on MissingPluginException {
      showNotice('当前移动端构建未注册文件打开通道，请重新构建应用。', isError: true);
    } on PlatformException catch (error) {
      showNotice('无法打开：${error.message ?? error.code}', isError: true);
    }
  }

  Future<void> _openAndroidUrl(String url) async {
    try {
      final opened = await _androidPlatform.invokeMethod<bool>('openUrl', {
        'url': url,
      });
      if (opened != true) {
        showNotice('没有可打开该链接的应用', isError: true);
      }
    } on MissingPluginException {
      showNotice('当前移动端构建未注册文件打开通道，请重新构建应用。', isError: true);
    } on PlatformException catch (error) {
      showNotice('无法打开：${error.message ?? error.code}', isError: true);
    }
  }

  Future<void> copyFolderToDownloads(String path) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return;
    }
    try {
      final count = await _androidPlatform.invokeMethod<int>(
        'copyFolderToDownloads',
        {'path': path},
      );
      if (Platform.isIOS) {
        showNotice(
          count == null || count == 0
              ? '没有可导出的文件'
              : '已打开“存储到文件”面板，共 $count 个文件',
        );
      } else {
        showNotice(
          count == null
              ? '已复制到 Download/Nexus'
              : '已复制 $count 个文件到 Download/Nexus',
        );
      }
    } on MissingPluginException {
      showNotice('当前移动端构建未注册目录复制通道，请重新构建应用。', isError: true);
    } on PlatformException catch (error) {
      showNotice('复制目录失败：${error.message ?? error.code}', isError: true);
    }
  }

  String previewPathTemplate(String template) {
    try {
      validatePathTemplate(template);
      final sample = PathFields(
        title: '作品标题',
        trackTitle: '示例分段',
        trackNo: 1,
        ext: 'mp4',
        bvid: 'BV1xx411c7mD',
        aid: 170001,
        cid: 123456,
        creator: '创作者',
        creatorId: 1000,
        series: '示例剧集',
        episodeNo: 1,
        collection: '示例收藏夹',
        index: 1,
        quality: '80',
        codec: 'AVC',
        date: DateTime.now(),
        publishDate: DateTime.now().toIso8601String(),
      );
      return composeRelativePath(template, sample);
    } on FormatException catch (error) {
      return '路径规则错误：${error.message}';
    }
  }

  @override
  void dispose() {
    coordinator.dispose();
    client.close();
    tabIndex.dispose();
    super.dispose();
  }
}

WorkspaceState workspaceOf(BuildContext context) {
  final scope = context.dependOnInheritedWidgetOfExactType<WorkspaceScope>();
  assert(scope != null, 'WorkspaceScope not found in the widget tree');
  return scope!.notifier;
}

class WorkspaceScope extends InheritedNotifier<WorkspaceState> {
  const WorkspaceScope({
    super.key,
    required WorkspaceState state,
    required super.child,
  }) : super(notifier: state);

  @override
  WorkspaceState get notifier => super.notifier!;
}

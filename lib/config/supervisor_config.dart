import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class SupervisorConfig {
  static const jsonSchemaVersion = 1;
  static const defaultCharacterName = 'monitor';

  const SupervisorConfig({
    required this.siyuanBaseUrl,
    required this.siyuanToken,
    required this.notebookId,
    required this.targetDocumentId,
    required this.characterName,
    required this.screenshotIntervalSeconds,
    required this.mimoBaseUrl,
    required this.mimoApiKey,
    required this.mimoModel,
    required this.uploadScreenshotToSiyuan,
  });

  final String siyuanBaseUrl;
  final String siyuanToken;
  final String notebookId;
  final String targetDocumentId;
  final String characterName;
  final int screenshotIntervalSeconds;
  final String mimoBaseUrl;
  final String mimoApiKey;
  final String mimoModel;
  final bool uploadScreenshotToSiyuan;

  static const defaults = SupervisorConfig(
    siyuanBaseUrl: '',
    siyuanToken: '',
    notebookId: '',
    targetDocumentId: '',
    characterName: defaultCharacterName,
    screenshotIntervalSeconds: 25 * 60,
    mimoBaseUrl: 'https://token-plan-cn.xiaomimimo.com/v1',
    mimoApiKey: '',
    mimoModel: 'mimo-v2.5',
    uploadScreenshotToSiyuan: false,
  );

  SupervisorConfig copyWith({
    String? siyuanBaseUrl,
    String? siyuanToken,
    String? notebookId,
    String? targetDocumentId,
    String? characterName,
    int? screenshotIntervalSeconds,
    String? mimoBaseUrl,
    String? mimoApiKey,
    String? mimoModel,
    bool? uploadScreenshotToSiyuan,
  }) => SupervisorConfig(
    siyuanBaseUrl: siyuanBaseUrl ?? this.siyuanBaseUrl,
    siyuanToken: siyuanToken ?? this.siyuanToken,
    notebookId: notebookId ?? this.notebookId,
    targetDocumentId: targetDocumentId ?? this.targetDocumentId,
    characterName: characterName ?? this.characterName,
    screenshotIntervalSeconds:
        screenshotIntervalSeconds ?? this.screenshotIntervalSeconds,
    mimoBaseUrl: mimoBaseUrl ?? this.mimoBaseUrl,
    mimoApiKey: mimoApiKey ?? this.mimoApiKey,
    mimoModel: mimoModel ?? this.mimoModel,
    uploadScreenshotToSiyuan:
        uploadScreenshotToSiyuan ?? this.uploadScreenshotToSiyuan,
  );

  static Future<SupervisorConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final configVersion = prefs.getInt('configVersion') ?? 1;
    final storedInterval = prefs.getInt('screenshotIntervalSeconds');
    final interval =
        storedInterval == null || (configVersion < 2 && storedInterval == 60)
        ? 25 * 60
        : storedInterval;
    if (configVersion < 2) await prefs.setInt('configVersion', 2);
    return SupervisorConfig(
      siyuanBaseUrl: prefs.getString('siyuanBaseUrl') ?? '',
      siyuanToken: prefs.getString('siyuanToken') ?? '',
      notebookId: prefs.getString('siyuanNotebookId') ?? '',
      targetDocumentId:
          prefs.getString('targetDocumentId') ??
          prefs.getString('notebookId') ??
          '',
      // Kept internally for backward-compatible records; it is no longer a
      // user setting.
      characterName: defaultCharacterName,
      screenshotIntervalSeconds: interval,
      mimoBaseUrl: prefs.getString('mimoBaseUrl') ?? defaults.mimoBaseUrl,
      mimoApiKey: prefs.getString('mimoApiKey') ?? '',
      mimoModel: prefs.getString('mimoModel') ?? defaults.mimoModel,
      uploadScreenshotToSiyuan:
          prefs.getBool('uploadScreenshotToSiyuan') ?? false,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setString('siyuanBaseUrl', siyuanBaseUrl.trim()),
      prefs.setString('siyuanToken', siyuanToken.trim()),
      prefs.setString('siyuanNotebookId', notebookId.trim()),
      prefs.setString('targetDocumentId', targetDocumentId.trim()),
      prefs.remove('notebookId'),
      prefs.remove('characterName'),
      prefs.setInt('screenshotIntervalSeconds', screenshotIntervalSeconds),
      prefs.setString('mimoBaseUrl', mimoBaseUrl.trim()),
      prefs.setString('mimoApiKey', mimoApiKey.trim()),
      prefs.setString('mimoModel', mimoModel.trim()),
      prefs.setBool('uploadScreenshotToSiyuan', uploadScreenshotToSiyuan),
      prefs.setInt('configVersion', 3),
    ]);
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': jsonSchemaVersion,
    'siyuan': {
      'server': siyuanBaseUrl.trim(),
      'token': siyuanToken.trim(),
      'notebookId': notebookId.trim(),
      'targetDocumentId': targetDocumentId.trim(),
    },
    'mimo': {
      'baseUrl': mimoBaseUrl.trim(),
      'apiKey': mimoApiKey.trim(),
      'model': mimoModel.trim(),
    },
    'monitoring': {
      'intervalMinutes': screenshotIntervalSeconds ~/ 60,
      'uploadScreenshotToSiyuan': uploadScreenshotToSiyuan,
    },
  };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory SupervisorConfig.fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'];
    if (version != jsonSchemaVersion) {
      throw const FormatException('不支持的配置文件版本');
    }
    final siyuan = _jsonSection(json, 'siyuan');
    final mimo = _jsonSection(json, 'mimo');
    final monitoring = _jsonSection(json, 'monitoring');
    final intervalMinutes = monitoring['intervalMinutes'];
    if (intervalMinutes is! num || intervalMinutes.toInt() < 1) {
      throw const FormatException('monitoring.intervalMinutes 必须是不小于 1 的数字');
    }
    final uploadScreenshot = monitoring['uploadScreenshotToSiyuan'];
    if (uploadScreenshot is! bool) {
      throw const FormatException(
        'monitoring.uploadScreenshotToSiyuan 必须是 true 或 false',
      );
    }
    return SupervisorConfig(
      siyuanBaseUrl: _jsonString(siyuan, 'server'),
      siyuanToken: _jsonString(siyuan, 'token'),
      notebookId: _jsonString(siyuan, 'notebookId'),
      targetDocumentId: _jsonString(siyuan, 'targetDocumentId'),
      characterName: defaultCharacterName,
      screenshotIntervalSeconds: intervalMinutes.toInt() * 60,
      mimoBaseUrl: _jsonString(mimo, 'baseUrl'),
      mimoApiKey: _jsonString(mimo, 'apiKey'),
      mimoModel: _jsonString(mimo, 'model'),
      uploadScreenshotToSiyuan: uploadScreenshot,
    );
  }

  factory SupervisorConfig.fromJsonString(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('配置文件根节点必须是 JSON 对象');
      }
      return SupervisorConfig.fromJson(decoded);
    } on FormatException {
      rethrow;
    } catch (error) {
      throw FormatException('无法解析配置文件：$error');
    }
  }

  String? validate() {
    final captureError = validateCapture();
    if (captureError != null) return captureError;
    final uri = Uri.tryParse(siyuanBaseUrl.trim());
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      return '请输入有效的 SiYuan Server URL';
    }
    if (siyuanToken.trim().isEmpty) return '请输入 SiYuan Token';
    if (notebookId.trim().isEmpty) return '请输入思源笔记本 ID';
    if (!RegExp(r'^\d{14}-[a-z0-9]{7}$').hasMatch(notebookId.trim())) {
      return '思源笔记本 ID 格式无效';
    }
    if (targetDocumentId.trim().isEmpty) return '请输入思源目标子文档 ID';
    if (!RegExp(r'^\d{14}-[a-z0-9]{7}$').hasMatch(targetDocumentId.trim())) {
      return '思源目标子文档 ID 格式无效';
    }
    final mimoUri = Uri.tryParse(mimoBaseUrl.trim());
    if (mimoUri == null || !mimoUri.hasScheme || !mimoUri.hasAuthority) {
      return '请输入有效的 MiMo API 地址';
    }
    if (mimoApiKey.trim().isEmpty) return '请输入 MiMo API Key';
    if (mimoModel.trim().isEmpty) return '请输入 MiMo 模型名';
    return null;
  }

  String? validateCapture() {
    if (screenshotIntervalSeconds < 60) return '监控间隔不能少于 1 分钟';
    return null;
  }
}

Map<String, dynamic> _jsonSection(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! Map) throw FormatException('缺少配置项：$key');
  return value.map((key, value) => MapEntry(key.toString(), value));
}

String _jsonString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('缺少配置项：$key');
  return value;
}

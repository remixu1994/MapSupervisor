import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../config/supervisor_config.dart';
import '../models/monitor_status.dart';
import '../repositories/monitor_repository.dart';
import '../services/monitoring_service.dart';
import '../services/siyuan_service.dart';
import '../services/config_file_service.dart';
import 'history_screen.dart';
import 'diagnostics_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    required this.repository,
    required this.monitoringService,
    super.key,
  });
  final MonitorRepository repository;
  final MonitoringService monitoringService;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _configFiles = ConfigFileService();
  final _url = TextEditingController();
  final _token = TextEditingController();
  final _notebook = TextEditingController();
  final _targetDocument = TextEditingController();
  final _mimoUrl = TextEditingController();
  final _mimoKey = TextEditingController();
  final _mimoModel = TextEditingController();
  final _interval = TextEditingController(text: '25');
  StreamSubscription<MonitorStatus>? _statusSubscription;
  MonitorStatus _status = const MonitorStatus();
  bool _loading = true;
  bool _busy = false;
  bool _uploadScreenshot = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final config = await SupervisorConfig.load();
    _url.text = config.siyuanBaseUrl;
    _token.text = config.siyuanToken;
    _notebook.text = config.notebookId;
    _targetDocument.text = config.targetDocumentId;
    _mimoUrl.text = config.mimoBaseUrl;
    _mimoKey.text = config.mimoApiKey;
    _mimoModel.text = config.mimoModel;
    _uploadScreenshot = config.uploadScreenshotToSiyuan;
    _interval.text = (config.screenshotIntervalSeconds ~/ 60).toString();
    _statusSubscription = widget.monitoringService.statuses.listen((status) {
      if (mounted) setState(() => _status = status);
    });
    await widget.monitoringService.initialize(config);
    if (mounted) {
      setState(() {
        _status = widget.monitoringService.status;
        _loading = false;
      });
    }
  }

  SupervisorConfig get _config => SupervisorConfig(
    siyuanBaseUrl: _url.text,
    siyuanToken: _token.text,
    notebookId: _notebook.text,
    targetDocumentId: _targetDocument.text,
    characterName: SupervisorConfig.defaultCharacterName,
    screenshotIntervalSeconds: (int.tryParse(_interval.text) ?? 25) * 60,
    mimoBaseUrl: _mimoUrl.text,
    mimoApiKey: _mimoKey.text,
    mimoModel: _mimoModel.text,
    uploadScreenshotToSiyuan: _uploadScreenshot,
  );

  void _applyConfig(SupervisorConfig config) {
    _url.text = config.siyuanBaseUrl;
    _token.text = config.siyuanToken;
    _notebook.text = config.notebookId;
    _targetDocument.text = config.targetDocumentId;
    _mimoUrl.text = config.mimoBaseUrl;
    _mimoKey.text = config.mimoApiKey;
    _mimoModel.text = config.mimoModel;
    _interval.text = (config.screenshotIntervalSeconds ~/ 60).toString();
    _uploadScreenshot = config.uploadScreenshotToSiyuan;
  }

  Future<void> _importConfig() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final source = await _configFiles.importJson();
      if (source == null) return;
      final config = SupervisorConfig.fromJsonString(source);
      final error = config.validate();
      if (error != null) throw FormatException(error);
      await config.save();
      await widget.monitoringService.initialize(config);
      if (!mounted) return;
      setState(() => _applyConfig(config));
      _show('配置已导入并保存');
    } catch (error) {
      _show('配置导入失败：$error', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportConfig() async {
    if (_busy) return;
    final error = _config.validate();
    if (error != null) {
      _show(error, isError: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await _config.save();
      final saved = await _configFiles.exportJson(_config.toJsonString());
      if (saved) _show('配置文件已导出');
    } catch (error) {
      _show('配置导出失败：$error', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool requireSiyuan = true,
  }) async {
    if (_busy) return;
    final error = requireSiyuan
        ? _config.validate()
        : _config.validateCapture();
    if (error != null) {
      _show(error, isError: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await _config.save();
      await action();
    } catch (error) {
      _show('$error', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _show(String message, {bool isError = false}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 2),
          backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
        ),
      );
  }

  String _time(DateTime? value) =>
      value == null ? '—' : DateFormat('HH:mm:ss').format(value);

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final screenshot = _status.lastScreenshotPath == null
        ? null
        : File(_status.lastScreenshotPath!);
    return Scaffold(
      appBar: AppBar(
        title: const Text('MapSupervisor'),
        actions: [
          IconButton(
            tooltip: '进程诊断日志',
            icon: const Icon(Icons.receipt_long_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const DiagnosticsScreen(),
              ),
            ),
          ),
          IconButton(
            tooltip: '监控历史',
            icon: const Icon(Icons.history),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => HistoryScreen(repository: widget.repository),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _StatusCard(status: _status, time: _time),
            const SizedBox(height: 16),
            if (_status.permissionRequired)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('监控已中断：需要重新授予屏幕捕获权限。'),
                ),
              ),
            if (screenshot != null && screenshot.existsSync()) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(screenshot, height: 180, fit: BoxFit.cover),
              ),
              const SizedBox(height: 16),
            ],
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'JSON 配置文件',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    const Text('配置文件包含 Token 和 API Key，请妥善保管。'),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _busy || _status.isRunning
                                ? null
                                : _importConfig,
                            icon: const Icon(Icons.file_open_outlined),
                            label: const Text('导入配置'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _busy ? null : _exportConfig,
                            icon: const Icon(Icons.save_alt),
                            label: const Text('导出配置'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            _field(_interval, '监控间隔（分钟，默认 25）', number: true),
            _field(_url, 'SiYuan Server', hint: 'http://192.168.1.2:6806'),
            _field(_token, 'SiYuan Token', secret: true),
            _field(_notebook, '思源笔记本 ID', hint: '20250305001716-bvpgdom'),
            _field(
              _targetDocument,
              '思源目标子文档 ID',
              hint: '例如 20261006220439-6oea414',
            ),
            const Divider(height: 28),
            _field(
              _mimoUrl,
              'MiMo Token Plan API',
              hint: 'https://token-plan-cn.xiaomimimo.com/v1',
            ),
            _field(_mimoKey, 'MiMo Plan API Key（tp-...）', secret: true),
            _field(_mimoModel, 'MiMo 视觉模型', hint: 'mimo-v2.5'),
            CheckboxListTile(
              value: _uploadScreenshot,
              contentPadding: EdgeInsets.zero,
              title: const Text('上传截图到 SiYuan'),
              subtitle: const Text('不勾选时只写入识别后的文字日志'),
              onChanged: _busy
                  ? null
                  : (value) =>
                        setState(() => _uploadScreenshot = value ?? false),
            ),
            const SizedBox(height: 4),
            FilledButton.icon(
              onPressed: _busy || _status.isRunning
                  ? null
                  : () => _run(() => widget.monitoringService.start(_config)),
              icon: const Icon(Icons.play_arrow),
              label: Text(_status.isRunning ? '监控已启动' : '开始监控'),
            ),
            OutlinedButton.icon(
              onPressed: _busy || !_status.isRunning
                  ? null
                  : widget.monitoringService.stop,
              icon: const Icon(Icons.stop),
              label: const Text('停止监控'),
            ),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run(
                      () => widget.monitoringService.captureNow(_config),
                    ),
              icon: const Icon(Icons.bug_report),
              label: const Text('手动调试（8 秒后截图并识别）'),
            ),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      await SiyuanService(_config).testConnection();
                      _show('SiYuan 连接及目标子文档验证成功');
                    }),
              icon: const Icon(Icons.cloud_done),
              label: const Text('测试 SiYuan 连接'),
            ),
            if (_busy) const LinearProgressIndicator(),
          ],
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
    bool secret = false,
    bool number = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: controller,
      obscureText: secret,
      keyboardType: number ? TextInputType.number : null,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _url.dispose();
    _token.dispose();
    _notebook.dispose();
    _targetDocument.dispose();
    _mimoUrl.dispose();
    _mimoKey.dispose();
    _mimoModel.dispose();
    _interval.dispose();
    super.dispose();
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status, required this.time});
  final MonitorStatus status;
  final String Function(DateTime?) time;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                status.isRunning ? Icons.visibility : Icons.visibility_off,
                color: status.isRunning ? Colors.green : Colors.grey,
              ),
              const SizedBox(width: 8),
              Text(
                status.isRunning ? '监控运行中' : '监控已停止',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ],
          ),
          const Divider(),
          Text('上次截图：${time(status.lastCapture)}'),
          Text('上次同步：${time(status.lastSync)}'),
          Text('下次截图：${time(status.nextCapture)}'),
          Text('待同步：${status.pending}    失败：${status.failed}'),
          if (status.message != null) ...[
            const SizedBox(height: 8),
            Text(status.message!),
          ],
        ],
      ),
    ),
  );
}

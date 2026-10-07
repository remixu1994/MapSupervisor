import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  static const _channel = MethodChannel('com.mapsupervisor/capture');
  late Future<String> _diagnostics;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _diagnostics = _channel
        .invokeMethod<String>('getDiagnostics')
        .then((value) => value ?? '暂无进程诊断日志');
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('诊断日志已复制')));
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空诊断日志？'),
        content: const Text('清空后无法恢复，建议先复制日志。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _channel.invokeMethod<void>('clearDiagnostics');
    if (mounted) setState(_reload);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('进程诊断日志'),
      actions: [
        IconButton(
          tooltip: '刷新',
          onPressed: () => setState(_reload),
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: '清空',
          onPressed: _clear,
          icon: const Icon(Icons.delete_outline),
        ),
      ],
    ),
    body: FutureBuilder<String>(
      future: _diagnostics,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final text = snapshot.data!;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  const Expanded(child: Text('复现退出后重新打开应用，再刷新并复制日志。')),
                  FilledButton.icon(
                    onPressed: () => _copy(text),
                    icon: const Icon(Icons.copy),
                    label: const Text('复制'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: SelectableText(
                  text,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

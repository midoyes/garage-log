import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/backup_service.dart';
import '../providers.dart';
import 'common.dart';

/// 自動備份存放的資料夾（App 私有目錄，一般檔案管理器看不到，
/// 所以下面的畫面提供「另存一份」把備份複製到使用者看得到的位置）。
Future<Directory> autoBackupDirectory() async {
  final base = await getApplicationSupportDirectory();
  return Directory(p.join(base.path, 'garage_log', 'backups'));
}

/// 自動備份與完整復原。
///
/// 與「匯入並合併」不同：完整復原會讓資料回到備份當時的狀態，
/// 備份之後新增的紀錄會被移除（以刪除處理，可再用復原前的自動備份救回）。
class RestorePage extends ConsumerStatefulWidget {
  const RestorePage({super.key});

  @override
  ConsumerState<RestorePage> createState() => _RestorePageState();
}

class _RestorePageState extends ConsumerState<RestorePage> {
  late Future<List<AutoBackupInfo>> _future = _load();
  bool _busy = false;

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  Future<List<AutoBackupInfo>> _load() async =>
      BackupService.listAutoBackups(await autoBackupDirectory());

  void _reload() => setState(() => _future = _load());

  /// 預覽 → 確認 → 先備份目前資料 → 完整復原。
  Future<void> _restoreText(String text, String label) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final svc = ref.read(backupProvider);
      final preview = await svc.preview(text); // 同時驗證格式與欄位
      final impact = await svc.restoreImpact(text);
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => _RestoreConfirmDialog(
          preview: preview,
          impact: impact,
          label: label,
        ),
      );
      if (ok != true) return;

      await svc.writeAutoBackup(
        await autoBackupDirectory(),
        prefix: BackupService.autoRestorePrefix,
      );
      await svc.restoreSnapshot(text);
      if (mounted) showSnack(context, '已完整復原到「$label」。復原前的資料已另存一份自動備份。');
    } on FormatException catch (e) {
      if (mounted) showSnack(context, e.message);
    } catch (e) {
      if (mounted) showSnack(context, '復原失敗：$e');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _reload();
      }
    }
  }

  Future<void> _restoreFromAuto(AutoBackupInfo b) async {
    try {
      final text = await b.file.readAsString();
      await _restoreText(text, _fmt(b.modified));
    } catch (e) {
      if (mounted) showSnack(context, '讀取備份失敗：$e');
    }
  }

  Future<void> _restoreFromFile() async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        dialogTitle: '選擇要完整復原的備份檔',
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      final path = picked?.files.single.path;
      if (path == null) return;
      await _restoreText(await File(path).readAsString(), p.basename(path));
    } catch (e) {
      if (mounted) showSnack(context, '讀取備份失敗：$e');
    }
  }

  /// 把自動備份複製到使用者選的位置（App 私有目錄不好直接找）。
  Future<void> _saveCopy(AutoBackupInfo b) async {
    try {
      final bytes = await b.file.readAsBytes();
      final path = await FilePicker.platform.saveFile(
        dialogTitle: '另存備份',
        fileName: b.name,
        type: FileType.custom,
        allowedExtensions: const ['json'],
        bytes: bytes,
      );
      if (path == null) return;
      if (!_isMobile) {
        final target = path.toLowerCase().endsWith('.json') ? path : '$path.json';
        await File(target).writeAsBytes(bytes);
      }
      if (mounted) showSnack(context, '已另存備份');
    } catch (e) {
      if (mounted) showSnack(context, '另存失敗：$e');
    }
  }

  static String _fmt(DateTime d) => DateFormat('yyyy/MM/dd HH:mm:ss').format(d);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('自動備份與復原')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('合併匯入 vs. 完整復原', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text(
                        '「匯入並合併」會保留兩邊較新的修改，不會讓資料回到過去。\n'
                        '「完整復原」則讓資料回到備份當時的樣子：備份之後新增或修改的紀錄都會被取代'
                        '（新增的會以刪除處理）。復原前會先自動備份目前資料，可以再復原回來。',
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _restoreFromFile,
                        icon: const Icon(Icons.restore_page_outlined),
                        label: const Text('從備份檔案完整復原…'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
                child: Text('自動備份（匯入前、復原前各自保留最近 5 份）',
                    style: theme.textTheme.titleSmall),
              ),
              FutureBuilder<List<AutoBackupInfo>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (snap.hasError) {
                    return Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('讀取自動備份失敗：${snap.error}'),
                    );
                  }
                  final list = snap.data ?? const <AutoBackupInfo>[];
                  if (list.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 32),
                      child: EmptyHint(
                        icon: Icons.history,
                        text: '還沒有自動備份\n第一次匯入備份檔時，會先自動備份目前資料',
                      ),
                    );
                  }
                  return Column(
                    children: [
                      for (var i = 0; i < list.length; i++)
                        Card(
                          child: ListTile(
                            leading: Icon(
                              list[i].kind == 'restore'
                                  ? Icons.settings_backup_restore
                                  : Icons.file_download_outlined,
                            ),
                            title: Text(_fmt(list[i].modified)),
                            subtitle: Text(
                              '${list[i].kind == 'restore' ? '復原前自動備份' : '匯入前自動備份'}'
                              '${i == 0 ? ' · 最新' : ''}'
                              ' · ${(list[i].file.lengthSync() / 1024).toStringAsFixed(1)} KB',
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: '另存一份',
                                  icon: const Icon(Icons.save_alt),
                                  onPressed: _busy ? null : () => _saveCopy(list[i]),
                                ),
                                FilledButton.tonal(
                                  onPressed: _busy ? null : () => _restoreFromAuto(list[i]),
                                  child: const Text('復原'),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RestoreConfirmDialog extends StatelessWidget {
  const _RestoreConfirmDialog({
    required this.preview,
    required this.impact,
    required this.label,
  });

  final BackupPreview preview;
  final RestoreImpact impact;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, color: theme.colorScheme.error),
      title: const Text('確定要完整復原嗎？'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('備份：$label'),
          const SizedBox(height: 8),
          const SizedBox(height: 12),
          SizedBox(
            width: 320,
            child: Table(
            columnWidths: const {
              0: FlexColumnWidth(2),
              1: FlexColumnWidth(),
              2: FlexColumnWidth(),
              3: FlexColumnWidth(),
            },
            children: [
              TableRow(
                children: [
                  for (final h in const ['', '目前', '備份', '將移除'])
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(h,
                          textAlign: h.isEmpty ? TextAlign.start : TextAlign.end,
                          style: theme.textTheme.labelMedium),
                    ),
                ],
              ),
              for (final t in impact.tables)
                TableRow(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(t.label),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text('${t.local}', textAlign: TextAlign.end),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text('${t.backup}', textAlign: TextAlign.end),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        '${t.removed}',
                        textAlign: TextAlign.end,
                        style: t.removed > 0
                            ? TextStyle(
                                color: theme.colorScheme.error,
                                fontWeight: FontWeight.w700,
                              )
                            : null,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          ),
          const SizedBox(height: 12),
          Text(
            impact.totalRemoved > 0
                ? '共有 ${impact.totalRemoved} 筆目前的紀錄會被移除（備份裡沒有）。'
                    '備份裡有、但目前的內容不同的紀錄會被改回備份的樣子。'
                : '沒有紀錄會被移除；內容不同的紀錄會被改回備份的樣子。',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          Text(
            '復原前會先自動備份目前資料，之後仍可再復原回來。',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('完整復原'),
        ),
      ],
    );
  }
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../data/backup_service.dart';
import '../providers.dart';
import 'common.dart';
import 'restore_page.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  String _stamp() => DateFormat('yyyyMMdd_HHmm').format(DateTime.now());

  /// 讓使用者選擇存檔位置。Android / iOS 需把 bytes 交給 file_picker 寫入；
  /// 桌面端 file_picker 只回傳路徑，要自行寫檔。
  Future<bool> _saveBytes(
    String fileName,
    String ext,
    Uint8List bytes,
    String dialogTitle,
  ) async {
    final path = await FilePicker.platform.saveFile(
      dialogTitle: dialogTitle,
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: [ext],
      bytes: bytes,
    );
    if (path == null) return false;
    if (!_isMobile) {
      final target = path.toLowerCase().endsWith('.$ext') ? path : '$path.$ext';
      await File(target).writeAsBytes(bytes);
    }
    return true;
  }

  Future<void> _exportJson(BuildContext context, WidgetRef ref) async {
    try {
      final json = await ref.read(backupProvider).exportJson();
      final ok = await _saveBytes(
        'garage_log_${_stamp()}.json',
        'json',
        Uint8List.fromList(utf8.encode(json)),
        '匯出備份',
      );
      if (ok && context.mounted) showSnack(context, '已匯出備份');
    } catch (e) {
      if (context.mounted) showSnack(context, '匯出失敗：$e');
    }
  }

  Future<void> _exportCsv(BuildContext context, WidgetRef ref, bool fuel) async {
    try {
      final exporter = ref.read(csvProvider);
      final text = fuel ? await exporter.fuelCsv() : await exporter.maintenanceCsv();
      final ok = await _saveBytes(
        '${fuel ? 'fuel' : 'maintenance'}_${_stamp()}.csv',
        'csv',
        Uint8List.fromList(utf8.encode(text)),
        fuel ? '匯出加油紀錄 CSV' : '匯出保養紀錄 CSV',
      );
      if (ok && context.mounted) showSnack(context, '已匯出 CSV');
    } catch (e) {
      if (context.mounted) showSnack(context, '匯出失敗：$e');
    }
  }

  /// 匯入流程：選檔 → 預覽摘要並確認 → 先自動備份目前資料 → 合併匯入。
  Future<void> _import(BuildContext context, WidgetRef ref) async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        dialogTitle: '選擇備份檔',
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      final path = picked?.files.single.path;
      if (path == null) return;

      final text = await File(path).readAsString();
      final svc = ref.read(backupProvider);
      final preview = await svc.preview(text);
      if (!context.mounted) return;

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => _ImportPreviewDialog(preview: preview),
      );
      if (confirmed != true) return;

      // 匯入前先把目前資料備份一份，匯入結果不如預期時可以還原。
      await svc.writeAutoBackup(await autoBackupDirectory());

      final report = await svc.importJson(text);
      if (!context.mounted) return;
      if (report.anomalies > 0) {
        // 有需要確認的異常資料時用對話框，避免提示一閃而過
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('匯入完成，但有異常資料'),
            content: Text('$report'),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
      } else {
        showSnack(context, '匯入完成：$report');
      }
    } on FormatException catch (e) {
      if (context.mounted) showSnack(context, e.message);
    } catch (e) {
      if (context.mounted) showSnack(context, '匯入失敗：$e');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('資料備份與跨裝置同步', style: theme.textTheme.titleMedium),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '所有資料只存在這台裝置。要在手機與電腦間同步：在 A 裝置「匯出」，'
                  '傳到 B 裝置後「匯入」。匯入前會先顯示內容摘要、並自動備份目前資料；'
                  '合併時以較新的修改為準，重複匯入不會產生重複資料，兩邊可以來回操作。',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              ListTile(
                leading: const Icon(Icons.upload_file),
                title: const Text('匯出全部資料（JSON）'),
                onTap: () => _exportJson(context, ref),
              ),
              ListTile(
                leading: const Icon(Icons.download),
                title: const Text('匯入備份並合併'),
                subtitle: const Text('匯入前會預覽，並自動保留最近 5 份匯入前備份'),
                onTap: () => _import(context, ref),
              ),
              ListTile(
                leading: const Icon(Icons.restore),
                title: const Text('自動備份與完整復原'),
                subtitle: const Text('匯入出問題時，可把資料整個退回某份備份'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const RestorePage()),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.lock_outline, size: 16, color: theme.colorScheme.tertiary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '備份檔內含車牌、里程與維修紀錄且未加密，請妥善保管，不要傳到公開的地方。',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: SwitchListTile(
            secondary: const Icon(Icons.local_gas_station_outlined),
            title: const Text('首頁顯示今日油價'),
            subtitle: const Text('向台灣中油公開網址讀取牌價（只讀取，不上傳任何資料）。關閉後 App 完全不連網。'),
            value: ref.watch(fuelPriceEnabledProvider),
            onChanged: (v) => ref.read(fuelPriceEnabledProvider.notifier).set(v),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('匯出成 Excel 可開的 CSV', style: theme.textTheme.titleMedium),
              ),
              ListTile(
                leading: const Icon(Icons.table_chart_outlined),
                title: const Text('匯出加油紀錄（CSV）'),
                subtitle: const Text('全部車輛，含每次區間油耗'),
                onTap: () => _exportCsv(context, ref, true),
              ),
              ListTile(
                leading: const Icon(Icons.table_chart_outlined),
                title: const Text('匯出保養紀錄（CSV）'),
                subtitle: const Text('全部車輛，每個保養項目一列'),
                onTap: () => _exportCsv(context, ref, false),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        const Card(
          child: ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('愛車記錄 v$kAppVersion'),
            subtitle: Text('純本地、無廣告、開源。資料不會上傳到任何伺服器。'),
          ),
        ),
      ],
    );
  }
}

/// 窄螢幕從選單開啟的設定頁。
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: const SettingsPage(),
        ),
      ),
    );
  }
}

class _ImportPreviewDialog extends StatelessWidget {
  const _ImportPreviewDialog({required this.preview});

  final BackupPreview preview;

  @override
  Widget build(BuildContext context) {
    final d = preview.diff;
    final when = preview.exportedAt == null
        ? '未知'
        : DateFormat('yyyy-MM-dd HH:mm').format(preview.exportedAt!);
    return AlertDialog(
      title: const Text('匯入預覽'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('備份時間：$when'),
          const SizedBox(height: 8),
          Text('檔案內容：車輛 ${preview.vehicles}、加油 ${preview.fuelLogs}、'
              '保養 ${preview.maintenanceRecords}、週期 ${preview.plans}'),
          const SizedBox(height: 8),
          Text('與本機合併後：新增 ${d.added} 筆、更新 ${d.updated} 筆、略過 ${d.skipped} 筆'),
          if (d.anomalies > 0) ...[
            const SizedBox(height: 8),
            Text(
              '注意：合併後有 ${d.anomalies} 筆異常資料（找不到所屬車輛 / 保養單，或保養單沒有明細），'
              '會被保留但不顯示。',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            '「略過」是本機已經有、而且不比備份舊的資料。'
            '按下匯入前會自動備份目前資料。',
            style: Theme.of(context).textTheme.bodySmall,
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
          child: const Text('匯入'),
        ),
      ],
    );
  }
}

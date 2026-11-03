import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../providers.dart';
import 'common.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    try {
      final json = await ref.read(backupProvider).exportJson();
      final bytes = Uint8List.fromList(utf8.encode(json));
      final name =
          'garage_log_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.json';

      final path = await FilePicker.platform.saveFile(
        dialogTitle: '匯出備份',
        fileName: name,
        type: FileType.custom,
        allowedExtensions: const ['json'],
        bytes: bytes, // Android / iOS 必填；桌面端下面再自行寫檔
      );
      if (path == null) return;
      if (!_isMobile) {
        final target = path.toLowerCase().endsWith('.json') ? path : '$path.json';
        await File(target).writeAsBytes(bytes);
      }
      if (context.mounted) showSnack(context, '已匯出備份');
    } catch (e) {
      if (context.mounted) showSnack(context, '匯出失敗：$e');
    }
  }

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
      final report = await ref.read(backupProvider).importJson(text);
      if (context.mounted) {
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
                  '傳到 B 裝置後「匯入」。匯入採合併（較新的修改為準），'
                  '重複匯入不會產生重複資料，兩邊可以來回操作。',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              ListTile(
                leading: const Icon(Icons.upload_file),
                title: const Text('匯出全部資料（JSON）'),
                onTap: () => _export(context, ref),
              ),
              ListTile(
                leading: const Icon(Icons.download),
                title: const Text('匯入備份並合併'),
                onTap: () => _import(context, ref),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        const Card(
          child: ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('愛車記錄'),
            subtitle: Text('純本地、無廣告、開源。資料不會上傳到任何伺服器。'),
          ),
        ),
      ],
    );
  }
}

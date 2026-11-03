import 'dart:io';

import 'package:path/path.dart' as p;

import 'backup_service.dart';

/// 同步後端抽象：只負責「讀 / 寫一份 JSON 文字」。
///
/// 目前提供 [FolderSyncBackend]（指向 OneDrive / Syncthing / Google Drive 桌面版
/// 等已同步的資料夾）。之後可新增 Google Drive appDataFolder、WebDAV 等實作，
/// 合併邏輯（LWW）都在 [BackupService]，後端不需要知道資料格式。
abstract class SyncBackend {
  Future<String?> read();
  Future<void> write(String content);
}

class FolderSyncBackend implements SyncBackend {
  FolderSyncBackend(this.directory, {this.fileName = 'garage_log_sync.json'});

  final String directory;
  final String fileName;

  File get _file => File(p.join(directory, fileName));

  @override
  Future<String?> read() async =>
      await _file.exists() ? _file.readAsString() : null;

  @override
  Future<void> write(String content) async {
    // 先寫暫存檔再改名，避免同步軟體抓到寫一半的檔案。
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(_file.path);
  }
}

/// 一次完整同步：下載遠端 → 合併進本機 → 把合併後結果寫回遠端。
class SyncService {
  SyncService(this.backup);

  final BackupService backup;

  Future<ImportReport> sync(SyncBackend backend) async {
    var report = ImportReport();
    final remote = await backend.read();
    if (remote != null && remote.trim().isNotEmpty) {
      report = await backup.importJson(remote);
    }
    await backend.write(await backup.exportJson());
    return report;
  }
}

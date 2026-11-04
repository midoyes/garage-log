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
///
/// 為降低「兩台裝置同時覆寫同一份同步檔」的風險，寫回前會再讀一次遠端：
/// 如果合併期間遠端內容又變了，就重新合併一次再寫（最多重試 [maxAttempts] 次）。
/// 重試次數用完仍持續變動時，**不會**強制覆寫，而是丟出 [SyncConflictException]，
/// 請使用者稍後再試。
///
/// 這只能縮小競爭視窗，不是真正的鎖：比對之後、寫入之前仍可能有別台裝置寫入。
/// 要做安全的全自動同步，後端必須提供版本驗證 / 條件式寫入（例如 ETag）。
class SyncConflictException implements Exception {
  const SyncConflictException();

  @override
  String toString() => '遠端資料持續變更，同步已取消，請稍後重試';
}

class SyncService {
  SyncService(this.backup, {this.maxAttempts = 3});

  final BackupService backup;
  final int maxAttempts;

  Future<ImportReport> sync(SyncBackend backend) async {
    final total = ImportReport();
    String? seen;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final remote = await backend.read();
      if (remote != null && remote.trim().isNotEmpty && remote != seen) {
        final r = await backup.importJson(remote);
        total
          ..added += r.added
          ..updated += r.updated
          ..skipped += r.skipped
          ..repaired += r.repaired;
      }
      seen = remote;

      final content = await backup.exportJson();
      final latest = await backend.read();
      if (latest == remote) {
        await backend.write(content);
        return total;
      }
      // 遠端在我們合併期間被改過：重來一輪
    }
    throw const SyncConflictException();
  }
}

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garage_log/data/backup_service.dart';
import 'package:garage_log/data/database.dart';
import 'package:garage_log/data/repository.dart';
import 'package:garage_log/data/sync_service.dart';

class MemoryBackend implements SyncBackend {
  String? content;
  int writes = 0;

  @override
  Future<String?> read() async => content;

  @override
  Future<void> write(String c) async {
    content = c;
    writes++;
  }
}

void main() {
  late AppDatabase dbA;
  late AppDatabase dbB;
  late GarageRepository repoA;
  late GarageRepository repoB;
  late SyncService syncA;
  late SyncService syncB;
  var t = 1000;
  int clock() => t++;

  setUp(() {
    t = 1000;
    dbA = AppDatabase(NativeDatabase.memory());
    dbB = AppDatabase(NativeDatabase.memory());
    repoA = GarageRepository(dbA, clock: clock);
    repoB = GarageRepository(dbB, clock: clock);
    syncA = SyncService(BackupService(dbA, clock: clock));
    syncB = SyncService(BackupService(dbB, clock: clock));
  });

  tearDown(() async {
    await dbA.close();
    await dbB.close();
  });

  Future<Set<String>> names(GarageRepository r) async =>
      (await r.watchVehicles().first).map((v) => v.name).toSet();

  test('兩台裝置透過同一份同步檔來回同步', () async {
    final backend = MemoryBackend();

    await repoA.addVehicle(type: 0, name: 'A 的車');
    await syncA.sync(backend); // 遠端還沒有檔案：只寫出
    expect(backend.content, isNotNull);

    final r = await syncB.sync(backend);
    expect(r.added, 1);
    expect(await names(repoB), {'A 的車'});

    await repoB.addVehicle(type: 1, name: 'B 的車');
    await syncB.sync(backend);
    await syncA.sync(backend);

    expect(await names(repoA), {'A 的車', 'B 的車'});
    expect(await names(repoB), {'A 的車', 'B 的車'});
  });

  test('重複同步是冪等的：沒有變動時不新增也不更新', () async {
    final backend = MemoryBackend();
    await repoA.addVehicle(type: 0, name: '車');
    await syncA.sync(backend);
    final again = await syncA.sync(backend);
    expect(again.added, 0);
    expect(again.updated, 0);
  });

  test('合併期間遠端被改過：重新合併後再寫回，不會蓋掉對方的資料', () async {
    final inner = MemoryBackend();
    await repoA.addVehicle(type: 0, name: 'A 的車');
    await syncA.sync(inner);
    final stale = inner.content; // 只有 A 的車的舊內容

    // B 把自己的車放上去；A 同步時第一次讀到的仍是舊內容，
    // 但寫回前遠端已經變成「兩台車都有」
    await repoB.addVehicle(type: 0, name: 'B 的車');
    await syncB.sync(inner);

    final racing = _RacingBackend(inner, stale);
    await syncA.sync(racing);

    expect(await names(repoA), {'A 的車', 'B 的車'});
    // 最後寫回的內容同時包含兩台車
    final dbC = AppDatabase(NativeDatabase.memory());
    addTearDown(dbC.close);
    await BackupService(dbC).importJson(inner.content!);
    expect(await names(GarageRepository(dbC)), {'A 的車', 'B 的車'});
  });

  test('遠端持續變動、重試用完：丟出衝突，不強制覆寫遠端', () async {
    await repoB.addVehicle(type: 0, name: 'B 的車');
    final base = await BackupService(dbB).exportJson();
    final backend = _ChurningBackend(base);

    await expectLater(
      syncA.sync(backend),
      throwsA(isA<SyncConflictException>()),
    );
    expect(backend.writes, 0, reason: '衝突時絕對不能寫入遠端');
  });
}

/// 每次 read 都回傳「內容相同、但字串不同」的備份（尾端空白逐次增加），
/// 模擬遠端一直被別台裝置改動。
class _ChurningBackend implements SyncBackend {
  _ChurningBackend(this._base);

  final String _base;
  int _reads = 0;
  int writes = 0;

  @override
  Future<String?> read() async => _base + (' ' * (++_reads));

  @override
  Future<void> write(String content) async {
    writes++;
  }
}

/// 第一次 read 回傳舊內容，之後回傳最新內容，模擬「讀取之後遠端又被別人改了」。
class _RacingBackend implements SyncBackend {
  _RacingBackend(this.inner, this._stale);

  final MemoryBackend inner;
  final String? _stale;
  int _reads = 0;

  @override
  Future<String?> read() async => (_reads++ == 0) ? _stale : inner.content;

  @override
  Future<void> write(String content) => inner.write(content);
}

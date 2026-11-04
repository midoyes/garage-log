import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garage_log/data/backup_service.dart';
import 'package:garage_log/data/database.dart';
import 'package:garage_log/data/photo_store.dart';
import 'package:garage_log/data/repository.dart';
import 'package:garage_log/domain/maintenance_calculator.dart';
import 'package:image/image.dart' as img;

const _items = [ItemInput(name: '機油', quantity: 1, unitPrice: 500)];

void main() {
  late AppDatabase db;
  late GarageRepository repo;
  late String vid;
  var t = 1000;

  setUp(() async {
    t = 1000;
    db = AppDatabase(NativeDatabase.memory());
    repo = GarageRepository(db, clock: () => t++);
    vid = await repo.addVehicle(type: 0, name: '車');
  });
  tearDown(() => db.close());

  Future<String> save({String? id, List<PhotoInput>? photos}) =>
      repo.saveMaintenance(
        id: id,
        vehicleId: vid,
        date: DateTime(2026, 3, 1),
        odometer: 1000,
        items: _items,
        photos: photos,
      );

  group('儲存與編輯', () {
    test('新增保養單附多張照片，依順序保存', () async {
      final id = await save(photos: const [
        PhotoInput(fileName: 'a.jpg', sizeBytes: 1),
        PhotoInput(fileName: 'b.jpg', sizeBytes: 2),
        PhotoInput(fileName: 'c.jpg', sizeBytes: 3),
      ]);
      final list = await repo.watchPhotos().first;
      expect(list.map((p) => p.fileName), ['a.jpg', 'b.jpg', 'c.jpg']);
      expect(list.every((p) => p.recordId == id), isTrue);
    });

    test('photos 為 null：編輯時完全不動既有照片', () async {
      final id = await save(photos: const [PhotoInput(fileName: 'a.jpg')]);
      await save(id: id); // 不帶 photos
      expect(await repo.watchPhotos().first, hasLength(1));
    });

    test('編輯：移除一張、新增一張、調整順序', () async {
      final id = await save(photos: const [
        PhotoInput(fileName: 'a.jpg'),
        PhotoInput(fileName: 'b.jpg'),
      ]);
      final old = await repo.watchPhotos().first;
      final idA = old.firstWhere((p) => p.fileName == 'a.jpg').id;
      final idB = old.firstWhere((p) => p.fileName == 'b.jpg').id;
      await save(id: id, photos: [
        const PhotoInput(fileName: 'c.jpg'),
        PhotoInput(id: idB, fileName: 'b.jpg'),
      ]);
      final now = await repo.watchPhotos().first;
      expect(now.map((p) => p.fileName), ['c.jpg', 'b.jpg']);
      // a 是軟刪除（墓碑），不是真的刪掉
      final all = await db.select(db.maintenancePhotos).get();
      expect(all.firstWhere((p) => p.id == idA).isDeleted, isTrue);
    });

    test('不屬於這張保養單的照片 id 會被拒絕', () async {
      final id1 = await save(photos: const [PhotoInput(fileName: 'a.jpg')]);
      final other = await save();
      final a = (await repo.watchPhotos().first).single;
      await expectLater(
        save(id: other, photos: [PhotoInput(id: a.id, fileName: 'a.jpg')]),
        throwsA(isA<GarageValidationException>()),
      );
      expect(id1, isNot(other));
    });

    test('不安全的檔名（路徑、..）一律拒絕', () async {
      for (final bad in ['../x.jpg', 'a/b.jpg', r'a\b.jpg', '', '..', '.hidden']) {
        await expectLater(
          save(photos: [PhotoInput(fileName: bad)]),
          throwsA(isA<GarageValidationException>()),
          reason: bad,
        );
      }
    });

    test('刪除保養單：照片一併軟刪除，列表不再出現', () async {
      final id = await save(photos: const [PhotoInput(fileName: 'a.jpg')]);
      await repo.deleteMaintenance(id);
      expect(await repo.watchPhotos().first, isEmpty);
      expect((await db.select(db.maintenancePhotos).get()).single.isDeleted, isTrue);
    });

    test('刪除車輛：底下保養單的照片一併軟刪除', () async {
      await save(photos: const [PhotoInput(fileName: 'a.jpg')]);
      await repo.deleteVehicle(vid);
      expect(await repo.watchPhotos().first, isEmpty);
    });
  });

  group('備份', () {
    late AppDatabase db2;
    late BackupService svc1;
    late BackupService svc2;
    setUp(() {
      db2 = AppDatabase(NativeDatabase.memory());
      svc1 = BackupService(db, clock: () => t++);
      svc2 = BackupService(db2, clock: () => t++);
    });
    tearDown(() => db2.close());

    test('匯出含照片記錄；另一台匯入後有同樣的記錄', () async {
      await save(photos: const [
        PhotoInput(fileName: 'a.jpg', sizeBytes: 5),
        PhotoInput(fileName: 'b.jpg', sizeBytes: 6),
      ]);
      final json = await svc1.exportJson();
      final preview = await svc2.preview(json);
      expect(preview.photos, 2);
      await svc2.importJson(json);
      final got = await db2.select(db2.maintenancePhotos).get();
      expect(got.map((p) => p.fileName).toSet(), {'a.jpg', 'b.jpg'});
    });

    test('v2 備份（沒有照片資料表）：完整復原不會把本機照片清掉', () async {
      await save(photos: const [PhotoInput(fileName: 'a.jpg')]);
      final map = await svc1.exportMap();
      map.remove('maintenancePhotos');
      map['formatVersion'] = 2;
      final text = jsonEncode(map);
      final impact = await svc1.restoreImpact(text);
      expect(impact.tables.any((x) => x.label == '保養照片'), isFalse);
      await svc1.restoreSnapshot(text);
      expect(await repo.watchPhotos().first, hasLength(1));
    });

    test('備份檔內含不安全檔名的照片：整份拒絕', () async {
      await save(photos: const [PhotoInput(fileName: 'a.jpg')]);
      final map = await svc1.exportMap();
      (map['maintenancePhotos'] as List).first['fileName'] = '../../evil.jpg';
      await expectLater(
        svc2.importJson(jsonEncode(map)),
        throwsA(isA<FormatException>()),
      );
    });

    test('完整復原：備份當時沒有的照片會被移除（留墓碑）', () async {
      final id = await save(photos: const [PhotoInput(fileName: 'a.jpg')]);
      final snapshot = await svc1.exportJson();
      final cur = await repo.watchPhotos().first;
      await save(id: id, photos: [
        PhotoInput(id: cur.single.id, fileName: 'a.jpg'),
        const PhotoInput(fileName: 'b.jpg'),
      ]);
      expect(await repo.watchPhotos().first, hasLength(2));
      await svc1.restoreSnapshot(snapshot);
      expect((await repo.watchPhotos().first).map((p) => p.fileName), ['a.jpg']);
    });
  });

  group('圖片處理', () {
    Uint8List makePng(int w, int h) {
      final image = img.Image(width: w, height: h);
      img.fill(image, color: img.ColorRgb8(200, 30, 30));
      return Uint8List.fromList(img.encodePng(image));
    }

    test('大圖縮到長邊 1600，轉成 JPEG', () {
      final out = compressPhoto(makePng(3200, 2000));
      final decoded = img.decodeJpg(out)!;
      expect(decoded.width, 1600);
      expect(decoded.height, 1000);
    });

    test('小圖不放大', () {
      final decoded = img.decodeJpg(compressPhoto(makePng(400, 300)))!;
      expect(decoded.width, 400);
      expect(decoded.height, 300);
    });

    test('不是圖片的資料丟出 FormatException', () {
      expect(() => compressPhoto(Uint8List.fromList([1, 2, 3, 4])),
          throwsFormatException);
    });

    test('檔名檢查', () {
      expect(isSafePhotoName('3f2a-91.jpg'), isTrue);
      expect(isSafePhotoName('../a.jpg'), isFalse);
      expect(isSafePhotoName('a/b.jpg'), isFalse);
      expect(isSafePhotoName(''), isFalse);
    });

    test('PhotoStore：存檔、讀取、刪除，且拒絕不安全檔名', () async {
      final dir = await Directory.systemTemp.createTemp('photos_test');
      addTearDown(() => dir.delete(recursive: true));
      final store = PhotoStore(dir);
      final r = await store.saveCompressed(Uint8List.fromList([1, 2, 3]));
      expect(await store.exists(r.fileName), isTrue);
      expect(r.size, 3);
      await store.delete(r.fileName);
      expect(await store.exists(r.fileName), isFalse);
      expect(() => store.fileOf('../x'), throwsArgumentError);
    });
  });
}

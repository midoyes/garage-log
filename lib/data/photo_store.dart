/// 保養照片的檔案儲存：壓縮、存檔、讀取、刪除。
///
/// 圖檔放在 App 私有資料夾的 photos/ 底下，檔名 = UUID + .jpg。
/// 資料庫（maintenance_photos）只記錄檔名，不記路徑，所以換裝置 / 還原備份都不會有路徑問題。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// 長邊上限與 JPEG 品質：1600px / 82 約 200～400KB，車況、單據、零件都看得清楚。
const kPhotoMaxSide = 1600;
const kPhotoQuality = 82;

final _safeName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');

/// 檔名是否安全（防止備份檔夾帶 ../ 之類的路徑）。
bool isSafePhotoName(String name) => _safeName.hasMatch(name) && !name.contains('..');

/// 壓縮並轉成 JPEG（純函式，可在 isolate 內執行）。
/// 會依 EXIF 轉正方向，長邊超過 [maxSide] 才縮小（不放大）。解碼失敗丟出 [FormatException]。
Uint8List compressPhoto(
  Uint8List bytes, {
  int maxSide = kPhotoMaxSide,
  int quality = kPhotoQuality,
}) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw const FormatException('不是可以讀取的圖片');
  var image = img.bakeOrientation(decoded);
  final longest = image.width > image.height ? image.width : image.height;
  if (longest > maxSide) {
    image = image.width >= image.height
        ? img.copyResize(image, width: maxSide)
        : img.copyResize(image, height: maxSide);
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: quality));
}

class PhotoStore {
  PhotoStore(this.dir, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final Directory dir;
  final Uuid _uuid;

  File fileOf(String fileName) {
    if (!isSafePhotoName(fileName)) {
      throw ArgumentError('不安全的照片檔名：$fileName');
    }
    return File(p.join(dir.path, fileName));
  }

  Future<bool> exists(String fileName) async =>
      isSafePhotoName(fileName) && await fileOf(fileName).exists();

  /// 壓縮（背景執行，不卡畫面）後存檔，回傳 (檔名, 檔案大小)。
  Future<({String fileName, int size})> addFromBytes(Uint8List bytes) async {
    final jpg = await compute(compressPhoto, bytes);
    return saveCompressed(jpg);
  }

  /// 已經是壓縮好的 JPEG（例如從備份還原）時直接存檔。
  Future<({String fileName, int size})> saveCompressed(Uint8List jpg,
      {String? fileName}) async {
    await dir.create(recursive: true);
    final name = fileName ?? '${_uuid.v4()}.jpg';
    if (!isSafePhotoName(name)) throw ArgumentError('不安全的照片檔名：$name');
    await File(p.join(dir.path, name)).writeAsBytes(jpg, flush: true);
    return (fileName: name, size: jpg.length);
  }

  Future<void> delete(String fileName) async {
    try {
      if (!isSafePhotoName(fileName)) return;
      final f = fileOf(fileName);
      if (await f.exists()) await f.delete();
    } catch (_) {
      // 刪不掉只是多留一個檔案，不影響資料
    }
  }
}

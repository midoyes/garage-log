/// 今日油價（台灣中油公開牌價）。
///
/// 只做一件事：對公開網址發一個 GET，取回各油品今日牌價。不上傳任何資料。
/// 取不到（沒網路、網站改版）時回傳上次成功的快取，首頁顯示「上次更新」。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';

const kCpcPriceUrl =
    'https://vipmbr.cpc.com.tw/CPCSTN/ListPriceWebService.asmx/getCPCMainProdListPrice_Chinese';

class FuelPrice {
  const FuelPrice(this.name, this.price);
  final String name; // 例如 98無鉛、95無鉛、92無鉛、超級/高級柴油
  final double price;

  Map<String, dynamic> toJson() => {'name': name, 'price': price};
  static FuelPrice? fromJson(Object? j) {
    if (j is! Map) return null;
    final n = j['name'];
    final p = j['price'];
    if (n is! String || p is! num) return null;
    return FuelPrice(n, p.toDouble());
  }
}

class FuelPriceSnapshot {
  const FuelPriceSnapshot({
    required this.prices,
    required this.fetchedAt,
    this.effective,
    this.fromCache = false,
  });

  final List<FuelPrice> prices;
  final DateTime fetchedAt;

  /// 牌價生效日（來源有提供才有）
  final String? effective;

  /// true = 這次連不上，顯示的是上次成功的資料
  final bool fromCache;

  FuelPriceSnapshot asCache() => FuelPriceSnapshot(
      prices: prices, fetchedAt: fetchedAt, effective: effective, fromCache: true);

  Map<String, dynamic> toJson() => {
        'prices': [for (final p in prices) p.toJson()],
        'fetchedAt': fetchedAt.millisecondsSinceEpoch,
        'effective': effective,
      };

  static FuelPriceSnapshot? fromJson(Object? j) {
    if (j is! Map) return null;
    final list = j['prices'];
    final at = j['fetchedAt'];
    if (list is! List || at is! int) return null;
    final prices = <FuelPrice>[];
    for (final e in list) {
      final fp = FuelPrice.fromJson(e);
      if (fp != null) prices.add(fp);
    }
    if (prices.isEmpty) return null;
    return FuelPriceSnapshot(
      prices: prices,
      fetchedAt: DateTime.fromMillisecondsSinceEpoch(at),
      effective: j['effective'] as String?,
    );
  }
}

/// 解析中油回傳的 XML（容錯：找不到的欄位就略過，不丟例外給畫面）。
///
/// 預期每個 `<tbTable>` 節點含「產品名稱」「參考牌價_金額」，
/// 可能有「牌價生效時間」。只保留汽油 92/95/98 與柴油。
FuelPriceSnapshot? parseCpcPrices(String body, {DateTime? now}) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(body);
  } on XmlException {
    return null;
  }
  final prices = <FuelPrice>[];
  String? effective;
  // 欄位名稱有不同版本的說法（tbTable / UpdateData；參考牌價_金額 / 牌價），都接受
  final rows = doc.descendants
      .whereType<XmlElement>()
      .where((e) => e.findElements('產品名稱').isNotEmpty);
  for (final row in rows) {
    String? text(String tag) {
      final e = row.findElements(tag).firstOrNull;
      final t = e?.innerText.trim();
      return (t == null || t.isEmpty) ? null : t;
    }

    final name = text('產品名稱');
    final price =
        double.tryParse(text('參考牌價_金額') ?? text('牌價') ?? '');
    if (name == null || price == null || !price.isFinite || price <= 0) continue;
    final keep = name.contains('98') ||
        name.contains('95') ||
        name.contains('92') ||
        name.contains('柴油');
    if (!keep) continue;
    prices.add(FuelPrice(name, price));
    effective ??= text('牌價生效時間');
  }
  if (prices.isEmpty) return null;
  prices.sort((a, b) => _rank(a.name).compareTo(_rank(b.name)));
  return FuelPriceSnapshot(
      prices: prices, fetchedAt: now ?? DateTime.now(), effective: effective);
}

int _rank(String n) {
  if (n.contains('98')) return 0;
  if (n.contains('95')) return 1;
  if (n.contains('92')) return 2;
  return 3;
}

class FuelPriceService {
  static const _cacheKey = 'fuel_price_cache';
  static const enabledKey = 'fuel_price_enabled';

  Future<FuelPriceSnapshot?> loadCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null) return null;
      return FuelPriceSnapshot.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  /// 抓最新牌價；失敗時回傳上次快取（標記 fromCache），都沒有就回 null。
  Future<FuelPriceSnapshot?> fetch() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.parse(kCpcPriceUrl));
      final res = await req.close().timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final body = await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 12));
      final snap = parseCpcPrices(body);
      if (snap == null) throw const FormatException('無法解析油價資料');
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_cacheKey, jsonEncode(snap.toJson()));
      } catch (_) {}
      return snap;
    } catch (_) {
      return (await loadCache())?.asCache();
    } finally {
      client.close(force: true);
    }
  }
}

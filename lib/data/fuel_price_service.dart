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

/// 由 GitHub Actions 定時產生的 JSON（見 tools/fetch_oil_price.py）。
/// 倉庫需為公開，或改放到公開的 GitHub Pages。
const kOilJsonUrl =
    'https://raw.githubusercontent.com/midoyes/garage-log/main/data/oil_price.json';

/// 中油官方開放資料（JSON）。舊的 ListPriceWebService 會被防火牆擋（Request Rejected）。
const kCpcPriceUrl = 'https://vipmbr.cpc.com.tw/openData/MainProdListPrice';

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

/// 下週趨勢（實驗性）：只有方向與國際油價指標變動，不含價格，也不含中油政策吸收。
class FuelForecast {
  const FuelForecast({
    required this.trend,
    required this.pct,
    required this.weekStart,
    required this.daysKnown,
  });
  final String trend; // up / down / flat
  final double pct;
  final String weekStart; // 預測適用的週一
  final int daysKnown;
}

class FuelPriceSnapshot {
  const FuelPriceSnapshot({
    required this.prices,
    required this.fetchedAt,
    this.effective,
    this.fromCache = false,
    this.deltas = const {},
    this.forecast,
  });

  /// 下週趨勢（實驗）。已有官方公告（生效日 ≥ 預測週）時為 null。
  final FuelForecast? forecast;

  /// 與上一次不同牌價相比的差額（油品名稱 → 元/公升），沒有上一次就是空的
  final Map<String, double> deltas;

  final List<FuelPrice> prices;
  final DateTime fetchedAt;

  /// 牌價生效日（來源有提供才有）
  final String? effective;

  /// true = 這次連不上，顯示的是上次成功的資料
  final bool fromCache;

  FuelPriceSnapshot asCache() => FuelPriceSnapshot(
      prices: prices,
      fetchedAt: fetchedAt,
      effective: effective,
      fromCache: true,
      deltas: deltas,
      forecast: forecast);

  Map<String, dynamic> toJson() => {
        'prices': [for (final p in prices) p.toJson()],
        'fetchedAt': fetchedAt.millisecondsSinceEpoch,
        'effective': effective,
        'deltas': deltas,
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
      deltas: {
        if (j['deltas'] is Map)
          for (final e in (j['deltas'] as Map).entries)
            if (e.key is String && e.value is num)
              e.key as String: (e.value as num).toDouble(),
      },
    );
  }
}

const _jsonNames = {
  '98': '98無鉛',
  '95': '95無鉛',
  '92': '92無鉛',
  'diesel': '柴油',
};

FuelForecast? _parseForecast(Object? p, String? effective) {
  if (p is! Map) return null;
  final trend = p['trend'];
  final pct = p['index_change_pct'];
  final ws = p['week_start'];
  if (trend is! String || pct is! num || ws is! String) return null;
  if (!const {'up', 'down', 'flat'}.contains(trend)) return null;
  // 中油已公告該週（或更新）的牌價 → 以官方為準，不再顯示預測
  if (effective != null && effective.compareTo(ws) >= 0) return null;
  return FuelForecast(
    trend: trend,
    pct: pct.toDouble(),
    weekStart: ws,
    daysKnown: (p['days_known'] is int) ? p['days_known'] as int : 0,
  );
}

/// 解析 oil_price.json（schema 1）。格式不符回傳 null。
FuelPriceSnapshot? parseOilJson(String body, {DateTime? now}) {
  try {
    final j = jsonDecode(body);
    if (j is! Map || j['schema'] != 1) return null;
    final cur = j['current'];
    if (cur is! Map || cur['prices'] is! Map) return null;
    final curPrices = <String, double>{
      for (final e in (cur['prices'] as Map).entries)
        if (e.key is String && e.value is num && (e.value as num) > 0)
          e.key as String: (e.value as num).toDouble(),
    };
    final prev = j['previous'];
    final prevPrices = (prev is Map && prev['prices'] is Map)
        ? <String, double>{
            for (final e in (prev['prices'] as Map).entries)
              if (e.key is String && e.value is num)
                e.key as String: (e.value as num).toDouble(),
          }
        : <String, double>{};
    final prices = <FuelPrice>[];
    final deltas = <String, double>{};
    for (final k in ['98', '95', '92', 'diesel']) {
      final v = curPrices[k];
      if (v == null) continue;
      final name = _jsonNames[k]!;
      prices.add(FuelPrice(name, v));
      final p = prevPrices[k];
      if (p != null) deltas[name] = double.parse((v - p).toStringAsFixed(2));
    }
    if (prices.isEmpty) return null;
    return FuelPriceSnapshot(
      prices: prices,
      fetchedAt: now ?? DateTime.now(),
      effective: cur['effective'] as String?,
      deltas: deltas,
      forecast: _parseForecast(j['prediction'], cur['effective'] as String?),
    );
  } catch (_) {
    return null;
  }
}

/// 解析中油回傳的 XML（容錯：找不到的欄位就略過，不丟例外給畫面）。
///
/// 預期每個 `<tbTable>` 節點含「產品名稱」「參考牌價_金額」，
/// 可能有「牌價生效時間」。只保留汽油 92/95/98 與柴油。
FuelPriceSnapshot? parseCpcPrices(String body, {DateTime? now}) {
  final t = body.trimLeft();
  if (t.startsWith('[') || t.startsWith('{')) return _parseCpcJson(t, now: now);
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(body);
  } on XmlException {
    // 中油回傳的 XML 曾經標籤不成對：改用正規表示式容錯解析
    return _parseCpcLoose(body, now: now);
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

/// 中油 openData JSON：每列有「產品名稱」「參考牌價_金額」「牌價生效日期（民國 7 碼）」。
FuelPriceSnapshot? _parseCpcJson(String body, {DateTime? now}) {
  try {
    final j = jsonDecode(body);
    if (j is! List) return null;
    final prices = <FuelPrice>[];
    final seen = <int>{};
    String? effective;
    for (final r in j) {
      if (r is! Map) continue;
      final name = r['產品名稱'];
      final raw = r['參考牌價_金額'];
      if (name is! String || raw is! num) continue;
      final price = raw.toDouble();
      if (price < 20 || price > 60) continue; // 排除用「元/公秉」等其他單位的油品
      if (!(name.contains('98') ||
          name.contains('95') ||
          name.contains('92') ||
          name.contains('柴油'))) {
        continue;
      }
      if (!seen.add(_rank(name))) continue;
      prices.add(FuelPrice(name, price));
      final d = r['牌價生效日期']?.toString();
      if (effective == null && d != null) {
        effective = RegExp(r'^\d{7}$').hasMatch(d)
            ? '${int.parse(d.substring(0, 3)) + 1911}-${d.substring(3, 5)}-${d.substring(5, 7)}'
            : d;
      }
    }
    if (prices.isEmpty) return null;
    prices.sort((a, b) => _rank(a.name).compareTo(_rank(b.name)));
    return FuelPriceSnapshot(
        prices: prices, fetchedAt: now ?? DateTime.now(), effective: effective);
  } catch (_) {
    return null;
  }
}

FuelPriceSnapshot? _parseCpcLoose(String body, {DateTime? now}) {
  final prices = <FuelPrice>[];
  String? effective;
  final seen = <int>{};
  for (final blk in body.split('<產品名稱>').skip(1)) {
    final nm = RegExp(r'^\s*([^<]+?)\s*</產品名稱>').firstMatch(blk);
    final pm = RegExp(r'<(?:參考牌價_金額|牌價)>\s*([0-9]+(?:\.[0-9]+)?)\s*<')
        .firstMatch(blk);
    if (nm == null || pm == null) continue;
    final name = nm.group(1)!;
    final price = double.tryParse(pm.group(1)!);
    if (price == null || price <= 0) continue;
    if (!(name.contains('98') ||
        name.contains('95') ||
        name.contains('92') ||
        name.contains('柴油'))) {
      continue;
    }
    if (!seen.add(_rank(name))) continue;
    prices.add(FuelPrice(name, price));
    effective ??=
        RegExp(r'<牌價生效時間>\s*([^<]+?)\s*<').firstMatch(blk)?.group(1);
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

  Future<String> _get(HttpClient client, String url) async {
    client.userAgent =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36';
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close().timeout(const Duration(seconds: 12));
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
    return res.transform(utf8.decoder).join().timeout(const Duration(seconds: 12));
  }

  /// 抓最新牌價：先讀專案的 oil_price.json，失敗再直接問中油；
  /// 都失敗回傳上次快取（標記 fromCache），都沒有就回 null。
  Future<FuelPriceSnapshot?> fetch() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      FuelPriceSnapshot? snap;
      try {
        snap = parseOilJson(await _get(client, kOilJsonUrl));
      } catch (_) {}
      if (snap == null) {
        snap = parseCpcPrices(await _get(client, kCpcPriceUrl));
        if (snap == null) throw const FormatException('無法解析油價資料');
      }
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

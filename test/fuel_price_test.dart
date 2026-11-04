import 'package:flutter_test/flutter_test.dart';
import 'package:garage_log/data/fuel_price_service.dart';

void main() {
  const sample = '''<?xml version="1.0" encoding="utf-8"?>
<CPC xmlns="http://tempuri.org/"><NewDataSet>
<tbTable><產品編號>1</產品編號><產品名稱>92無鉛汽油</產品名稱><參考牌價_金額>31.2</參考牌價_金額><牌價生效時間>2026-11-02</牌價生效時間></tbTable>
<tbTable><產品名稱>98無鉛汽油</產品名稱><參考牌價_金額>34.7</參考牌價_金額></tbTable>
<tbTable><產品名稱>95無鉛汽油</產品名稱><參考牌價_金額>32.7</參考牌價_金額></tbTable>
<tbTable><產品名稱>超級/高級柴油</產品名稱><參考牌價_金額>29.9</參考牌價_金額></tbTable>
<tbTable><產品名稱>煤油</產品名稱><參考牌價_金額>20</參考牌價_金額></tbTable>
</NewDataSet></CPC>''';

  test('解析：保留 98/95/92/柴油並依序排列，忽略其他', () {
    final s = parseCpcPrices(sample)!;
    expect(s.prices.map((p) => p.price), [34.7, 32.7, 31.2, 29.9]);
    expect(s.effective, '2026-11-02');
  });
  test('另一種欄位命名（UpdateData / 牌價）也能解析', () {
    const alt = '<r><UpdateData><產品名稱>95無鉛汽油</產品名稱><牌價>32.7</牌價></UpdateData></r>';
    expect(parseCpcPrices(alt)!.prices.single.price, 32.7);
  });
  test('中油 openData JSON：解析牌價與民國生效日', () {
    const j = '[{"型別名稱":"汽柴油零售","產品名稱":"98無鉛汽油","參考牌價_金額":34.7000,"牌價生效日期":"1151102"},'
        '{"型別名稱":"汽柴油零售","產品名稱":"95無鉛汽油","參考牌價_金額":32.7000,"牌價生效日期":"1151102"},'
        '{"型別名稱":"汽柴油零售","產品名稱":"92無鉛汽油","參考牌價_金額":31.2000,"牌價生效日期":"1151102"},'
        '{"型別名稱":"汽柴油零售","產品名稱":"超級/高級柴油","參考牌價_金額":29.9000,"牌價生效日期":"1151102"},'
        '{"型別名稱":"國內海運燃油","產品名稱":"海運輕柴油","參考牌價_金額":29900.0}]';
    final s = parseCpcPrices(j)!;
    expect(s.prices.map((p) => p.price), [34.7, 32.7, 31.2, 29.9]);
    expect(s.effective, '2026-11-02');
  });
  test('標籤不成對的壞 XML 也能容錯解析', () {
    const bad = '<a><產品名稱>95無鉛汽油</產品名稱><參考牌價_金額>32.7</參考牌價_金額></b>'
        '<產品名稱>92無鉛汽油</產品名稱><參考牌價_金額>31.2</參考牌價_金額>';
    final s = parseCpcPrices(bad)!;
    expect(s.prices.map((p) => p.price), [32.7, 31.2]);
  });
  test('壞資料回傳 null 不丟例外', () {
    expect(parseCpcPrices('not xml'), isNull);
    expect(parseCpcPrices('<a/>'), isNull);
  });
  test('快取 JSON 來回', () {
    final s = parseCpcPrices(sample)!;
    final back = FuelPriceSnapshot.fromJson(s.toJson())!;
    expect(back.prices.length, 4);
  });

  test('oil_price.json：解析牌價與較上次差額', () {
    const j = '{"schema":1,"current":{"effective":"2026-11-02","prices":{"98":34.7,"95":32.7,"92":31.2,"diesel":29.9}},'
        '"previous":{"effective":"2026-10-26","prices":{"98":34.2,"95":32.2,"92":31.2,"diesel":30.4}}}';
    final s = parseOilJson(j)!;
    expect(s.prices.map((p) => p.name), ['98無鉛', '95無鉛', '92無鉛', '柴油']);
    expect(s.deltas['98無鉛'], 0.5);
    expect(s.deltas['柴油'], -0.5);
    expect(s.effective, '2026-11-02');
  });
  test('oil_price.json：趨勢預測；官方已公告該週後隱藏', () {
    String j(String eff) => '{"schema":1,"current":{"effective":"$eff","prices":{"95":32.7}},'
        '"prediction":{"trend":"up","index_change_pct":1.2,"week_start":"2026-11-09","days_known":3}}';
    final s = parseOilJson(j('2026-11-02'))!;
    expect(s.forecast!.trend, 'up');
    expect(s.forecast!.daysKnown, 3);
    expect(parseOilJson(j('2026-11-09'))!.forecast, isNull);
  });
  test('oil_price.json：schema 不符或壞資料 → null', () {
    expect(parseOilJson('{"schema":2}'), isNull);
    expect(parseOilJson('oops'), isNull);
  });
}

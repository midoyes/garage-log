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
  test('壞資料回傳 null 不丟例外', () {
    expect(parseCpcPrices('not xml'), isNull);
    expect(parseCpcPrices('<a/>'), isNull);
  });
  test('快取 JSON 來回', () {
    final s = parseCpcPrices(sample)!;
    final back = FuelPriceSnapshot.fromJson(s.toJson())!;
    expect(back.prices.length, 4);
  });
}

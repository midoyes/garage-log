import 'package:flutter_test/flutter_test.dart';
import 'package:garage_log/domain/maintenance_calculator.dart';

void main() {
  group('validateItemInput', () {
    test('合法：數量 > 0、單價 >= 0', () {
      expect(
        validateItemInput(const ItemInput(name: '機油', quantity: 4, unitPrice: 350)),
        isNull,
      );
    });

    test('單價 0（保固 / 免費）允許', () {
      expect(
        validateItemInput(const ItemInput(name: '工資', quantity: 1, unitPrice: 0)),
        isNull,
      );
    });

    test('負數數量被擋下（避免小計變成負數）', () {
      expect(
        validateItemInput(const ItemInput(name: '機油', quantity: -2, unitPrice: 500)),
        isNotNull,
      );
    });

    test('數量 0、NaN、無限大被擋下', () {
      for (final q in [0.0, double.nan, double.infinity]) {
        expect(
          validateItemInput(ItemInput(name: '機油', quantity: q, unitPrice: 100)),
          isNotNull,
          reason: 'quantity=$q',
        );
      }
    });

    test('負單價、NaN 單價被擋下', () {
      for (final p in [-1.0, double.nan]) {
        expect(
          validateItemInput(ItemInput(name: '機油', quantity: 1, unitPrice: p)),
          isNotNull,
          reason: 'unitPrice=$p',
        );
      }
    });

    test('名稱空白被擋下', () {
      expect(
        validateItemInput(const ItemInput(name: '  ', quantity: 1, unitPrice: 100)),
        isNotNull,
      );
    });
  });

  group('金額計算', () {
    test('數值不合法時小計顯示為 0，不會出現 NaN', () {
      const i = ItemInput(name: 'x', quantity: double.nan, unitPrice: 100);
      expect(i.subtotal, 0);
      expect(computeItemsTotal([i]), 0);
    });
  });

  group('normalizeItemName / quickItemsFor', () {
    test('忽略前後空白、多餘空白與大小寫', () {
      expect(normalizeItemName('  機油 '), normalizeItemName('機油'));
      expect(normalizeItemName('Engine   Oil'), normalizeItemName('engine oil'));
      expect(normalizeItemName('機油'), isNot(normalizeItemName('機油濾芯')));
    });

    test('汽機車有各自的常用項目', () {
      expect(quickItemsFor(0), contains('冷氣濾網'));
      expect(quickItemsFor(0), isNot(contains('普利珠')));
      expect(quickItemsFor(1), contains('普利珠'));
      expect(quickItemsFor(1), isNot(contains('冷氣濾網')));
    });
  });
}

/// 保養明細金額計算（純 Dart）。
library;

/// 常用保養快速選單。
const kQuickMaintenanceItems = <String>[
  '機油',
  '齒輪油',
  '機油濾芯',
  '空氣濾芯',
  '輪胎',
  '煞車皮',
  '火星塞',
  '電瓶',
  '傳動皮帶',
  '工資',
];

/// 金額四捨五入到小數 2 位，避免浮點誤差累積。
double roundMoney(double v) => (v * 100).round() / 100;

/// 表單 / 儲存用的保養明細。
class ItemInput {
  const ItemInput({
    this.id,
    required this.name,
    required this.quantity,
    required this.unitPrice,
  });

  /// 既有明細的 UUID；新明細為 null（儲存時才產生）。
  final String? id;
  final String name;
  final double quantity;
  final double unitPrice;

  /// 小計 = 數量 × 單價
  double get subtotal => roundMoney(quantity * unitPrice);
}

/// 明細總金額 = 各小計加總。
double computeItemsTotal(Iterable<ItemInput> items) =>
    roundMoney(items.fold<double>(0, (sum, i) => sum + i.subtotal));

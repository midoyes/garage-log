/// 保養明細金額計算與驗證（純 Dart）。
library;

/// 汽車常用保養項目。
const kCarQuickItems = <String>[
  '機油',
  '機油濾芯',
  '空氣濾芯',
  '冷氣濾網',
  '煞車皮',
  '煞車油',
  '火星塞',
  '電瓶',
  '輪胎',
  '變速箱油',
  '冷卻水',
  '雨刷',
  '工資',
];

/// 機車常用保養項目。
const kMotoQuickItems = <String>[
  '機油',
  '齒輪油',
  '機油濾芯',
  '空氣濾芯',
  '煞車皮',
  '輪胎',
  '火星塞',
  '傳動皮帶',
  '普利珠',
  '電瓶',
  '工資',
];

/// 依車種取得預設常用項目（0 = 汽車, 1 = 機車）。
List<String> quickItemsFor(int vehicleType) =>
    vehicleType == 1 ? kMotoQuickItems : kCarQuickItems;

/// 金額四捨五入到小數 2 位，避免浮點誤差累積。
double roundMoney(double v) => (v * 100).round() / 100;

/// 項目名稱正規化，用於比對「同一個零件」（忽略前後空白、多餘空白與大小寫）。
String normalizeItemName(String s) =>
    s.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

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

  /// 小計 = 數量 × 單價。數值不合法時回傳 0（僅供畫面即時顯示；
  /// 儲存前一定會先經過 [validateItemInput]）。
  double get subtotal {
    final s = quantity * unitPrice;
    return s.isFinite ? roundMoney(s) : 0;
  }
}

/// 驗證單一明細。合法回傳 null，否則回傳錯誤訊息。
///
/// - 名稱不可空白
/// - 數量必須是大於 0 的有限數
/// - 單價必須是不小於 0 的有限數（0 元代表保固 / 免費，允許）
String? validateItemInput(ItemInput i) {
  final label = i.name.trim().isEmpty ? '項目' : '「${i.name.trim()}」';
  if (i.name.trim().isEmpty) return '項目名稱不可空白';
  if (!i.quantity.isFinite || i.quantity <= 0) return '$label數量必須大於 0';
  if (!i.unitPrice.isFinite || i.unitPrice < 0) return '$label單價不可為負數';
  return null;
}

/// 明細總金額 = 各小計加總。
double computeItemsTotal(Iterable<ItemInput> items) =>
    roundMoney(items.fold<double>(0, (sum, i) => sum + i.subtotal));

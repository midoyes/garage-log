import 'package:flutter/material.dart';

import 'navigation.dart';

const kAppVersion = '0.2.2';

/// 油品選項。
const kFuelTypes = <String>['92', '95', '98', '柴油', '其他'];

/// 目前沒有任何車輛時的提示。
class NoVehicleHint extends StatelessWidget {
  const NoVehicleHint({super.key});

  @override
  Widget build(BuildContext context) => EmptyHint(
        icon: Icons.directions_car_outlined,
        text: '還沒有車輛，先新增一台吧',
        action: FilledButton.icon(
          onPressed: () => openVehicleForm(context),
          icon: const Icon(Icons.add),
          label: const Text('新增車輛'),
        ),
      );
}

class EmptyHint extends StatelessWidget {
  const EmptyHint({super.key, required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;

  /// 提示文字下方的操作按鈕（選填）
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outline;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: color),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center, style: TextStyle(color: color)),
            if (action != null) ...[
              const SizedBox(height: 16),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmText = '刪除',
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmText),
        ),
      ],
    ),
  );
  return result ?? false;
}

void showSnack(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// 表單頁共用外框：置中並限制最大寬度（桌面寬螢幕不會拉得過寬）。
///
/// 儲存流程統一在這裡處理：
/// - 按下儲存後進入「儲存中」狀態，按鈕停用並顯示轉圈，避免連續點擊重複新增
/// - [onSave] 完成（成功或丟出例外）後才恢復
class FormScaffold extends StatefulWidget {
  const FormScaffold({
    super.key,
    required this.title,
    required this.children,
    required this.onSave,
    this.bottom,
  });

  final String title;
  final List<Widget> children;
  final Future<void> Function() onSave;

  /// 顯示在儲存按鈕上方的區塊（例如保養總金額）。
  final Widget? bottom;

  @override
  State<FormScaffold> createState() => _FormScaffoldState();
}

class _FormScaffoldState extends State<FormScaffold> {
  bool _saving = false;

  Future<void> _handleSave() async {
    if (_saving) return; // 即使按鈕還沒重繪，也不會重入
    setState(() => _saving = true);
    try {
      await widget.onSave();
    } catch (e) {
      // 表單自己處理驗證錯誤；這裡接住其他例外（例如資料庫寫入失敗、磁碟已滿），
      // 頁面不關閉、欄位內容保留，使用者可以直接再按一次儲存。
      if (mounted) showSnack(context, '儲存失敗，輸入的內容已保留：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final saveIcon = _saving
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.check);

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      bottomNavigationBar: SafeArea(
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.bottom != null) ...[
                      widget.bottom!,
                      const SizedBox(height: 8),
                    ],
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _saving ? null : _handleSave,
                        icon: saveIcon,
                        label: Text(_saving ? '儲存中…' : '儲存'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: widget.children,
          ),
        ),
      ),
    );
  }
}

const numberKeyboard = TextInputType.numberWithOptions(decimal: true);

InputDecoration fieldDecoration(String label, {String? suffix}) =>
    InputDecoration(
      labelText: label,
      suffixText: suffix,
      border: const OutlineInputBorder(),
    );

/// 解析使用者輸入的數字；空白、非數字、NaN、Infinity 一律回傳 null。
double? parseNumber(String? v) {
  if (v == null) return null;
  final d = double.tryParse(v.trim());
  return (d != null && d.isFinite) ? d : null;
}

String? requiredNumber(String? v) {
  if (v == null || v.trim().isEmpty) return '必填';
  return parseNumber(v) == null ? '請輸入數字' : null;
}

String? positiveNumber(String? v) {
  final err = requiredNumber(v);
  if (err != null) return err;
  return parseNumber(v)! <= 0 ? '必須大於 0' : null;
}

String? nonNegativeNumber(String? v) {
  final err = requiredNumber(v);
  if (err != null) return err;
  return parseNumber(v)! < 0 ? '不可為負數' : null;
}

/// 選填的非負數（空白視為 0，但有填就必須是合法數字）。
String? optionalNonNegativeNumber(String? v) {
  if (v == null || v.trim().isEmpty) return null;
  return nonNegativeNumber(v);
}

/// 選填的非負整數（空白 = 不設定；30.5、-1、abc 都不接受）。
String? optionalNonNegativeInteger(String? v) {
  if (v == null || v.trim().isEmpty) return null;
  final n = int.tryParse(v.trim());
  if (n == null) return '請輸入整數';
  return n < 0 ? '不可為負數' : null;
}

/// 列表上方的篩選列：年份下拉 + 搜尋框。
class FilterBar extends StatelessWidget {
  const FilterBar({
    super.key,
    required this.years,
    required this.year,
    required this.onYearChanged,
    required this.onQueryChanged,
    this.hint = '搜尋',
  });

  /// 有資料的年份（由新到舊）
  final List<int> years;
  final int? year;
  final ValueChanged<int?> onYearChanged;
  final ValueChanged<String> onQueryChanged;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final value = years.contains(year) ? year : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          DropdownButton<int?>(
            value: value,
            underline: const SizedBox.shrink(),
            items: [
              const DropdownMenuItem<int?>(value: null, child: Text('全部年份')),
              for (final y in years)
                DropdownMenuItem<int?>(value: y, child: Text('$y 年')),
            ],
            onChanged: onYearChanged,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: hint,
                border: const OutlineInputBorder(),
              ),
              onChanged: onQueryChanged,
            ),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';

/// 目前沒有任何車輛時的提示。
class NoVehicleHint extends StatelessWidget {
  const NoVehicleHint({super.key});

  @override
  Widget build(BuildContext context) => const EmptyHint(
        icon: Icons.directions_car_outlined,
        text: '請先到「車輛」頁新增一台車',
      );
}

class EmptyHint extends StatelessWidget {
  const EmptyHint({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outline;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: color),
          const SizedBox(height: 12),
          Text(text, style: TextStyle(color: color)),
        ],
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
class FormScaffold extends StatelessWidget {
  const FormScaffold({
    super.key,
    required this.title,
    required this.children,
    required this.onSave,
    this.bottom,
  });

  final String title;
  final List<Widget> children;
  final VoidCallback onSave;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          TextButton.icon(
            onPressed: onSave,
            icon: const Icon(Icons.check),
            label: const Text('儲存'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      bottomNavigationBar: bottom,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: children,
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

String? requiredNumber(String? v) {
  if (v == null || v.trim().isEmpty) return '必填';
  if (double.tryParse(v.trim()) == null) return '請輸入數字';
  return null;
}

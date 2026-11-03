import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/repository.dart';
import '../domain/maintenance_calculator.dart';
import '../providers.dart';
import 'common.dart';
import 'format.dart';

/// 表單內的一列明細（持有自己的 controller）。
class _Row {
  _Row({this.id, String name = '', String qty = '1', String price = ''})
      : name = TextEditingController(text: name),
        qty = TextEditingController(text: qty),
        price = TextEditingController(text: price);

  final String? id;
  final TextEditingController name;
  final TextEditingController qty;
  final TextEditingController price;

  double get quantity => double.tryParse(qty.text.trim()) ?? 0;
  double get unitPrice => double.tryParse(price.text.trim()) ?? 0;

  ItemInput toInput() => ItemInput(
        id: id,
        name: name.text.trim(),
        quantity: quantity,
        unitPrice: unitPrice,
      );

  void dispose() {
    name.dispose();
    qty.dispose();
    price.dispose();
  }
}

class MaintenanceFormPage extends ConsumerStatefulWidget {
  const MaintenanceFormPage({super.key, required this.vehicle, this.existing});

  final Vehicle vehicle;
  final MaintenanceWithItems? existing;

  @override
  ConsumerState<MaintenanceFormPage> createState() =>
      _MaintenanceFormPageState();
}

class _MaintenanceFormPageState extends ConsumerState<MaintenanceFormPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _odo;
  late final TextEditingController _note;
  late DateTime _date;
  final List<_Row> _rows = [];

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _date = e == null
        ? DateTime.now()
        : DateTime.fromMillisecondsSinceEpoch(e.record.date);
    _odo = TextEditingController(text: e == null ? '' : trimNum(e.record.odometer));
    _note = TextEditingController(text: e?.record.note ?? '');
    if (e != null) {
      for (final i in e.items) {
        _rows.add(_Row(
          id: i.id,
          name: i.name,
          qty: trimNum(i.quantity),
          price: trimNum(i.unitPrice),
        ));
      }
    }
  }

  @override
  void dispose() {
    _odo.dispose();
    _note.dispose();
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  double get _total => computeItemsTotal(_rows.map((r) => r.toInput()));

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  void _addRow([String name = '']) {
    setState(() => _rows.add(_Row(name: name)));
  }

  void _removeRow(_Row row) {
    setState(() => _rows.remove(row));
    row.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    try {
      await ref.read(repoProvider).saveMaintenance(
            id: widget.existing?.record.id,
            vehicleId: widget.vehicle.id,
            date: _date,
            odometer: double.tryParse(_odo.text.trim()) ?? 0,
            items: _rows.map((r) => r.toInput()).toList(),
            note: _note.text,
          );
      if (mounted) Navigator.of(context).pop();
    } on GarageValidationException catch (e) {
      if (mounted) showSnack(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FormScaffold(
      title: widget.existing == null ? '新增保養' : '編輯保養',
      onSave: _save,
      bottom: SafeArea(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('總金額', style: theme.textTheme.titleMedium),
              Text('\$${fmtMoney(_total)}', style: theme.textTheme.headlineSmall),
            ],
          ),
        ),
      ),
      children: [
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                onTap: _pickDate,
                child: InputDecorator(
                  decoration: fieldDecoration('日期'),
                  child: Row(
                    children: [
                      Expanded(child: Text(fmtDate(_date))),
                      const Icon(Icons.calendar_today, size: 18),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _odo,
                keyboardType: numberKeyboard,
                decoration: fieldDecoration('目前里程', suffix: 'km'),
                validator: requiredNumber,
              ),
              const SizedBox(height: 20),
              Text('常用項目（點一下加入）', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final n in kQuickMaintenanceItems)
                    ActionChip(label: Text(n), onPressed: () => _addRow(n)),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Text('保養明細', style: theme.textTheme.titleSmall),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _addRow,
                    icon: const Icon(Icons.add),
                    label: const Text('自訂項目'),
                  ),
                ],
              ),
              if (_rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    '尚未加入項目',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.colorScheme.outline),
                  ),
                ),
              for (final row in _rows)
                _ItemEditor(
                  key: ObjectKey(row),
                  row: row,
                  onChanged: () => setState(() {}),
                  onRemove: () => _removeRow(row),
                ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _note,
                decoration: fieldDecoration('備註（選填）'),
                maxLines: 2,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ItemEditor extends StatelessWidget {
  const _ItemEditor({
    super.key,
    required this.row,
    required this.onChanged,
    required this.onRemove,
  });

  final _Row row;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: row.name,
                    decoration: fieldDecoration('項目名稱'),
                  ),
                ),
                IconButton(
                  tooltip: '移除',
                  icon: const Icon(Icons.close),
                  onPressed: onRemove,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox(
                  width: 84,
                  child: TextFormField(
                    controller: row.qty,
                    keyboardType: numberKeyboard,
                    decoration: fieldDecoration('數量'),
                    onChanged: (_) => onChanged(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: row.price,
                    keyboardType: numberKeyboard,
                    decoration: fieldDecoration('單價', suffix: '\$'),
                    onChanged: (_) => onChanged(),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 84,
                  child: Text(
                    '\$${fmtMoney(row.toInput().subtotal)}',
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

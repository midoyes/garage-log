import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/repository.dart';
import '../providers.dart';
import 'common.dart';
import 'format.dart';

class FuelFormPage extends ConsumerStatefulWidget {
  const FuelFormPage({
    super.key,
    required this.vehicle,
    this.log,
    this.lastOdometer,
  });

  final Vehicle vehicle;
  final FuelLog? log;

  /// 目前最新一筆里程（僅用於提示）。
  final double? lastOdometer;

  @override
  ConsumerState<FuelFormPage> createState() => _FuelFormPageState();
}

class _FuelFormPageState extends ConsumerState<FuelFormPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _odo;
  late final TextEditingController _liters;
  late final TextEditingController _amount;
  late final TextEditingController _price;
  late final TextEditingController _note;
  late DateTime _date;
  late bool _full;

  @override
  void initState() {
    super.initState();
    final l = widget.log;
    _date = l == null
        ? DateTime.now()
        : DateTime.fromMillisecondsSinceEpoch(l.date);
    _full = l?.isFullTank ?? true; // 預設跳停
    _odo = TextEditingController(text: l == null ? '' : trimNum(l.odometer));
    _liters = TextEditingController(text: l == null ? '' : trimNum(l.liters));
    _amount = TextEditingController(text: l == null ? '' : trimNum(l.amount));
    _price = TextEditingController(
      text: (l == null || l.unitPrice <= 0) ? '' : trimNum(l.unitPrice),
    );
    _note = TextEditingController(text: l?.note ?? '');
  }

  @override
  void dispose() {
    _odo.dispose();
    _liters.dispose();
    _amount.dispose();
    _price.dispose();
    _note.dispose();
    super.dispose();
  }

  double? _num(TextEditingController c) => double.tryParse(c.text.trim());

  // onChanged 只在使用者輸入時觸發，程式改文字不會觸發，所以不會互相無限連動。
  void _onLitersOrAmountChanged(String _) {
    final l = _num(_liters);
    final a = _num(_amount);
    if (l != null && l > 0 && a != null) {
      _price.text = trimNum(a / l);
    }
  }

  void _onPriceChanged(String _) {
    final l = _num(_liters);
    final p = _num(_price);
    if (l != null && l > 0 && p != null) {
      _amount.text = trimNum(l * p);
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    try {
      await ref.read(repoProvider).saveFuelLog(
            id: widget.log?.id,
            vehicleId: widget.vehicle.id,
            date: _date,
            odometer: _num(_odo)!,
            liters: _num(_liters)!,
            amount: _num(_amount)!,
            unitPrice: _num(_price),
            isFullTank: _full,
            note: _note.text,
          );
      if (mounted) Navigator.of(context).pop();
    } on GarageValidationException catch (e) {
      if (mounted) showSnack(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final last = widget.lastOdometer;
    return FormScaffold(
      title: widget.log == null ? '新增加油' : '編輯加油',
      onSave: _save,
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
                decoration: fieldDecoration('里程', suffix: 'km').copyWith(
                  helperText: (widget.log == null && last != null)
                      ? '上一筆：${fmtKm(last)} km'
                      : null,
                ),
                validator: requiredNumber,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _liters,
                keyboardType: numberKeyboard,
                decoration: fieldDecoration('公升數', suffix: 'L'),
                onChanged: _onLitersOrAmountChanged,
                validator: (v) {
                  final err = requiredNumber(v);
                  if (err != null) return err;
                  return double.parse(v!.trim()) <= 0 ? '必須大於 0' : null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _amount,
                keyboardType: numberKeyboard,
                decoration: fieldDecoration('金額', suffix: '\$'),
                onChanged: _onLitersOrAmountChanged,
                validator: requiredNumber,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _price,
                keyboardType: numberKeyboard,
                decoration: fieldDecoration('單價（自動計算，可修改）', suffix: '\$/L'),
                onChanged: _onPriceChanged,
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('跳停（加滿）'),
                subtitle: const Text('油耗以跳停為區間基準；沒加滿請關閉'),
                value: _full,
                onChanged: (v) => setState(() => _full = v),
              ),
              const SizedBox(height: 8),
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/repository.dart';
import '../domain/fuel_calculator.dart';
import '../providers.dart';
import 'common.dart';
import 'format.dart';

class FuelFormPage extends ConsumerStatefulWidget {
  const FuelFormPage({super.key, required this.vehicle, this.log});

  final Vehicle vehicle;
  final FuelLog? log;

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
  late String _fuelType;

  /// 計價模式：
  /// - false（預設）：輸入「實付金額」，單價 = 金額 ÷ 公升（唯讀）
  /// - true：輸入「單價」，金額 = 公升 × 單價（唯讀）
  /// 每次只會有一個欄位被自動計算，不會互相覆寫。
  bool _byPrice = false;

  @override
  void initState() {
    super.initState();
    final l = widget.log;
    _date = l == null
        ? DateTime.now()
        : DateTime.fromMillisecondsSinceEpoch(l.date);
    _full = l?.isFullTank ?? true; // 預設跳停
    _fuelType = l?.fuelType ?? widget.vehicle.defaultFuelType;
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

  /// 使用者輸入時才重算（程式改文字不會觸發 onChanged，所以不會無限連動）。
  void _recalc() {
    final l = parseNumber(_liters.text);
    if (l == null || l <= 0) return;
    if (_byPrice) {
      final p = parseNumber(_price.text);
      if (p != null) _amount.text = trimNum(l * p, digits: 2);
    } else {
      final a = parseNumber(_amount.text);
      if (a != null) _price.text = trimNum(a / l, digits: 2);
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
            odometer: parseNumber(_odo.text)!,
            liters: parseNumber(_liters.text)!,
            amount: parseNumber(_amount.text)!,
            unitPrice: parseNumber(_price.text),
            isFullTank: _full,
            fuelType: _fuelType,
            note: _note.text,
          );
      if (mounted) Navigator.of(context).pop();
    } on GarageValidationException catch (e) {
      if (mounted) showSnack(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final logs = ref.watch(fuelLogsProvider).valueOrNull ?? const <FuelLog>[];
    // 依「所選日期」顯示前後紀錄的里程範圍（補登舊紀錄時不會被最新里程誤導）
    final bounds = fuelOdometerBounds(
      existing: logs.map(fuelLogToEntry),
      date: _date,
      excludeId: widget.log?.id,
    );
    final String? odoHelper;
    if (bounds.prevMax != null && bounds.nextMin != null) {
      odoHelper = '這一天的里程需介於 ${fmtKm(bounds.prevMax!)} ～ '
          '${fmtKm(bounds.nextMin!)} km 之間（不含兩端）';
    } else if (bounds.prevMax != null) {
      odoHelper = '前一筆：${fmtKm(bounds.prevMax!)} km，這次必須比它大';
    } else if (bounds.nextMin != null) {
      odoHelper = '後一筆：${fmtKm(bounds.nextMin!)} km，這次必須比它小';
    } else {
      odoHelper = null;
    }
    final theme = Theme.of(context);

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
                autofocus: widget.log == null,
                decoration: fieldDecoration('里程', suffix: 'km')
                    .copyWith(helperText: odoHelper, helperMaxLines: 2),
                validator: nonNegativeNumber,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _liters,
                keyboardType: numberKeyboard,
                decoration: fieldDecoration('公升數', suffix: 'L'),
                onChanged: (_) => _recalc(),
                validator: positiveNumber,
              ),
              const SizedBox(height: 16),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('輸入實付金額')),
                  ButtonSegment(value: true, label: Text('輸入單價')),
                ],
                selected: {_byPrice},
                onSelectionChanged: (s) {
                  setState(() => _byPrice = s.first);
                  _recalc();
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _amount,
                readOnly: _byPrice,
                keyboardType: numberKeyboard,
                decoration: fieldDecoration(
                  _byPrice ? '金額（自動計算）' : '實付金額',
                  suffix: '\$',
                ),
                onChanged: (_) => _recalc(),
                validator: nonNegativeNumber,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _price,
                readOnly: !_byPrice,
                keyboardType: numberKeyboard,
                decoration: fieldDecoration(
                  _byPrice ? '單價' : '單價（自動計算）',
                  suffix: '\$/L',
                ),
                onChanged: (_) => _recalc(),
                validator: (v) =>
                    _byPrice ? positiveNumber(v) : optionalNonNegativeNumber(v),
              ),
              const SizedBox(height: 16),
              Text('油品', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final t in kFuelTypes)
                    ChoiceChip(
                      label: Text(t),
                      selected: _fuelType == t,
                      onSelected: (sel) => setState(() => _fuelType = sel ? t : ''),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('本次有加滿油箱（跳停）'),
                subtitle: const Text('沒加滿請關閉，這次的油量會累計到下一次加滿一起計算油耗'),
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

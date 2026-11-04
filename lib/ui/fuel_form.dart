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
      text: (l == null || l.unitPrice <= 0) ? '' : l.unitPrice.toStringAsFixed(2),
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
      // 單價固定顯示兩位小數（31.90 而不是 31.9）
      if (a != null) _price.text = (a / l).toStringAsFixed(2);
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null) setState(() => _date = picked); // 日期一變，下方的里程範圍提示跟著更新
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

  /// 這台車所有加油 + 保養的里程讀數（跨類型一起判定）。
  List<OdometerReading> _allReadings() {
    final logs = ref.read(fuelLogsProvider).valueOrNull ?? const <FuelLog>[];
    final maint =
        ref.read(maintenanceProvider).valueOrNull ?? const <MaintenanceWithItems>[];
    return [
      for (final l in logs)
        OdometerReading(
          id: l.id,
          date: DateTime.fromMillisecondsSinceEpoch(l.date),
          odometer: l.odometer,
          label: '加油',
        ),
      for (final m in maint)
        OdometerReading(
          id: m.record.id,
          date: DateTime.fromMillisecondsSinceEpoch(m.record.date),
          odometer: m.record.odometer,
          label: '保養',
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(fuelLogsProvider);
    ref.watch(maintenanceProvider);
    // 依「所選日期」顯示前後紀錄的里程範圍（補登舊紀錄時不會被最新里程誤導）
    final bounds = odometerBounds(
      readings: _allReadings(),
      date: _date,
      excludeId: widget.log?.id,
    );
    final odoHelper = odometerHelperText(bounds.prevMax, bounds.nextMin);
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
                validator: (v) {
                  final err = nonNegativeNumber(v);
                  if (err != null) return err;
                  return validateOdometerByDate(
                    readings: _allReadings(),
                    date: _date,
                    odometer: parseNumber(v)!,
                    initialOdometer: widget.vehicle.initialOdometer,
                    excludeId: widget.log?.id,
                  );
                },
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

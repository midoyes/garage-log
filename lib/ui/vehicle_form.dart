import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/repository.dart';
import '../providers.dart';
import 'common.dart';
import 'format.dart';

class VehicleFormPage extends ConsumerStatefulWidget {
  const VehicleFormPage({super.key, this.vehicle});

  final Vehicle? vehicle;

  @override
  ConsumerState<VehicleFormPage> createState() => _VehicleFormPageState();
}

class _VehicleFormPageState extends ConsumerState<VehicleFormPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _plate;
  late final TextEditingController _odo;
  late int _type;
  late String _fuelType;

  @override
  void initState() {
    super.initState();
    final v = widget.vehicle;
    _type = v?.type ?? 0;
    _fuelType = v?.defaultFuelType ?? '';
    _name = TextEditingController(text: v?.name ?? '');
    _plate = TextEditingController(text: v?.plate ?? '');
    _odo = TextEditingController(text: v == null ? '0' : trimNum(v.initialOdometer));
  }

  @override
  void dispose() {
    _name.dispose();
    _plate.dispose();
    _odo.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final repo = ref.read(repoProvider);
    final odo = parseNumber(_odo.text)!;
    final v = widget.vehicle;
    try {
      if (v == null) {
        final id = await repo.addVehicle(
          type: _type,
          name: _name.text,
          plate: _plate.text,
          initialOdometer: odo,
          defaultFuelType: _fuelType,
        );
        // 新增的車直接切換過去（也會記住，下次開啟 App 仍是這台）。
        await ref.read(selectedVehicleIdProvider.notifier).select(id);
      } else {
        await repo.updateVehicle(
          v.id,
          type: _type,
          name: _name.text,
          plate: _plate.text,
          initialOdometer: odo,
          defaultFuelType: _fuelType,
        );
      }
      if (mounted) Navigator.of(context).pop();
    } on GarageValidationException catch (e) {
      if (mounted) showSnack(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FormScaffold(
      title: widget.vehicle == null ? '新增車輛' : '編輯車輛',
      onSave: _save,
      children: [
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(
                      value: 0, icon: Icon(Icons.directions_car), label: Text('汽車')),
                  ButtonSegment(
                      value: 1, icon: Icon(Icons.two_wheeler), label: Text('機車')),
                ],
                selected: {_type},
                onSelectionChanged: (s) => setState(() => _type = s.first),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _name,
                decoration: fieldDecoration('車輛名稱'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? '請輸入名稱' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _plate,
                textCapitalization: TextCapitalization.characters,
                decoration: fieldDecoration('車牌（選填）'),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _odo,
                keyboardType: numberKeyboard,
                decoration: fieldDecoration('初始里程', suffix: 'km'),
                validator: nonNegativeNumber,
              ),
              const SizedBox(height: 20),
              Text('預設油品（加油時自動帶入）',
                  style: Theme.of(context).textTheme.titleSmall),
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
            ],
          ),
        ),
      ],
    );
  }
}

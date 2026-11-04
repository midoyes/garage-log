import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/repository.dart';
import '../domain/maintenance_calculator.dart';
import '../domain/reminders.dart';
import '../providers.dart';
import 'common.dart';
import 'format.dart';
import 'navigation.dart';
import 'reminder_widgets.dart';

/// 保養週期與零件歷史：
/// - 週期由車主自訂（里程、天數可擇一或兩者，任一先到就提醒）
/// - 零件歷史由保養明細自動整理，不用另外輸入
class PlansPage extends ConsumerWidget {
  const PlansPage({super.key});

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    Vehicle vehicle, {
    PlanSpec? plan,
    String? presetName,
  }) async {
    final result = await showDialog<PlanSpec>(
      context: context,
      builder: (_) => _PlanDialog(initial: plan, presetName: presetName),
    );
    if (result == null) return;
    try {
      await ref.read(repoProvider).savePlan(
            id: plan?.id,
            vehicleId: vehicle.id,
            name: result.name,
            intervalKm: result.intervalKm,
            intervalDays: result.intervalDays,
          );
    } on GarageValidationException catch (e) {
      if (context.mounted) showSnack(context, e.message);
    } catch (e) {
      if (context.mounted) showSnack(context, '儲存失敗：$e');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vehicle = ref.watch(currentVehicleProvider);
    final reminders = ref.watch(remindersProvider);
    final maint =
        ref.watch(maintenanceProvider).valueOrNull ?? const <MaintenanceWithItems>[];
    final parts = summarizeParts(partRecordsFrom(maint));
    final theme = Theme.of(context);

    final planned = {for (final r in reminders) normalizeItemName(r.plan.name)};
    final presets = vehicle == null
        ? const <String>[]
        : quickItemsFor(vehicle.type)
            .where((n) => !planned.contains(normalizeItemName(n)))
            .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('保養週期與零件歷史')),
      floatingActionButton: vehicle == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _edit(context, ref, vehicle),
              icon: const Icon(Icons.add),
              label: const Text('新增週期'),
            ),
      body: vehicle == null
          ? const NoVehicleHint()
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 800),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                  children: [
                    Text('${vehicle.name} 的保養週期', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      '週期由你自訂，不同車款與油品的原廠建議不一樣。'
                      '里程以你最後回報的里程計算；日期與里程同時設定時，任一條件先到就提醒。',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    if (reminders.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: EmptyHint(
                          icon: Icons.event_repeat,
                          text: '還沒有設定週期，從下面的常用項目開始',
                        ),
                      ),
                    for (final r in reminders)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          child: ReminderTile(
                            result: r,
                            onTap: () => openPartHistory(context, r.plan.name),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: '編輯週期',
                                  icon: const Icon(Icons.edit_outlined),
                                  onPressed: () =>
                                      _edit(context, ref, vehicle, plan: r.plan),
                                ),
                                IconButton(
                                  tooltip: '刪除週期',
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () async {
                                    final ok = await confirmDialog(
                                      context,
                                      title: '刪除「${r.plan.name}」的週期？',
                                      message: '只會刪除週期設定，過去的保養紀錄不受影響。',
                                    );
                                    if (ok) {
                                      await ref.read(repoProvider).deletePlan(r.plan.id);
                                    }
                                  },
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (presets.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Text('常用項目（點一下設定週期）', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final n in presets)
                            ActionChip(
                              label: Text(n),
                              onPressed: () =>
                                  _edit(context, ref, vehicle, presetName: n),
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 24),
                    Text('保養項目歷史', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      '依保養明細的項目名稱整理。名稱相同的項目一律視為「完成一次保養」，'
                      '包含檢查、補胎、工資等；若某次只是檢查，請用不同的名稱記錄（例如「輪胎檢查」）。',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    if (parts.isEmpty)
                      Text('保養紀錄裡出現過的項目會自動列在這裡。',
                          style: theme.textTheme.bodySmall),
                    for (final p in parts)
                      Card(
                        child: ListTile(
                          title: Text(p.name),
                          subtitle: Text(
                            '共 ${p.count} 次 · 最近 ${fmtDate(p.last.date)}，'
                            '${fmtKm(p.last.odometer)} km',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => openPartHistory(context, p.name),
                        ),
                      ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// 新增 / 編輯週期的對話框；回傳 [PlanSpec]（id 在新增時為空字串，由呼叫端忽略）。
class _PlanDialog extends StatefulWidget {
  const _PlanDialog({this.initial, this.presetName});

  final PlanSpec? initial;
  final String? presetName;

  @override
  State<_PlanDialog> createState() => _PlanDialogState();
}

class _PlanDialogState extends State<_PlanDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _km;
  late final TextEditingController _days;

  @override
  void initState() {
    super.initState();
    final p = widget.initial;
    _name = TextEditingController(text: p?.name ?? widget.presetName ?? '');
    _km = TextEditingController(
        text: (p == null || p.intervalKm <= 0) ? '' : trimNum(p.intervalKm));
    _days = TextEditingController(
        text: (p == null || p.intervalDays <= 0) ? '' : '${p.intervalDays}');
  }

  @override
  void dispose() {
    _name.dispose();
    _km.dispose();
    _days.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(
      PlanSpec(
        id: widget.initial?.id ?? '',
        name: _name.text.trim(),
        intervalKm: parseNumber(_km.text) ?? 0,
        // 天數只接受整數（驗證器已擋掉 30.5 這類輸入）；空白 = 不設定
        intervalDays: int.tryParse(_days.text.trim()) ?? 0,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? '新增保養週期' : '編輯保養週期'),
      content: Form(
        key: _formKey,
        // 可捲動：手機開著鍵盤時內容不會擠壓或溢出
        child: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _name,
                  decoration: fieldDecoration('項目名稱（要和保養明細的名稱一致）'),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? '請輸入項目名稱' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _km,
                  keyboardType: numberKeyboard,
                  decoration: fieldDecoration('每隔多少公里（選填）', suffix: 'km'),
                  validator: optionalNonNegativeNumber,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _days,
                  keyboardType: TextInputType.number,
                  decoration: fieldDecoration('每隔多少天（選填，整數）', suffix: '天'),
                  validator: optionalNonNegativeInteger,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('儲存')),
      ],
    );
  }
}

/// 單一零件的更換歷史：上次更換、下次預計、每次間隔。
class PartHistoryPage extends ConsumerWidget {
  const PartHistoryPage({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final maint =
        ref.watch(maintenanceProvider).valueOrNull ?? const <MaintenanceWithItems>[];
    final reminders = ref.watch(remindersProvider);
    final history = partHistory(partRecordsFrom(maint), name);
    final theme = Theme.of(context);

    ReminderResult? reminder;
    for (final r in reminders) {
      if (normalizeItemName(r.plan.name) == normalizeItemName(name)) reminder = r;
    }

    return Scaffold(
      appBar: AppBar(title: Text(name)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (history.isEmpty)
                const EmptyHint(icon: Icons.history, text: '還沒有這個零件的更換紀錄')
              else ...[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Expanded(
                          child: _Fact(
                            label: '上次更換',
                            value: '${fmtKm(history.first.odometer)} km',
                            sub: fmtDate(history.first.date),
                          ),
                        ),
                        Expanded(
                          child: _Fact(
                            label: '下次預計',
                            value: reminder == null || reminderDueText(reminder).isEmpty
                                ? '未設定'
                                : reminderDueText(reminder).replaceFirst('預計 ', ''),
                            sub: reminder == null
                                ? '到「週期」設定'
                                : reminderRemainingText(reminder),
                          ),
                        ),
                        Expanded(
                          child: _Fact(
                            label: '更換次數',
                            value: '${history.length}',
                            sub: '',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                for (var i = 0; i < history.length; i++)
                  Card(
                    child: ListTile(
                      title: Text('${fmtDate(history[i].date)} · ${fmtKm(history[i].odometer)} km'),
                      subtitle: Text(_intervalText(history, i)),
                      trailing: Text(
                        '\$${fmtMoney(history[i].subtotal)}',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 「×4 @ 350 · 距上次 5,000 km / 120 天」。
  String _intervalText(List<PartRecord> history, int i) {
    final h = history[i];
    final parts = <String>['×${trimNum(h.quantity)} @ ${fmtMoney(h.unitPrice)}'];
    if (i + 1 < history.length) {
      final prev = history[i + 1];
      final km = h.odometer - prev.odometer;
      final days = h.date.difference(prev.date).inDays;
      parts.add('距上次 ${fmtKm(km)} km / $days 天');
    } else {
      parts.add('最早的紀錄');
    }
    return parts.join(' · ');
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value, required this.sub});

  final String label;
  final String value;
  final String sub;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Text(label, style: theme.textTheme.bodySmall),
        const SizedBox(height: 4),
        Text(value, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
        if (sub.isNotEmpty)
          Text(sub, style: theme.textTheme.bodySmall, textAlign: TextAlign.center),
      ],
    );
  }
}

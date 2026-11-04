import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/repository.dart';
import '../domain/reminders.dart';
import '../providers.dart';
import 'common.dart';
import 'format.dart';
import 'navigation.dart';
import 'reminder_widgets.dart';

class MaintenancePage extends ConsumerStatefulWidget {
  const MaintenancePage({super.key});

  @override
  ConsumerState<MaintenancePage> createState() => _MaintenancePageState();
}

class _MaintenancePageState extends ConsumerState<MaintenancePage> {
  int? _year;
  String _query = '';

  bool _match(MaintenanceWithItems m, int? year) {
    final date = DateTime.fromMillisecondsSinceEpoch(m.record.date);
    if (year != null && date.year != year) return false;
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return m.record.note.toLowerCase().contains(q) ||
        trimNum(m.record.odometer).contains(q) ||
        fmtDate(date).contains(q) ||
        m.items.any((i) => i.name.toLowerCase().contains(q));
  }

  @override
  Widget build(BuildContext context) {
    // 換車時清掉年份與關鍵字，避免「篩選器顯示全部、列表卻是空的」
    ref.listen<String?>(currentVehicleProvider.select((v) => v?.id), (prev, next) {
      if (prev != next) {
        setState(() {
          _year = null;
          _query = '';
        });
      }
    });

    final vehicle = ref.watch(currentVehicleProvider);
    if (vehicle == null) return const NoVehicleHint();

    return ref.watch(maintenanceProvider).when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('讀取失敗：$e')),
          data: (records) {
            final total =
                records.fold<double>(0, (s, r) => s + r.record.totalAmount);
            final years = {
              for (final r in records)
                DateTime.fromMillisecondsSinceEpoch(r.record.date).year,
            }.toList()
              ..sort((a, b) => b.compareTo(a));
            final year = years.contains(_year) ? _year : null;
            final shown = records.where((m) => _match(m, year)).toList();

            return Column(
              children: [
                if (records.isNotEmpty)
                  FilterBar(
                    key: ValueKey(vehicle.id),
                    years: years,
                    year: year,
                    hint: '搜尋零件、備註、里程',
                    onYearChanged: (y) => setState(() => _year = y),
                    onQueryChanged: (q) => setState(() => _query = q),
                  ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                    itemCount: shown.length + 2,
                    itemBuilder: (context, i) {
                      if (i == 0) return const _ReminderCard();
                      if (i == 1) {
                        if (records.isEmpty) {
                          return const Padding(
                            padding: EdgeInsets.only(top: 48),
                            child: EmptyHint(
                              icon: Icons.build_outlined,
                              text: '還沒有保養紀錄，點右下角新增',
                            ),
                          );
                        }
                        return Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('保養累計花費',
                                    style: Theme.of(context).textTheme.titleMedium),
                                Text('\$${fmtMoney(total)}',
                                    style: Theme.of(context).textTheme.titleLarge),
                              ],
                            ),
                          ),
                        );
                      }
                      return _MaintenanceCard(entry: shown[i - 2], vehicle: vehicle);
                    },
                  ),
                ),
              ],
            );
          },
        );
  }
}

/// 保養頁頂端的提醒摘要：最急的前 3 項 + 前往「週期與零件歷史」。
class _ReminderCard extends ConsumerWidget {
  const _ReminderCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reminders = ref.watch(remindersProvider);
    final actionable = reminders
        .where((r) =>
            r.status == ReminderStatus.overdue ||
            r.status == ReminderStatus.soon ||
            r.status == ReminderStatus.ok)
        .take(3)
        .toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('保養提醒', style: Theme.of(context).textTheme.titleMedium),
                ),
                TextButton(
                  onPressed: () => openPlans(context),
                  child: const Text('週期與零件歷史'),
                ),
              ],
            ),
            if (reminders.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8, right: 8),
                child: Text(
                  '還沒有設定保養週期。設定後，這裡會顯示機油、輪胎等零件還剩多少公里或天數。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              )
            else if (actionable.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8, right: 8),
                child: Text(
                  '已設定的項目還沒有可計算的更換紀錄。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              )
            else
              for (final r in actionable)
                ReminderTile(
                  result: r,
                  onTap: () => openPartHistory(context, r.plan.name),
                ),
          ],
        ),
      ),
    );
  }
}

class _MaintenanceCard extends ConsumerWidget {
  const _MaintenanceCard({required this.entry, required this.vehicle});

  final MaintenanceWithItems entry;
  final Vehicle vehicle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final r = entry.record;
    final date = DateTime.fromMillisecondsSinceEpoch(r.date);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openMaintenanceForm(context, vehicle, existing: entry),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${fmtDate(date)}  ·  ${fmtKm(r.odometer)} km',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  Text(
                    '\$${fmtMoney(r.totalAmount)}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  IconButton(
                    tooltip: '刪除',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      final ok = await confirmDialog(
                        context,
                        title: '刪除這筆保養紀錄？',
                        message: '${fmtDate(date)}・\$${fmtMoney(r.totalAmount)}',
                      );
                      if (ok) {
                        await ref.read(repoProvider).deleteMaintenance(r.id);
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 4),
              for (final i in entry.items)
                Padding(
                  padding: const EdgeInsets.only(right: 12, top: 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          onTap: () => openPartHistory(context, i.name),
                          child: Text(
                            '${i.name}  ×${trimNum(i.quantity)} @ ${fmtMoney(i.unitPrice)}',
                          ),
                        ),
                      ),
                      Text('\$${fmtMoney(i.quantity * i.unitPrice)}'),
                    ],
                  ),
                ),
              if (r.note.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(r.note, style: theme.textTheme.bodySmall),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

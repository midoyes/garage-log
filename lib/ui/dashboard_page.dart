import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/repository.dart';
import '../domain/fuel_calculator.dart';
import '../domain/reminders.dart';
import '../domain/stats_summary.dart';
import '../providers.dart';
import 'format.dart';
import 'navigation.dart';
import 'reminder_widgets.dart';

/// 總覽：車輛 → 目前里程 → 油耗 / 花費 → 保養提醒 → 快速新增 → 最近紀錄。
class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vehicle = ref.watch(currentVehicleProvider);
    if (vehicle == null) return const _NoVehicle();

    final logs = ref.watch(fuelLogsProvider).valueOrNull ?? const <FuelLog>[];
    final maint =
        ref.watch(maintenanceProvider).valueOrNull ?? const <MaintenanceWithItems>[];
    final odo = ref.watch(currentOdometerProvider) ?? vehicle.initialOdometer;
    final reminders = ref.watch(remindersProvider);

    // 最近平均油耗：最近 5 個跳停區間的加權平均
    final entries = logs.map(fuelLogToEntry).toList();
    final stats = computeFuelStats(entries);
    final points = buildStatPoints(entries, stats);
    final lastFive = points.length > 5 ? points.sublist(points.length - 5) : points;
    final recentAvg = overallKmPerL(lastFive.map((p) => p.stat));

    // 本月花費（加油 + 保養）
    final now = ref.watch(todayProvider);
    bool thisMonth(DateTime d) => d.year == now.year && d.month == now.month;
    var monthFuel = 0.0;
    for (final l in logs) {
      if (thisMonth(DateTime.fromMillisecondsSinceEpoch(l.date))) monthFuel += l.amount;
    }
    var monthMaint = 0.0;
    for (final m in maint) {
      if (thisMonth(DateTime.fromMillisecondsSinceEpoch(m.record.date))) {
        monthMaint += m.record.totalAmount;
      }
    }

    final header = _VehicleHeader(
      vehicle: vehicle,
      odometer: odo,
      recentAvg: recentAvg,
      monthTotal: monthFuel + monthMaint,
      monthFuel: monthFuel,
      monthMaint: monthMaint,
    );
    final quick = _QuickActions(vehicle: vehicle);
    const priceCard = _FuelPriceCard();
    final reminderCard = _ReminderSection(reminders: reminders);
    final recent = _RecentSection(logs: logs, maint: maint);

    return LayoutBuilder(
      builder: (context, c) {
        if (c.maxWidth >= 800) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(children: [header, const SizedBox(height: 12), priceCard, const SizedBox(height: 12), quick]),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    children: [reminderCard, const SizedBox(height: 12), recent],
                  ),
                ),
              ],
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            header,
            const SizedBox(height: 12),
            priceCard,
            const SizedBox(height: 12),
            quick,
            const SizedBox(height: 12),
            reminderCard,
            const SizedBox(height: 12),
            recent,
          ],
        );
      },
    );
  }
}

class _NoVehicle extends StatelessWidget {
  const _NoVehicle();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.directions_car_outlined, size: 72, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text('歡迎使用愛車記錄', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text('先新增一台車，就能開始記錄加油與保養。',
                style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => openVehicleForm(context),
              icon: const Icon(Icons.add),
              label: const Text('新增第一台車'),
            ),
          ],
        ),
      ),
    );
  }
}

class _VehicleHeader extends StatelessWidget {
  const _VehicleHeader({
    required this.vehicle,
    required this.odometer,
    required this.recentAvg,
    required this.monthTotal,
    required this.monthFuel,
    required this.monthMaint,
  });

  final Vehicle vehicle;
  final double odometer;
  final double? recentAvg;
  final double monthTotal;
  final double monthFuel;
  final double monthMaint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(vehicle.type == 1 ? Icons.two_wheeler : Icons.directions_car),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(vehicle.name, style: theme.textTheme.titleLarge),
                ),
                if (vehicle.plate.isNotEmpty)
                  Chip(
                    label: Text(vehicle.plate),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text('目前里程', style: theme.textTheme.bodySmall),
            Text('${fmtKm(odometer)} km', style: theme.textTheme.displaySmall),
            Text('以你最後輸入的里程為準', style: theme.textTheme.bodySmall),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _Metric(
                    label: '最近平均油耗',
                    value: recentAvg == null ? '—' : recentAvg!.toStringAsFixed(1),
                    unit: 'km/L',
                    note: '最近 5 次跳停',
                  ),
                ),
                Expanded(
                  child: _Metric(
                    label: '本月花費',
                    value: '\$${fmtMoney(monthTotal)}',
                    unit: '',
                    note: '加油＋保養',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    required this.unit,
    required this.note,
  });

  final String label;
  final String value;
  final String unit;
  final String note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.bodySmall),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(child: Text(value, style: theme.textTheme.headlineMedium)),
            if (unit.isNotEmpty) ...[
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(unit, style: theme.textTheme.bodySmall),
              ),
            ],
          ],
        ),
        Text(note, style: theme.textTheme.bodySmall),
      ],
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.vehicle});

  final Vehicle vehicle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: () => openFuelForm(context, vehicle),
            icon: const Icon(Icons.local_gas_station),
            label: const Text('記錄加油'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton.tonalIcon(
            onPressed: () => openMaintenanceForm(context, vehicle),
            icon: const Icon(Icons.build),
            label: const Text('記錄保養'),
          ),
        ),
      ],
    );
  }
}

class _ReminderSection extends StatelessWidget {
  const _ReminderSection({required this.reminders});

  final List<ReminderResult> reminders;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                Expanded(child: Text('近期保養提醒', style: theme.textTheme.titleMedium)),
                TextButton(
                  onPressed: () => openPlans(context),
                  child: Text(reminders.isEmpty ? '設定週期' : '查看全部'),
                ),
              ],
            ),
            if (actionable.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8, right: 8),
                child: Text(
                  reminders.isEmpty
                      ? '設定機油、輪胎等零件的保養週期，這裡就會告訴你還剩多少公里或天數。'
                      : '已設定的項目還沒有可計算的更換紀錄。',
                  style: theme.textTheme.bodySmall,
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

class _RecentItem {
  const _RecentItem({
    required this.date,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.amount,
  });

  final DateTime date;
  final IconData icon;
  final String title;
  final String subtitle;
  final double amount;
}

class _RecentSection extends StatelessWidget {
  const _RecentSection({required this.logs, required this.maint});

  final List<FuelLog> logs;
  final List<MaintenanceWithItems> maint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = <_RecentItem>[
      for (final l in logs)
        _RecentItem(
          date: DateTime.fromMillisecondsSinceEpoch(l.date),
          icon: Icons.local_gas_station,
          title: '加油 · ${trimNum(l.liters)} L',
          subtitle: '${fmtKm(l.odometer)} km',
          amount: l.amount,
        ),
      for (final m in maint)
        _RecentItem(
          date: DateTime.fromMillisecondsSinceEpoch(m.record.date),
          icon: Icons.build,
          title: m.items.isEmpty
              ? '保養'
              : m.items.map((i) => i.name).take(3).join('、') +
                  (m.items.length > 3 ? '…' : ''),
          subtitle: '${fmtKm(m.record.odometer)} km',
          amount: m.record.totalAmount,
        ),
    ]..sort((a, b) => b.date.compareTo(a.date));
    final shown = items.take(5).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('最近紀錄', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            if (shown.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('還沒有紀錄。', style: theme.textTheme.bodySmall),
              ),
            for (final i in shown)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(i.icon),
                title: Text(i.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${fmtShortDate(i.date)} · ${i.subtitle}'),
                trailing: Text('\$${fmtMoney(i.amount)}',
                    style: theme.textTheme.titleSmall),
              ),
          ],
        ),
      ),
    );
  }
}

/// 今日油價（中油公開牌價）。關閉或取不到資料時安靜降級，不影響其他功能。
class _FuelPriceCard extends ConsumerWidget {
  const _FuelPriceCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(fuelPriceEnabledProvider)) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final async = ref.watch(fuelPriceProvider);
    final colors = [
      Colors.red.shade400,
      Colors.orange.shade600,
      Colors.green.shade600,
      Colors.blueGrey.shade500,
    ];

    Widget body;
    if (async.isLoading) {
      body = const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    } else {
      final snap = async.valueOrNull;
      if (snap == null) {
        body = Row(
          children: [
            Expanded(
              child: Text('目前取不到油價（可能沒有網路）',
                  style: TextStyle(color: theme.colorScheme.outline)),
            ),
            TextButton(
              onPressed: () => ref.invalidate(fuelPriceProvider),
              child: const Text('重試'),
            ),
          ],
        );
      } else {
        final info = StringBuffer('來源：台灣中油');
        if (snap.effective != null) info.write('　生效：${snap.effective}');
        if (snap.fromCache) {
          final t = snap.fetchedAt;
          info.write('　（離線，上次更新 ${t.month}/${t.day}）');
        }
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                for (var i = 0; i < snap.prices.length; i++)
                  Expanded(
                    child: Column(
                      children: [
                        Text(snap.prices[i].name,
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall),
                        const SizedBox(height: 4),
                        Text(snap.prices[i].price.toStringAsFixed(1),
                            style: theme.textTheme.titleLarge?.copyWith(
                                color: colors[i % colors.length],
                                fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(info.toString(), style: theme.textTheme.bodySmall),
          ],
        );
      }
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.local_gas_station_outlined, size: 20),
                const SizedBox(width: 6),
                Text('今日油價', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            body,
          ],
        ),
      ),
    );
  }
}

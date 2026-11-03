import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/repository.dart';
import '../domain/fuel_calculator.dart';
import '../providers.dart';
import 'common.dart';
import 'format.dart';
import 'fuel_form.dart';

class FuelPage extends ConsumerWidget {
  const FuelPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vehicle = ref.watch(currentVehicleProvider);
    if (vehicle == null) return const NoVehicleHint();

    return ref.watch(fuelLogsProvider).when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('讀取失敗：$e')),
          data: (logs) {
            if (logs.isEmpty) {
              return const EmptyHint(
                icon: Icons.local_gas_station_outlined,
                text: '還沒有加油紀錄，點右下角新增',
              );
            }
            final entries = logs.map(fuelLogToEntry).toList();
            final stats = computeFuelStats(entries);
            final avg = overallKmPerL(stats.values);
            final totalFuelCost = logs.fold<double>(0, (s, l) => s + l.amount);
            final shown = logs.reversed.toList(); // 新的在上

            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                _SummaryCard(
                  avgKmPerL: avg,
                  totalCost: totalFuelCost,
                  count: logs.length,
                ),
                const SizedBox(height: 8),
                for (final l in shown)
                  _FuelCard(
                    log: l,
                    stat: stats[l.id],
                    vehicle: vehicle,
                    lastOdometer: logs.last.odometer,
                  ),
              ],
            );
          },
        );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.avgKmPerL,
    required this.totalCost,
    required this.count,
  });

  final double? avgKmPerL;
  final double totalCost;
  final int count;

  @override
  Widget build(BuildContext context) {
    Widget cell(String label, String value) => Expanded(
          child: Column(
            children: [
              Text(value, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(label, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          children: [
            cell('平均油耗 km/L', avgKmPerL == null ? '—' : avgKmPerL!.toStringAsFixed(2)),
            cell('加油總花費', '\$${fmtMoney(totalCost)}'),
            cell('加油次數', '$count'),
          ],
        ),
      ),
    );
  }
}

class _FuelCard extends ConsumerWidget {
  const _FuelCard({
    required this.log,
    required this.stat,
    required this.vehicle,
    required this.lastOdometer,
  });

  final FuelLog log;
  final FuelStat? stat;
  final Vehicle vehicle;
  final double lastOdometer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final date = DateTime.fromMillisecondsSinceEpoch(log.date);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => FuelFormPage(
              vehicle: vehicle,
              log: log,
              lastOdometer: lastOdometer,
            ),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(fmtDate(date), style: theme.textTheme.titleMedium),
                        const SizedBox(width: 8),
                        if (!log.isFullTank)
                          const Chip(
                            label: Text('未加滿'),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${fmtKm(log.odometer)} km · ${trimNum(log.liters)} L · '
                      '\$${fmtMoney(log.amount)}'
                      '${log.unitPrice > 0 ? '（\$${log.unitPrice.toStringAsFixed(2)}/L）' : ''}',
                    ),
                    if (stat != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        '${stat!.kmPerL.toStringAsFixed(2)} km/L · '
                        '\$${stat!.costPerKm.toStringAsFixed(2)}/km · '
                        '區間 ${fmtKm(stat!.distanceKm)} km',
                        style: TextStyle(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    if (log.note.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(log.note, style: theme.textTheme.bodySmall),
                    ],
                  ],
                ),
              ),
              IconButton(
                tooltip: '刪除',
                icon: const Icon(Icons.delete_outline),
                onPressed: () async {
                  final ok = await confirmDialog(
                    context,
                    title: '刪除這筆加油紀錄？',
                    message: '${fmtDate(date)}・${fmtKm(log.odometer)} km',
                  );
                  if (ok) await ref.read(repoProvider).deleteFuelLog(log.id);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

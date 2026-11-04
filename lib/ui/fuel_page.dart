import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/repository.dart';
import '../domain/fuel_calculator.dart';
import '../providers.dart';
import 'common.dart';
import 'format.dart';
import 'navigation.dart';

class FuelPage extends ConsumerStatefulWidget {
  const FuelPage({super.key});

  @override
  ConsumerState<FuelPage> createState() => _FuelPageState();
}

class _FuelPageState extends ConsumerState<FuelPage> {
  int? _year;
  String _query = '';

  bool _match(FuelLog l, int? year) {
    final date = DateTime.fromMillisecondsSinceEpoch(l.date);
    if (year != null && date.year != year) return false;
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return l.note.toLowerCase().contains(q) ||
        l.fuelType.toLowerCase().contains(q) ||
        trimNum(l.odometer).contains(q) ||
        fmtDate(date).contains(q);
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
            final stats = computeFuelStats(logs.map(fuelLogToEntry));
            final avg = overallKmPerL(stats.values);
            final totalFuelCost = logs.fold<double>(0, (s, l) => s + l.amount);
            final years = {
              for (final l in logs) DateTime.fromMillisecondsSinceEpoch(l.date).year,
            }.toList()
              ..sort((a, b) => b.compareTo(a));
            // 選到的年份已不存在（例如刪光了該年紀錄）時，視同「全部年份」
            final year = years.contains(_year) ? _year : null;
            final shown =
                logs.reversed.where((l) => _match(l, year)).toList(); // 新的在上

            return Column(
              children: [
                FilterBar(
                  key: ValueKey(vehicle.id),
                  years: years,
                  year: year,
                  hint: '搜尋備註、里程、油品',
                  onYearChanged: (y) => setState(() => _year = y),
                  onQueryChanged: (q) => setState(() => _query = q),
                ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                    itemCount: shown.length + 1,
                    itemBuilder: (context, i) {
                      if (i == 0) {
                        return _SummaryCard(
                          avgKmPerL: avg,
                          totalCost: totalFuelCost,
                          count: logs.length,
                        );
                      }
                      final l = shown[i - 1];
                      return _FuelCard(log: l, stat: stats[l.id], vehicle: vehicle);
                    },
                  ),
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

/// 加油卡片：第一眼看到「日期、公升、金額」三個數字；
/// 區間油耗用主色獨立一行，細節（里程、單價、備註）放次要位置。
class _FuelCard extends ConsumerWidget {
  const _FuelCard({required this.log, required this.stat, required this.vehicle});

  final FuelLog log;
  final FuelStat? stat;
  final Vehicle vehicle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final date = DateTime.fromMillisecondsSinceEpoch(log.date);
    final tags = [
      if (log.fuelType.isNotEmpty) log.fuelType,
      log.isFullTank ? '加滿' : '未加滿',
    ].join(' · ');

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openFuelForm(context, vehicle, log: log),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(fmtDate(date), style: theme.textTheme.titleSmall),
                    Text(tags, style: theme.textTheme.bodySmall),
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${trimNum(log.liters)} L',
                                  style: theme.textTheme.headlineSmall),
                              Text('${fmtKm(log.odometer)} km',
                                  style: theme.textTheme.bodyMedium),
                            ],
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('\$${fmtMoney(log.amount)}',
                                  style: theme.textTheme.headlineSmall),
                              Text(
                                log.unitPrice > 0
                                    ? '\$${log.unitPrice.toStringAsFixed(2)} / L'
                                    : '',
                                style: theme.textTheme.bodyMedium,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (stat != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        '本次區間 ${stat!.kmPerL.toStringAsFixed(2)} km/L · '
                        '\$${stat!.costPerKm.toStringAsFixed(2)}/km · '
                        '${fmtKm(stat!.distanceKm)} km',
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

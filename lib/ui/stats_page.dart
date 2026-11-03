import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../data/repository.dart';
import '../domain/cost_summary.dart';
import '../domain/fuel_calculator.dart';
import '../providers.dart';
import 'common.dart';
import 'format.dart';

class StatsPage extends ConsumerWidget {
  const StatsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vehicle = ref.watch(currentVehicleProvider);
    if (vehicle == null) return const NoVehicleHint();

    final logs = ref.watch(fuelLogsProvider).valueOrNull ?? const [];
    final maint = ref.watch(maintenanceProvider).valueOrNull ?? const [];

    final entries = logs.map(fuelLogToEntry).toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    final stats = computeFuelStats(entries);
    final points = [
      for (final e in entries)
        if (stats[e.id] != null) (date: e.date, kmPerL: stats[e.id]!.kmPerL),
    ];

    final months = computeMonthlyCosts(
      fuel: [
        for (final l in logs)
          DatedAmount(DateTime.fromMillisecondsSinceEpoch(l.date), l.amount),
      ],
      maintenance: [
        for (final m in maint)
          DatedAmount(
              DateTime.fromMillisecondsSinceEpoch(m.record.date), m.record.totalAmount),
      ],
    );
    final recent = months.length > 12 ? months.sublist(months.length - 12) : months;

    final fuelCard = _ChartCard(
      title: '歷次油耗 (km/L)',
      child: _FuelLineChart(points: points),
    );
    final costCard = _ChartCard(
      title: '每月花費（加油 vs 保養）',
      legend: const [('加油', 0), ('保養', 1)],
      child: _MonthlyBarChart(months: recent),
    );

    return LayoutBuilder(
      builder: (context, c) {
        final sideBySide = c.maxWidth >= 900;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (sideBySide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: fuelCard),
                  const SizedBox(width: 16),
                  Expanded(child: costCard),
                ],
              )
            else ...[
              fuelCard,
              const SizedBox(height: 16),
              costCard,
            ],
          ],
        );
      },
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.title, required this.child, this.legend});

  final String title;
  final Widget child;

  /// (名稱, 顏色索引)：0 = primary, 1 = tertiary
  final List<(String, int)>? legend;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title, style: Theme.of(context).textTheme.titleMedium),
                ),
                if (legend != null)
                  for (final (name, idx) in legend!) ...[
                    Container(
                      width: 10,
                      height: 10,
                      color: idx == 0 ? cs.primary : cs.tertiary,
                    ),
                    const SizedBox(width: 4),
                    Text(name, style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(width: 10),
                  ],
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(height: 260, child: child),
          ],
        ),
      ),
    );
  }
}

Widget _bottomLabel(String text) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(text, style: const TextStyle(fontSize: 11)),
    );

const _noTitles = AxisTitles(sideTitles: SideTitles(showTitles: false));

class _FuelLineChart extends StatelessWidget {
  const _FuelLineChart({required this.points});

  final List<({DateTime date, double kmPerL})> points;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return const EmptyHint(
        icon: Icons.show_chart,
        text: '需要至少兩筆「跳停」加油紀錄才有油耗資料',
      );
    }
    final cs = Theme.of(context).colorScheme;
    final ys = points.map((p) => p.kmPerL);
    final lo = ys.reduce(math.min);
    final hi = ys.reduce(math.max);
    final pad = math.max((hi - lo) * 0.2, 1.0);
    final minY = math.max(0.0, (lo - pad).floorToDouble());
    final maxY = (hi + pad).ceilToDouble();
    final step = math.max(1, (points.length / 6).ceil()).toDouble();

    return LineChart(
      LineChartData(
        minY: minY,
        maxY: maxY,
        minX: 0,
        maxX: math.max(points.length - 1, 1).toDouble(),
        gridData: const FlGridData(drawVerticalLine: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: _noTitles,
          rightTitles: _noTitles,
          leftTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: true, reservedSize: 40),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: step,
              reservedSize: 28,
              getTitlesWidget: (value, meta) {
                final i = value.toInt();
                if (i < 0 || i >= points.length || value != i.toDouble()) {
                  return const SizedBox.shrink();
                }
                return _bottomLabel(DateFormat('MM/dd').format(points[i].date));
              },
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipItems: (spots) => [
              for (final s in spots)
                LineTooltipItem(
                  '${fmtDate(points[s.x.toInt()].date)}\n'
                  '${points[s.x.toInt()].kmPerL.toStringAsFixed(2)} km/L',
                  const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
            ],
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: [
              for (var i = 0; i < points.length; i++)
                FlSpot(i.toDouble(), points[i].kmPerL),
            ],
            isCurved: true,
            curveSmoothness: 0.2,
            barWidth: 3,
            color: cs.primary,
            dotData: const FlDotData(show: true),
            belowBarData: BarAreaData(
              show: true,
              color: cs.primary.withValues(alpha: 0.12),
            ),
          ),
        ],
      ),
    );
  }
}

class _MonthlyBarChart extends StatelessWidget {
  const _MonthlyBarChart({required this.months});

  final List<MonthlyCost> months;

  @override
  Widget build(BuildContext context) {
    if (months.isEmpty) {
      return const EmptyHint(icon: Icons.bar_chart, text: '還沒有花費資料');
    }
    final cs = Theme.of(context).colorScheme;
    final maxV = months.map((m) => math.max(m.fuel, m.maintenance)).reduce(math.max);
    final maxY = maxV <= 0 ? 1.0 : maxV * 1.2;
    final step = math.max(1, (months.length / 6).ceil()).toDouble();

    return BarChart(
      BarChartData(
        maxY: maxY,
        alignment: BarChartAlignment.spaceAround,
        gridData: const FlGridData(drawVerticalLine: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: _noTitles,
          rightTitles: _noTitles,
          leftTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: true, reservedSize: 48),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: step,
              reservedSize: 28,
              getTitlesWidget: (value, meta) {
                final i = value.toInt();
                if (i < 0 || i >= months.length) return const SizedBox.shrink();
                return _bottomLabel(DateFormat('yy/MM').format(months[i].month));
              },
            ),
          ),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, groupIndex, rod, rodIndex) => BarTooltipItem(
              '${DateFormat('yyyy/MM').format(months[groupIndex].month)}\n'
              '${rodIndex == 0 ? '加油' : '保養'} \$${fmtMoney(rod.toY)}',
              const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        barGroups: [
          for (var i = 0; i < months.length; i++)
            BarChartGroupData(
              x: i,
              barsSpace: 4,
              barRods: [
                BarChartRodData(
                  toY: months[i].fuel,
                  width: 10,
                  color: cs.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
                BarChartRodData(
                  toY: months[i].maintenance,
                  width: 10,
                  color: cs.tertiary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

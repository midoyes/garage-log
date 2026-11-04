import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../data/database.dart';
import '../data/repository.dart';
import '../domain/cost_summary.dart';
import '../domain/fuel_calculator.dart';
import '../domain/stats_summary.dart';
import '../providers.dart';
import 'common.dart';
import 'format.dart';

class StatsPage extends ConsumerWidget {
  const StatsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vehicle = ref.watch(currentVehicleProvider);
    if (vehicle == null) return const NoVehicleHint();

    final period = ref.watch(statsPeriodProvider);
    final logs = ref.watch(fuelLogsProvider).valueOrNull ?? const <FuelLog>[];
    final maint =
        ref.watch(maintenanceProvider).valueOrNull ?? const <MaintenanceWithItems>[];

    final now = ref.watch(todayProvider);
    final entries = logs.map(fuelLogToEntry).toList();
    final allPoints = buildStatPoints(entries, computeFuelStats(entries));
    final maintAmounts = [
      for (final m in maint)
        DatedAmount(DateTime.fromMillisecondsSinceEpoch(m.record.date), m.record.totalAmount),
    ];
    final fuelAmounts = [
      for (final l in logs)
        DatedAmount(DateTime.fromMillisecondsSinceEpoch(l.date), l.amount),
    ];

    final range = periodRange(now, period);
    final cur = summarizePeriod(points: allPoints, maintenance: maintAmounts, range: range);
    final prev = period > 0
        ? summarizePeriod(
            points: allPoints,
            maintenance: maintAmounts,
            range: previousPeriodRange(now, period),
          )
        : null;

    final points = allPoints.where((p) => range.contains(p.date)).toList();
    final outliers = countOutliers(points.map((p) => p.kmPerL));

    final allMonths = computeMonthlyCosts(fuel: fuelAmounts, maintenance: maintAmounts);
    final from = range.from;
    var months = from == null
        ? allMonths
        : allMonths
            .where((m) => !m.month.isBefore(DateTime(from.year, from.month)))
            .toList();
    // 圖表最多畫 24 個月，避免十年資料擠在一張圖；摘要數字仍計算整個期間。
    final monthsTruncated = months.length > 24;
    if (monthsTruncated) months = months.sublist(months.length - 24);

    final fuelCard = _ChartCard(
      title: '歷次油耗 (km/L)',
      footer: outliers > 0
          ? '有 $outliers 筆油耗偏離中位數 40% 以上，可能是漏記加油或里程輸入錯誤，建議回頭檢查。'
          : null,
      child: _FuelLineChart(points: points),
    );
    final costCard = _ChartCard(
      title: '每月花費（加油 vs 保養）',
      legend: const [('加油', 0), ('保養', 1)],
      footer: monthsTruncated ? '圖表只顯示最近 24 個有紀錄的月份；上方的摘要數字仍計算整個期間。' : null,
      child: _MonthlyBarChart(months: months),
    );

    return LayoutBuilder(
      builder: (context, c) {
        final sideBySide = c.maxWidth >= 900;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 3, label: Text('近 3 個月')),
                ButtonSegment(value: 12, label: Text('近 12 個月')),
                ButtonSegment(value: 0, label: Text('全部')),
              ],
              selected: {period},
              onSelectionChanged: (s) =>
                  ref.read(statsPeriodProvider.notifier).state = s.first,
            ),
            const SizedBox(height: 12),
            _SummaryTiles(cur: cur, prev: prev),
            const SizedBox(height: 16),
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

class _SummaryTiles extends StatelessWidget {
  const _SummaryTiles({required this.cur, required this.prev});

  final PeriodSummary cur;
  final PeriodSummary? prev;

  @override
  Widget build(BuildContext context) {
    final avg = cur.avgKmPerL;
    final prevAvg = prev?.avgKmPerL;
    String? delta;
    IconData? deltaIcon;
    if (avg != null && prevAvg != null) {
      final d = avg - prevAvg;
      delta = '比前一期 ${d >= 0 ? '+' : ''}${d.toStringAsFixed(2)} km/L';
      deltaIcon = d >= 0 ? Icons.trending_up : Icons.trending_down;
    }

    final tiles = [
      _Tile(
        label: '平均油耗',
        value: avg == null ? '—' : '${avg.toStringAsFixed(2)} km/L',
        sub: delta ?? (cur.intervals == 0 ? '此期間沒有完整的跳停區間' : '${cur.intervals} 個跳停區間'),
        icon: deltaIcon,
      ),
      _Tile(
        label: '完整區間每公里油費',
        value: cur.fuelCostPerKm == null ? '—' : '\$${cur.fuelCostPerKm!.toStringAsFixed(2)}',
        sub: '${fmtKm(cur.distanceKm)} km 已完成跳停區間的加油花費',
      ),
      _Tile(
        label: '估算每公里成本（區間油費＋保養）',
        value: cur.allCostPerKm == null ? '—' : '\$${cur.allCostPerKm!.toStringAsFixed(2)}',
        sub: '估算值：區間油費依區間結束日歸期，另加期間保養 \$${fmtMoney(cur.maintenanceAmount)}；'
            '不等於該期間全部實際支出',
      ),
    ];

    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 640;
        if (wide) {
          return Row(
            children: [
              for (var i = 0; i < tiles.length; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                Expanded(child: tiles[i]),
              ],
            ],
          );
        }
        return Column(
          children: [
            for (var i = 0; i < tiles.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              SizedBox(width: double.infinity, child: tiles[i]),
            ],
          ],
        );
      },
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.label, required this.value, required this.sub, this.icon});

  final String label;
  final String value;
  final String sub;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(value, style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Row(
              children: [
                if (icon != null) ...[Icon(icon, size: 16), const SizedBox(width: 4)],
                Expanded(child: Text(sub, style: theme.textTheme.bodySmall)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.title,
    required this.child,
    this.legend,
    this.footer,
  });

  final String title;
  final Widget child;
  final String? footer;

  /// (名稱, 顏色索引)：0 = primary, 1 = tertiary
  final List<(String, int)>? legend;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
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
            if (footer != null) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, size: 16, color: cs.tertiary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(footer!, style: Theme.of(context).textTheme.bodySmall),
                  ),
                ],
              ),
            ],
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

  final List<StatPoint> points;

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return const EmptyHint(
        icon: Icons.show_chart,
        text: '此期間沒有油耗資料\n（需要至少兩筆「跳停」加油紀錄）',
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
            // 油耗是實際量測值：用直線連接，不用平滑曲線，
            // 避免曲線看起來超出真實的最高 / 最低值。
            isCurved: false,
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
      return const EmptyHint(icon: Icons.bar_chart, text: '此期間沒有花費資料');
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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import 'dashboard_page.dart';
import 'fuel_page.dart';
import 'maintenance_page.dart';
import 'navigation.dart';
import 'settings_page.dart';
import 'stats_page.dart';
import 'vehicles_page.dart';

/// 寬度 >= 此值使用側邊欄（Windows 桌面 / 平板橫向）；否則底部導覽列（手機直立）。
const double kWideBreakpoint = 840;

/// 寬度 >= 此值側邊欄展開顯示文字。
const double kExtendedRailBreakpoint = 1200;

class _Dest {
  const _Dest(this.icon, this.selectedIcon, this.label);
  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// 分頁索引：0 總覽、1 加油、2 保養、3 統計、4 車輛、5 設定。
/// 手機只把前 4 個放在底部導覽列，車輛與設定從右上角選單進入；
/// 寬螢幕的側邊欄則全部列出。
const _destinations = [
  _Dest(Icons.dashboard_outlined, Icons.dashboard, '總覽'),
  _Dest(Icons.local_gas_station_outlined, Icons.local_gas_station, '加油'),
  _Dest(Icons.build_outlined, Icons.build, '保養'),
  _Dest(Icons.insert_chart_outlined, Icons.insert_chart, '統計'),
  _Dest(Icons.directions_car_outlined, Icons.directions_car, '車輛'),
  _Dest(Icons.settings_outlined, Icons.settings, '設定'),
];

const _mobileTabCount = 4;

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  Widget _page(int index) => switch (index) {
        0 => const DashboardPage(),
        1 => const FuelPage(),
        2 => const MaintenancePage(),
        3 => const StatsPage(),
        4 => const VehiclesPage(),
        _ => const SettingsPage(),
      };

  Widget? _fab(int index) {
    final vehicle = ref.watch(currentVehicleProvider);
    switch (index) {
      case 1:
        if (vehicle == null) return null;
        return FloatingActionButton.extended(
          onPressed: () => openFuelForm(context, vehicle),
          icon: const Icon(Icons.add),
          label: const Text('加油'),
        );
      case 2:
        if (vehicle == null) return null;
        return FloatingActionButton.extended(
          onPressed: () => openMaintenanceForm(context, vehicle),
          icon: const Icon(Icons.add),
          label: const Text('保養'),
        );
      case 4:
        return FloatingActionButton.extended(
          onPressed: () => openVehicleForm(context),
          icon: const Icon(Icons.add),
          label: const Text('新增車輛'),
        );
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= kWideBreakpoint;

    // 視窗從寬變窄時，車輛 / 設定分頁在手機版不存在，退回總覽。
    final index = (!wide && _index >= _mobileTabCount) ? 0 : _index;

    // 內容置中並限制最大寬度：卡片會隨視窗延伸，但不會寬到難以閱讀。
    final content = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: _page(index),
      ),
    );

    final appBar = AppBar(
      title: const Text('愛車記錄'),
      actions: [
        const VehicleSwitcher(),
        if (!wide)
          PopupMenuButton<int>(
            tooltip: '更多',
            onSelected: (v) {
              final page = v == 4 ? const VehiclesScreen() : const SettingsScreen();
              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 4,
                child: ListTile(
                  leading: Icon(Icons.directions_car),
                  title: Text('車輛管理'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              PopupMenuItem(
                value: 5,
                child: ListTile(
                  leading: Icon(Icons.settings),
                  title: Text('設定與備份'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        const SizedBox(width: 8),
      ],
    );

    if (wide) {
      final extended = width >= kExtendedRailBreakpoint;
      return Scaffold(
        appBar: appBar,
        floatingActionButton: _fab(index),
        body: Row(
          children: [
            NavigationRail(
              extended: extended,
              selectedIndex: index,
              onDestinationSelected: (i) => setState(() => _index = i),
              labelType:
                  extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
              destinations: [
                for (final d in _destinations)
                  NavigationRailDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selectedIcon),
                    label: Text(d.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: content),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: appBar,
      floatingActionButton: _fab(index),
      body: content,
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final d in _destinations.take(_mobileTabCount))
            NavigationDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.selectedIcon),
              label: d.label,
            ),
        ],
      ),
    );
  }
}

/// AppBar 上的車輛切換選單。
class VehicleSwitcher extends ConsumerWidget {
  const VehicleSwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vehicles = ref.watch(vehiclesProvider).valueOrNull ?? const [];
    final current = ref.watch(currentVehicleProvider);
    if (current == null) return const SizedBox.shrink();

    return PopupMenuButton<String>(
      tooltip: '切換車輛',
      onSelected: (id) => ref.read(selectedVehicleIdProvider.notifier).select(id),
      itemBuilder: (_) => [
        for (final v in vehicles)
          PopupMenuItem(
            value: v.id,
            child: Row(
              children: [
                Icon(v.type == 1 ? Icons.two_wheeler : Icons.directions_car, size: 20),
                const SizedBox(width: 8),
                Text(v.plate.isEmpty ? v.name : '${v.name}（${v.plate}）'),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(current.type == 1 ? Icons.two_wheeler : Icons.directions_car),
            const SizedBox(width: 6),
            Text(current.name),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }
}

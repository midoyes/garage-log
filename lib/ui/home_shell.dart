import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import 'fuel_form.dart';
import 'fuel_page.dart';
import 'maintenance_form.dart';
import 'maintenance_page.dart';
import 'settings_page.dart';
import 'stats_page.dart';
import 'vehicle_form.dart';
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

const _destinations = [
  _Dest(Icons.local_gas_station_outlined, Icons.local_gas_station, '加油'),
  _Dest(Icons.build_outlined, Icons.build, '保養'),
  _Dest(Icons.insert_chart_outlined, Icons.insert_chart, '統計'),
  _Dest(Icons.directions_car_outlined, Icons.directions_car, '車輛'),
  _Dest(Icons.settings_outlined, Icons.settings, '設定'),
];

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  Widget _page() => switch (_index) {
        0 => const FuelPage(),
        1 => const MaintenancePage(),
        2 => const StatsPage(),
        3 => const VehiclesPage(),
        _ => const SettingsPage(),
      };

  Widget? _fab() {
    final vehicle = ref.watch(currentVehicleProvider);
    void push(Widget page) =>
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

    switch (_index) {
      case 0:
        if (vehicle == null) return null;
        final logs = ref.watch(fuelLogsProvider).valueOrNull ?? const [];
        final last = logs.isEmpty ? null : logs.last.odometer;
        return FloatingActionButton.extended(
          onPressed: () =>
              push(FuelFormPage(vehicle: vehicle, lastOdometer: last)),
          icon: const Icon(Icons.add),
          label: const Text('加油'),
        );
      case 1:
        if (vehicle == null) return null;
        return FloatingActionButton.extended(
          onPressed: () => push(MaintenanceFormPage(vehicle: vehicle)),
          icon: const Icon(Icons.add),
          label: const Text('保養'),
        );
      case 3:
        return FloatingActionButton.extended(
          onPressed: () => push(const VehicleFormPage()),
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

    // 內容置中並限制最大寬度：卡片會隨視窗延伸，但不會寬到難以閱讀。
    final content = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: _page(),
      ),
    );

    final appBar = AppBar(
      title: const Text('愛車記錄'),
      actions: const [VehicleSwitcher(), SizedBox(width: 8)],
    );

    if (wide) {
      return Scaffold(
        appBar: appBar,
        floatingActionButton: _fab(),
        body: Row(
          children: [
            NavigationRail(
              extended: width >= kExtendedRailBreakpoint,
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              labelType: width >= kExtendedRailBreakpoint
                  ? NavigationRailLabelType.none
                  : NavigationRailLabelType.all,
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
      floatingActionButton: _fab(),
      body: content,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final d in _destinations)
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
      onSelected: (id) => ref.read(selectedVehicleIdProvider.notifier).state = id,
      itemBuilder: (_) => [
        for (final v in vehicles)
          PopupMenuItem(
            value: v.id,
            child: Row(
              children: [
                Icon(v.type == 1 ? Icons.two_wheeler : Icons.directions_car,
                    size: 20),
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

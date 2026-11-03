import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import 'common.dart';
import 'format.dart';
import 'vehicle_form.dart';

class VehiclesPage extends ConsumerWidget {
  const VehiclesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vehicles = ref.watch(vehiclesProvider).valueOrNull ?? const [];
    final current = ref.watch(currentVehicleProvider);

    if (vehicles.isEmpty) {
      return const EmptyHint(
        icon: Icons.directions_car_outlined,
        text: '還沒有車輛，點右下角新增',
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: [
        for (final v in vehicles)
          Card(
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              selected: v.id == current?.id,
              leading: Icon(v.type == 1 ? Icons.two_wheeler : Icons.directions_car),
              title: Text(v.name),
              subtitle: Text(
                [
                  v.type == 1 ? '機車' : '汽車',
                  if (v.plate.isNotEmpty) v.plate,
                  '初始里程 ${fmtKm(v.initialOdometer)} km',
                ].join(' · '),
              ),
              onTap: () =>
                  ref.read(selectedVehicleIdProvider.notifier).state = v.id,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (v.id == current?.id)
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: Icon(Icons.check_circle, size: 20),
                    ),
                  IconButton(
                    tooltip: '編輯',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => VehicleFormPage(vehicle: v),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '刪除',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      final ok = await confirmDialog(
                        context,
                        title: '刪除「${v.name}」？',
                        message: '這台車的所有加油與保養紀錄也會一併刪除。',
                      );
                      if (ok) await ref.read(repoProvider).deleteVehicle(v.id);
                    },
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repository.dart';
import '../providers.dart';
import 'common.dart';
import 'format.dart';
import 'maintenance_form.dart';

class MaintenancePage extends ConsumerWidget {
  const MaintenancePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vehicle = ref.watch(currentVehicleProvider);
    if (vehicle == null) return const NoVehicleHint();

    return ref.watch(maintenanceProvider).when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('讀取失敗：$e')),
          data: (records) {
            if (records.isEmpty) {
              return const EmptyHint(
                icon: Icons.build_outlined,
                text: '還沒有保養紀錄，點右下角新增',
              );
            }
            final total =
                records.fold<double>(0, (s, r) => s + r.record.totalAmount);
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                Card(
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
                ),
                const SizedBox(height: 8),
                for (final r in records)
                  _MaintenanceCard(entry: r, vehicleId: vehicle.id),
              ],
            );
          },
        );
  }
}

class _MaintenanceCard extends ConsumerWidget {
  const _MaintenanceCard({required this.entry, required this.vehicleId});

  final MaintenanceWithItems entry;
  final String vehicleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final r = entry.record;
    final date = DateTime.fromMillisecondsSinceEpoch(r.date);
    final vehicle = ref.watch(currentVehicleProvider)!;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => MaintenanceFormPage(vehicle: vehicle, existing: entry),
          ),
        ),
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
                        child: Text(
                          '${i.name}  ×${trimNum(i.quantity)} @ ${fmtMoney(i.unitPrice)}',
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

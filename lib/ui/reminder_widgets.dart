import 'package:flutter/material.dart';

import '../domain/reminders.dart';
import 'format.dart';

/// 提醒狀態的短文字。狀態同時用「圖示 + 文字 + 顏色」表達，不只靠顏色。
String reminderStatusLabel(ReminderStatus s) => switch (s) {
      ReminderStatus.overdue => '已到期',
      ReminderStatus.soon => '即將到期',
      ReminderStatus.ok => '正常',
      ReminderStatus.noHistory => '尚無更換紀錄',
      ReminderStatus.noInterval => '常用項目（未啟用提醒）',
    };

IconData reminderStatusIcon(ReminderStatus s) => switch (s) {
      ReminderStatus.overdue => Icons.error_outline,
      ReminderStatus.soon => Icons.schedule,
      ReminderStatus.ok => Icons.check_circle_outline,
      ReminderStatus.noHistory => Icons.history_toggle_off,
      ReminderStatus.noInterval => Icons.tune,
    };

Color reminderStatusColor(BuildContext context, ReminderStatus s) {
  final cs = Theme.of(context).colorScheme;
  return switch (s) {
    ReminderStatus.overdue => cs.error,
    ReminderStatus.soon => cs.tertiary,
    ReminderStatus.ok => cs.primary,
    ReminderStatus.noHistory || ReminderStatus.noInterval => cs.outline,
  };
}

/// 「剩 1,500 km · 剩 45 天」或「已超過 300 km」這類說明。
String reminderRemainingText(ReminderResult r) {
  final parts = <String>[];
  final km = r.remainingKm;
  final days = r.remainingDays;
  if (km != null) {
    parts.add(km <= 0 ? '已超過 ${fmtKm(-km)} km' : '剩 ${fmtKm(km)} km');
  }
  if (days != null) {
    parts.add(days <= 0 ? '已逾期 ${-days} 天' : '剩 $days 天');
  }
  return parts.join(' · ');
}

/// 「預計 150,000 km / 2026-12-01」。
String reminderDueText(ReminderResult r) {
  final parts = <String>[];
  if (r.dueOdometer != null) parts.add('${fmtKm(r.dueOdometer!)} km');
  if (r.dueDate != null) parts.add(fmtDate(r.dueDate!));
  return parts.isEmpty ? '' : '預計 ${parts.join(' / ')}';
}

/// 提醒清單中的一列（總覽與保養頁共用）。
class ReminderTile extends StatelessWidget {
  const ReminderTile({super.key, required this.result, this.onTap, this.trailing});

  final ReminderResult result;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final color = reminderStatusColor(context, result.status);
    final status = result.status;
    final detail = switch (status) {
      ReminderStatus.overdue || ReminderStatus.soon || ReminderStatus.ok =>
        '${reminderRemainingText(result)}\n${reminderDueText(result)}',
      _ => reminderStatusLabel(status),
    };

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      onTap: onTap,
      leading: Icon(reminderStatusIcon(status), color: color),
      title: Row(
        children: [
          Flexible(child: Text(result.plan.name)),
          if (status == ReminderStatus.overdue || status == ReminderStatus.soon) ...[
            const SizedBox(width: 8),
            Text(
              reminderStatusLabel(status),
              style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ],
        ],
      ),
      subtitle: Text(detail),
      isThreeLine: detail.contains('\n'),
      trailing: trailing,
    );
  }
}

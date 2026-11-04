import 'package:flutter_test/flutter_test.dart';
import 'package:garage_log/domain/reminders.dart';

PartRecord oil(DateTime d, double odo, {String name = '機油'}) =>
    PartRecord(name: name, date: d, odometer: odo, quantity: 4, unitPrice: 350);

void main() {
  final history = [
    oil(DateTime(2026, 1, 10), 100000),
    oil(DateTime(2026, 4, 15), 105000),
    oil(DateTime(2026, 8, 20), 110000),
    PartRecord(name: '輪胎', date: DateTime(2025, 6, 1), odometer: 90000),
  ];
  const plan = PlanSpec(id: 'p1', name: '機油', intervalKm: 5000, intervalDays: 180);

  ReminderResult run({
    PlanSpec p = plan,
    double odo = 112000,
    DateTime? now,
    List<PartRecord>? records,
  }) =>
      computeReminder(
        plan: p,
        records: records ?? history,
        currentOdometer: odo,
        now: now ?? DateTime(2026, 9, 1),
      );

  group('computeReminder', () {
    test('以最後一次更換為準，算出下次里程與日期', () {
      final r = run();
      expect(r.lastOdometer, 110000);
      expect(r.lastDate, DateTime(2026, 8, 20));
      expect(r.dueOdometer, 115000);
      expect(r.dueDate, DateTime(2027, 2, 16)); // 8/20 + 180 天
      expect(r.remainingKm, 3000);
      expect(r.remainingDays, 168);
      expect(r.historyCount, 3);
      expect(r.status, ReminderStatus.ok);
    });

    test('里程先到就提醒（即將到期）', () {
      expect(run(odo: 114600).status, ReminderStatus.soon); // 剩 400 km
    });

    test('里程超過 → 已到期', () {
      final r = run(odo: 115200);
      expect(r.status, ReminderStatus.overdue);
      expect(r.remainingKm, -200);
    });

    test('日期先到也算到期（里程還沒到）', () {
      final r = run(now: DateTime(2027, 3, 1), odo: 111000);
      expect(r.status, ReminderStatus.overdue);
      expect(r.remainingKm, greaterThan(0));
      expect(r.remainingDays, lessThan(0));
    });

    test('只設定里程時，沒有天數資訊', () {
      final r = run(p: const PlanSpec(id: 'p', name: '機油', intervalKm: 5000));
      expect(r.remainingKm, 3000);
      expect(r.remainingDays, isNull);
      expect(r.dueDate, isNull);
    });

    test('只設定天數時，沒有里程資訊', () {
      final r = run(p: const PlanSpec(id: 'p', name: '機油', intervalDays: 180));
      expect(r.remainingKm, isNull);
      expect(r.remainingDays, 168);
    });

    test('沒有更換紀錄 → noHistory', () {
      final r = run(p: const PlanSpec(id: 'p', name: '電瓶', intervalKm: 30000));
      expect(r.status, ReminderStatus.noHistory);
      expect(r.historyCount, 0);
    });

    test('沒有設定週期 → noInterval，但仍帶出上次更換', () {
      final r = run(p: const PlanSpec(id: 'p', name: '機油'));
      expect(r.status, ReminderStatus.noInterval);
      expect(r.lastOdometer, 110000);
    });

    test('名稱比對忽略空白與大小寫', () {
      final r = run(
        records: [oil(DateTime(2026, 8, 20), 110000, name: '  機油 ')],
      );
      expect(r.status, ReminderStatus.ok);
      expect(r.historyCount, 1);
    });

    test('零件名稱不同不會混在一起（機油 vs 機油濾芯）', () {
      final r = run(
        records: [oil(DateTime(2026, 8, 20), 110000, name: '機油濾芯')],
      );
      expect(r.status, ReminderStatus.noHistory);
    });
  });

  test('compareReminders：已到期 → 即將到期 → 正常 → 無紀錄 → 未設定', () {
    final overdue = run(odo: 115200);
    final soon = run(odo: 114600);
    final ok = run();
    final none = run(p: const PlanSpec(id: 'x', name: '電瓶', intervalKm: 1));
    final unset = run(p: const PlanSpec(id: 'y', name: '輪胎'));
    final list = [unset, ok, none, soon, overdue]..sort(compareReminders);
    expect(list.map((r) => r.status), [
      ReminderStatus.overdue,
      ReminderStatus.soon,
      ReminderStatus.ok,
      ReminderStatus.noHistory,
      ReminderStatus.noInterval,
    ]);
  });

  group('零件歷史', () {
    test('partHistory：只含該零件，最新的在前', () {
      final h = partHistory(history, '機油');
      expect(h.map((r) => r.odometer), [110000, 105000, 100000]);
    });

    test('summarizeParts：每個零件一列、最近更換的在前', () {
      final parts = summarizeParts(history);
      expect(parts.map((p) => p.name), ['機油', '輪胎']);
      expect(parts.first.count, 3);
      expect(parts.first.last.odometer, 110000);
    });
  });

  test('currentOdometerOf：取初始里程與所有讀數的最大值', () {
    expect(currentOdometerOf(initial: 500, readings: const []), 500);
    expect(currentOdometerOf(initial: 500, readings: [600, 1200, 900]), 1200);
    expect(currentOdometerOf(initial: 500, readings: [double.nan, 300]), 500);
  });
}

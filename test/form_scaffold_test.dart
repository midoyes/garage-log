import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garage_log/ui/common.dart';

void main() {
  testWidgets('連續快速點擊儲存，只會執行一次', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: FormScaffold(
          title: '測試',
          children: const [Text('內容')],
          onSave: () async {
            calls++;
            await Future<void>.delayed(const Duration(milliseconds: 100));
          },
        ),
      ),
    );

    final button = find.byWidgetPredicate((w) => w is FilledButton);
    await tester.tap(button);
    await tester.tap(button);
    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 300));

    expect(calls, 1);
  });

  testWidgets('儲存時發生非預期錯誤：顯示失敗提示、頁面與輸入保留、按鈕恢復', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FormScaffold(
          title: '測試',
          children: const [Text('輸入內容')],
          onSave: () async => throw StateError('disk full'),
        ),
      ),
    );

    await tester.tap(find.byWidgetPredicate((w) => w is FilledButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('儲存失敗'), findsOneWidget);
    expect(find.text('輸入內容'), findsOneWidget);
    expect(find.text('儲存'), findsOneWidget);
  });

  testWidgets('儲存結束但頁面沒關閉（例如驗證失敗）後，按鈕會恢復可再按', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: FormScaffold(
          title: '測試',
          children: const [Text('內容')],
          onSave: () async {
            calls++;
            await Future<void>.delayed(const Duration(milliseconds: 50));
            // onSave 正常結束但頁面沒有關閉（驗證失敗時的情況）
          },
        ),
      ),
    );

    final button = find.byWidgetPredicate((w) => w is FilledButton);
    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('儲存'), findsOneWidget); // 已恢復

    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 200));
    expect(calls, 2);
  });
}

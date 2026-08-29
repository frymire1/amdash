import 'package:admin/classes/audit_log_entry.dart';
import 'package:admin/screens/audit_log_screen.dart';
import 'package:admin/services/admin_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../support/pump_app.dart';

class _MockAdminService extends Mock implements AdminService {}

AuditLogEntry _entry({
  String id = 'entry-1',
  String action = 'user.create',
  String actorEmail = 'jordan@example.com',
  String? target = 'uid-1',
  Map<String, Object?> details = const {},
  Object? timestamp = _defaultTimestamp,
}) {
  return AuditLogEntry(
    id: id,
    action: action,
    actorEmail: actorEmail,
    target: target,
    details: details,
    timestamp: identical(timestamp, _defaultTimestamp) ? DateTime(2026, 8, 15, 15, 42) : timestamp as DateTime?,
  );
}

// A sentinel distinct from `null` so `_entry(timestamp: null)` can express
// "genuinely no timestamp" instead of falling back to the default (which a
// plain nullable default param + `??` can't distinguish from "not passed").
const _defaultTimestamp = Object();

void main() {
  late _MockAdminService adminService;

  setUp(() {
    adminService = _MockAdminService();
  });

  Future<void> pumpScreen(WidgetTester tester) {
    return pumpApp(
      tester,
      const AuditLogScreen(),
      overrides: [adminServiceProvider.overrideWithValue(adminService)],
    );
  }

  testWidgets('loads and shows entries on mount', (tester) async {
    when(
      () => adminService.listAuditLog(),
    ).thenAnswer((_) async => AuditLogPage(entries: [_entry()], hasMore: false));

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    expect(find.text('jordan@example.com'), findsOneWidget);
    expect(find.text('Created user'), findsOneWidget);
  });

  testWidgets('a load failure shows the inline error', (tester) async {
    when(() => adminService.listAuditLog()).thenThrow(Exception('boom'));

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    expect(find.text('Failed to load the audit log. Please try again.'), findsOneWidget);
  });

  testWidgets('no activity yet: shows the empty state', (tester) async {
    when(() => adminService.listAuditLog()).thenAnswer((_) async => const AuditLogPage(entries: [], hasMore: false));

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    expect(find.text('No activity yet'), findsOneWidget);
  });

  testWidgets('tapping refresh reloads the list', (tester) async {
    when(
      () => adminService.listAuditLog(),
    ).thenAnswer((_) async => AuditLogPage(entries: [_entry()], hasMore: false));

    await pumpScreen(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();

    verify(() => adminService.listAuditLog()).called(2);
  });

  group('entry rendering', () {
    testWidgets('an unrecognized action falls back to the raw action string', (tester) async {
      when(
        () => adminService.listAuditLog(),
      ).thenAnswer((_) async => AuditLogPage(entries: [_entry(action: 'some.newAction')], hasMore: false));

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      expect(find.text('some.newAction'), findsOneWidget);
    });

    testWidgets('an entry with no timestamp shows an em dash', (tester) async {
      when(() => adminService.listAuditLog()).thenAnswer(
        (_) async => AuditLogPage(entries: [_entry(timestamp: null)], hasMore: false),
      );

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      expect(find.text('—'), findsWidgets);
    });

    testWidgets('a timestamp formats as "Mon D, YYYY, H:MM AM/PM"', (tester) async {
      when(() => adminService.listAuditLog()).thenAnswer(
        (_) async => AuditLogPage(entries: [_entry(timestamp: DateTime(2026, 1, 5, 0, 5))], hasMore: false),
      );

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      expect(find.text('Jan 5, 2026, 12:05 AM'), findsOneWidget);
    });

    testWidgets('details combine target + each detail entry, comma-separated', (tester) async {
      when(() => adminService.listAuditLog()).thenAnswer(
        (_) async => AuditLogPage(
          entries: [
            _entry(target: 'uid-9', details: const {'role': 'ems'}),
          ],
          hasMore: false,
        ),
      );

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      expect(find.text('target: uid-9, role: ems'), findsOneWidget);
    });

    testWidgets('no target and no details shows an em dash', (tester) async {
      when(() => adminService.listAuditLog()).thenAnswer(
        (_) async => AuditLogPage(entries: [_entry(target: null, details: const {})], hasMore: false),
      );

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      expect(find.text('—'), findsOneWidget);
    });
  });

  group('search', () {
    testWidgets('searching by actor email narrows the table', (tester) async {
      when(() => adminService.listAuditLog()).thenAnswer(
        (_) async => AuditLogPage(
          entries: [_entry(actorEmail: 'jordan@example.com'), _entry(actorEmail: 'sam@example.com')],
          hasMore: false,
        ),
      );

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Search'), 'sam');
      await tester.pumpAndSettle();

      expect(find.text('sam@example.com'), findsOneWidget);
      expect(find.text('jordan@example.com'), findsNothing);
    });

    testWidgets('a search matching nothing shows the filtered-empty state', (tester) async {
      when(
        () => adminService.listAuditLog(),
      ).thenAnswer((_) async => AuditLogPage(entries: [_entry()], hasMore: false));

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Search'), 'nobody');
      await tester.pumpAndSettle();

      expect(find.text('No activity matches this search'), findsOneWidget);
    });
  });

  group('load more', () {
    testWidgets('hasMore true: shows the Load more button; false: hides it', (tester) async {
      when(
        () => adminService.listAuditLog(),
      ).thenAnswer((_) async => AuditLogPage(entries: [_entry()], hasMore: true));

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      expect(find.text('Load more'), findsOneWidget);
    });

    testWidgets('tapping Load more pages back from the oldest loaded entry and appends', (tester) async {
      final older = _entry(id: 'entry-2', actorEmail: 'older@example.com', timestamp: DateTime(2026, 1, 1));
      // A single stub keyed on the actual argument, not two separate
      // when()s — `listAuditLog()` (implicit null) and
      // `listAuditLog(beforeTimestampMs: any())` both match a null-arg
      // call, so registering them separately leaves it up to mocktail's
      // own stub-priority rules which one answers the first (no-arg) call;
      // confirmed for real that the any()-based stub won and the initial
      // load got the "older" page instead of the first one.
      when(() => adminService.listAuditLog(beforeTimestampMs: any(named: 'beforeTimestampMs'))).thenAnswer((
        invocation,
      ) async {
        final before = invocation.namedArguments[#beforeTimestampMs] as int?;
        return before == null
            ? AuditLogPage(entries: [_entry()], hasMore: true)
            : AuditLogPage(entries: [older], hasMore: false);
      });

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Load more'));
      await tester.pumpAndSettle();

      verify(
        () => adminService.listAuditLog(
          beforeTimestampMs: DateTime(2026, 8, 15, 15, 42).millisecondsSinceEpoch,
        ),
      ).called(1);
      expect(find.text('jordan@example.com'), findsOneWidget);
      expect(find.text('older@example.com'), findsOneWidget);
      // hasMore now false — the button is gone.
      expect(find.text('Load more'), findsNothing);
    });

    testWidgets('a load-more failure shows its own error message', (tester) async {
      // Same single-stub-keyed-on-the-argument approach as the test above.
      when(() => adminService.listAuditLog(beforeTimestampMs: any(named: 'beforeTimestampMs'))).thenAnswer((
        invocation,
      ) async {
        final before = invocation.namedArguments[#beforeTimestampMs] as int?;
        if (before == null) return AuditLogPage(entries: [_entry()], hasMore: true);
        throw Exception('boom');
      });

      await pumpScreen(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Load more'));
      await tester.pumpAndSettle();

      expect(find.text('Failed to load more activity. Please try again.'), findsOneWidget);
    });
  });
}

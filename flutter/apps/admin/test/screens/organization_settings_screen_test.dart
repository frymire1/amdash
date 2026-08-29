import 'dart:async';

import 'package:admin/screens/organization_settings_screen.dart';
import 'package:admin/services/admin_service.dart';
import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../support/pump_app.dart';

class _MockAdminService extends Mock implements AdminService {}

void main() {
  late _MockAdminService adminService;

  setUp(() {
    adminService = _MockAdminService();
  });

  Future<void> pumpScreen(WidgetTester tester, {Organization? organization}) {
    return pumpApp(
      tester,
      const OrganizationSettingsScreen(),
      overrides: [
        adminServiceProvider.overrideWithValue(adminService),
        ownOrganizationProvider.overrideWith((ref) => Stream.value(organization)),
        hospitalsProvider.overrideWith((ref) => Stream.value(const [])),
      ],
    );
  }

  testWidgets('while the organization is still loading, every save control is disabled', (tester) async {
    await pumpScreen(tester, organization: null);
    await tester.pumpAndSettle();

    final saveButton = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));
    expect(saveButton.onPressed, isNull);
    final retentionSwitch = tester.widgetList<Switch>(find.byType(Switch)).first;
    expect(retentionSwitch.onChanged, isNull);
  });

  testWidgets('hosts the Hospitals section below the org settings cards', (tester) async {
    await pumpScreen(tester, organization: const Organization(id: 'org-1', name: 'Acme Health'));
    await tester.pumpAndSettle();

    expect(find.text('Hospitals'), findsWidgets);
    expect(find.text('No hospitals yet'), findsOneWidget);
  });

  group('country', () {
    testWidgets('prefills the dropdown from the live organization', (tester) async {
      await pumpScreen(tester, organization: const Organization(id: 'org-1', name: 'Acme Health', country: 'US'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(DropdownButtonFormField<String>, 'United States'), findsOneWidget);
    });

    testWidgets('saving without a selection is disabled', (tester) async {
      await pumpScreen(tester, organization: const Organization(id: 'org-1', name: 'Acme Health'));
      await tester.pumpAndSettle();

      final saveButton = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));
      expect(saveButton.onPressed, isNull);
    });

    testWidgets('selecting and saving succeeds', (tester) async {
      when(() => adminService.setOrganizationCountry(any())).thenAnswer((_) async {});

      await pumpScreen(tester, organization: const Organization(id: 'org-1', name: 'Acme Health'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(DropdownButtonFormField<String>, 'Country'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Canada').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      verify(() => adminService.setOrganizationCountry('CA')).called(1);
      expect(find.text('Saved.'), findsOneWidget);
    });

    testWidgets('a save failure shows the inline error', (tester) async {
      when(() => adminService.setOrganizationCountry(any())).thenThrow(Exception('boom'));

      await pumpScreen(tester, organization: const Organization(id: 'org-1', name: 'Acme Health', country: 'US'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(find.text('Failed to save. Please try again.'), findsOneWidget);
    });

    testWidgets('while saving, the button shows a spinner', (tester) async {
      final completer = Completer<void>();
      when(() => adminService.setOrganizationCountry(any())).thenAnswer((_) => completer.future);

      await pumpScreen(tester, organization: const Organization(id: 'org-1', name: 'Acme Health', country: 'US'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();

      expect(
        find.descendant(of: find.byType(FilledButton), matching: find.byType(CircularProgressIndicator)),
        findsOneWidget,
      );

      completer.complete();
      await tester.pumpAndSettle();
    });
  });

  group('data retention', () {
    testWidgets('defaults to auto-delete when unset', (tester) async {
      await pumpScreen(tester, organization: const Organization(id: 'org-1', name: 'Acme Health'));
      await tester.pumpAndSettle();

      expect(find.text('Auto-deleting after 48 hours'), findsOneWidget);
    });

    testWidgets('retainAllData true shows the retaining message', (tester) async {
      await pumpScreen(
        tester,
        organization: const Organization(id: 'org-1', name: 'Acme Health', retainAllData: true),
      );
      await tester.pumpAndSettle();

      expect(find.text('Retaining all data'), findsOneWidget);
    });

    testWidgets(
      'toggling calls the service with the new value; the label only flips once the live '
      'organization listener confirms it (no optimistic local update, by design)',
      (tester) async {
        when(() => adminService.setOrganizationRetention(any())).thenAnswer((_) async {});
        final orgController = StreamController<Organization?>();
        addTearDown(orgController.close);

        await pumpApp(
          tester,
          const OrganizationSettingsScreen(),
          overrides: [
            adminServiceProvider.overrideWithValue(adminService),
            ownOrganizationProvider.overrideWith((ref) => orgController.stream),
            hospitalsProvider.overrideWith((ref) => Stream.value(const [])),
          ],
        );
        orgController.add(const Organization(id: 'org-1', name: 'Acme Health'));
        await tester.pumpAndSettle();

        await tester.ensureVisible(find.byType(Switch).first);
        await tester.tap(find.byType(Switch).first);
        await tester.pumpAndSettle();

        verify(() => adminService.setOrganizationRetention(true)).called(1);
        // Still the pre-toggle label — the switch reads straight off
        // ownOrganizationProvider, and that hasn't emitted anything new yet.
        expect(find.text('Auto-deleting after 48 hours'), findsOneWidget);

        // The real Firestore listener now catches the confirmed write.
        orgController.add(const Organization(id: 'org-1', name: 'Acme Health', retainAllData: true));
        await tester.pumpAndSettle();

        expect(find.text('Retaining all data'), findsOneWidget);
      },
    );

    testWidgets('a toggle failure shows the inline error', (tester) async {
      when(() => adminService.setOrganizationRetention(any())).thenThrow(Exception('boom'));

      await pumpScreen(tester, organization: const Organization(id: 'org-1', name: 'Acme Health'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byType(Switch).first);
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();

      expect(find.text('Failed to save. Please try again.'), findsOneWidget);
    });

    testWidgets('while saving, a spinner appears next to the switch', (tester) async {
      final completer = Completer<void>();
      when(() => adminService.setOrganizationRetention(any())).thenAnswer((_) => completer.future);

      await pumpScreen(tester, organization: const Organization(id: 'org-1', name: 'Acme Health'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byType(Switch).first);
      await tester.tap(find.byType(Switch).first);
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      completer.complete();
      await tester.pumpAndSettle();
    });
  });

  group('patient record audit logging', () {
    testWidgets('defaults to enabled when unset', (tester) async {
      await pumpScreen(tester, organization: const Organization(id: 'org-1', name: 'Acme Health'));
      await tester.pumpAndSettle();

      expect(find.text('Logging patient record actions'), findsOneWidget);
    });

    testWidgets('explicitly disabled shows the not-logging message', (tester) async {
      await pumpScreen(
        tester,
        organization: const Organization(id: 'org-1', name: 'Acme Health', auditLoggingEnabled: false),
      );
      await tester.pumpAndSettle();

      expect(find.text('Not logging patient record actions'), findsOneWidget);
    });

    testWidgets('toggling off calls the service with the new value', (tester) async {
      // No optimistic local update by design (see the screen's own doc
      // comment) — the switch's displayed value stays bound to
      // ownOrganizationProvider until the real Firestore listener catches
      // the confirmed write, which retention's own test below exercises via
      // a StreamController. This test just confirms the call itself.
      when(() => adminService.setOrganizationAuditLogging(any())).thenAnswer((_) async {});

      await pumpScreen(tester, organization: const Organization(id: 'org-1', name: 'Acme Health'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byType(Switch).at(1));
      await tester.tap(find.byType(Switch).at(1));
      await tester.pumpAndSettle();

      verify(() => adminService.setOrganizationAuditLogging(false)).called(1);
    });

    testWidgets('a toggle failure shows the inline error', (tester) async {
      when(() => adminService.setOrganizationAuditLogging(any())).thenThrow(Exception('boom'));

      await pumpScreen(tester, organization: const Organization(id: 'org-1', name: 'Acme Health'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byType(Switch).at(1));
      await tester.tap(find.byType(Switch).at(1));
      await tester.pumpAndSettle();

      expect(find.text('Failed to save. Please try again.'), findsOneWidget);
    });
  });

  group('CMEK patient data encryption', () {
    testWidgets('defaults to not requested', (tester) async {
      await pumpScreen(tester, organization: const Organization(id: 'org-1', name: 'Acme Health'));
      await tester.pumpAndSettle();

      expect(find.text('Not requested'), findsOneWidget);
    });

    testWidgets('a Canadian org sees the CLOUD Act / data-residency callout', (tester) async {
      await pumpScreen(tester, organization: const Organization(id: 'org-1', name: 'Acme Health', country: 'CA'));
      await tester.pumpAndSettle();

      expect(find.textContaining('CLOUD Act'), findsOneWidget);
    });

    testWidgets('a non-Canadian org does not see the callout', (tester) async {
      await pumpScreen(tester, organization: const Organization(id: 'org-1', name: 'Acme Health', country: 'US'));
      await tester.pumpAndSettle();

      expect(find.textContaining('CLOUD Act'), findsNothing);
    });

    testWidgets('toggling on calls the service with the new value', (tester) async {
      when(() => adminService.setOrganizationCmekPreference(any())).thenAnswer((_) async {});

      await pumpScreen(tester, organization: const Organization(id: 'org-1', name: 'Acme Health'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byType(Switch).at(2));
      await tester.tap(find.byType(Switch).at(2));
      await tester.pumpAndSettle();

      verify(() => adminService.setOrganizationCmekPreference(true)).called(1);
    });

    testWidgets('a toggle failure shows the inline error', (tester) async {
      when(() => adminService.setOrganizationCmekPreference(any())).thenThrow(Exception('boom'));

      await pumpScreen(tester, organization: const Organization(id: 'org-1', name: 'Acme Health'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byType(Switch).at(2));
      await tester.tap(find.byType(Switch).at(2));
      await tester.pumpAndSettle();

      expect(find.text('Failed to save. Please try again.'), findsOneWidget);
    });
  });

  group('FHIR data export', () {
    testWidgets('defaults to disabled', (tester) async {
      await pumpScreen(tester, organization: const Organization(id: 'org-1', name: 'Acme Health'));
      await tester.pumpAndSettle();

      expect(find.text('Export disabled'), findsOneWidget);
    });

    testWidgets('toggling on calls the service with the new value', (tester) async {
      when(() => adminService.setOrganizationFhirExportEnabled(any())).thenAnswer((_) async {});

      await pumpScreen(tester, organization: const Organization(id: 'org-1', name: 'Acme Health'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byType(Switch).at(3));
      await tester.tap(find.byType(Switch).at(3));
      await tester.pumpAndSettle();

      verify(() => adminService.setOrganizationFhirExportEnabled(true)).called(1);
    });

    testWidgets('a toggle failure shows the inline error', (tester) async {
      when(() => adminService.setOrganizationFhirExportEnabled(any())).thenThrow(Exception('boom'));

      await pumpScreen(tester, organization: const Organization(id: 'org-1', name: 'Acme Health'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byType(Switch).at(3));
      await tester.tap(find.byType(Switch).at(3));
      await tester.pumpAndSettle();

      expect(find.text('Failed to save. Please try again.'), findsOneWidget);
    });
  });
}

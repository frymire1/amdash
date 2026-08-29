import 'dart:async';

import 'package:admin/classes/managed_user.dart';
import 'package:admin/services/admin_service.dart';
import 'package:admin/widgets/edit_user_dialog.dart';
import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../support/pump_app.dart';

class _MockAdminService extends Mock implements AdminService {}

const _user = ManagedUser(
  uid: 'uid-1',
  email: 'jordan@example.com',
  firstName: 'Jordan',
  lastName: 'Lee',
  role: [UserRole.ems],
  disabled: false,
  hasPassword: true,
  mfaEnrolled: false,
);

void main() {
  setUpAll(() {
    // mocktail can't auto-generate a fallback for a custom enum, needed for
    // any(named: 'role') below — an unconsumed matcher registration from
    // this otherwise silently corrupts whichever test runs next.
    registerFallbackValue(UserRole.ems);
  });

  late _MockAdminService adminService;
  late int changedCount;

  setUp(() {
    adminService = _MockAdminService();
    changedCount = 0;
  });

  Future<void> pumpDialog(WidgetTester tester, {ManagedUser user = _user}) async {
    // The default 600px-tall surface clips this dialog's own scrollable
    // content (Suspend/Reset/Delete buttons and the add-role dropdown's
    // popup menu all sit below the fold otherwise) — taller here so every
    // test can reach them, same fix as physician's hour-dropdown test.
    await tester.binding.setSurfaceSize(const Size(800, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    return pumpApp(
      tester,
      Builder(
        builder: (context) => FilledButton(
          onPressed: () => showEditUserDialog(context, user, () => changedCount++),
          child: const Text('Open'),
        ),
      ),
      overrides: [adminServiceProvider.overrideWithValue(adminService)],
    );
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  group('profile', () {
    testWidgets('prefills email/first/last name', (tester) async {
      await pumpDialog(tester);
      await open(tester);

      expect(find.widgetWithText(TextField, 'jordan@example.com'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Jordan'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Lee'), findsOneWidget);
    });

    testWidgets('saving with an empty field is a no-op', (tester) async {
      await pumpDialog(tester);
      await open(tester);

      await tester.enterText(find.widgetWithText(TextField, 'jordan@example.com'), '');
      await tester.tap(find.text('Save Changes'));
      await tester.pumpAndSettle();

      verifyNever(
        () => adminService.updateUser(
          uid: any(named: 'uid'),
          email: any(named: 'email'),
          firstName: any(named: 'firstName'),
          lastName: any(named: 'lastName'),
        ),
      );
    });

    testWidgets('saving successfully shows Saved. and notifies onChanged', (tester) async {
      when(
        () => adminService.updateUser(
          uid: any(named: 'uid'),
          email: any(named: 'email'),
          firstName: any(named: 'firstName'),
          lastName: any(named: 'lastName'),
        ),
      ).thenAnswer((_) async => _user);

      await pumpDialog(tester);
      await open(tester);

      await tester.enterText(find.widgetWithText(TextField, 'Lee'), 'Nguyen');
      await tester.tap(find.text('Save Changes'));
      await tester.pumpAndSettle();

      verify(
        () => adminService.updateUser(uid: 'uid-1', email: 'jordan@example.com', firstName: 'Jordan', lastName: 'Nguyen'),
      ).called(1);
      expect(find.text('Saved.'), findsOneWidget);
      expect(changedCount, 1);
    });

    testWidgets('a failure with a short server message shows it verbatim', (tester) async {
      when(
        () => adminService.updateUser(
          uid: any(named: 'uid'),
          email: any(named: 'email'),
          firstName: any(named: 'firstName'),
          lastName: any(named: 'lastName'),
        ),
      ).thenThrow(Exception('message: invalid email'));

      await pumpDialog(tester);
      await open(tester);

      await tester.tap(find.text('Save Changes'));
      await tester.pumpAndSettle();

      expect(find.textContaining('invalid email'), findsOneWidget);
    });

    testWidgets('a failure with a long, opaque message shows the fallback', (tester) async {
      when(
        () => adminService.updateUser(
          uid: any(named: 'uid'),
          email: any(named: 'email'),
          firstName: any(named: 'firstName'),
          lastName: any(named: 'lastName'),
        ),
      ).thenThrow(Exception('x' * 200));

      await pumpDialog(tester);
      await open(tester);

      await tester.tap(find.text('Save Changes'));
      await tester.pumpAndSettle();

      expect(find.text('Failed to save changes.'), findsOneWidget);
    });
  });

  group('roles', () {
    testWidgets('no roles assigned: shows the placeholder text', (tester) async {
      await pumpDialog(tester, user: const ManagedUser(
        uid: 'uid-1',
        email: 'jordan@example.com',
        firstName: 'Jordan',
        lastName: 'Lee',
        role: [],
        disabled: false,
        hasPassword: true,
        mfaEnrolled: false,
      ));
      await open(tester);

      expect(find.text('No roles assigned.'), findsOneWidget);
    });

    testWidgets('existing roles render as chips', (tester) async {
      await pumpDialog(tester);
      await open(tester);

      expect(find.text('ems'), findsOneWidget);
    });

    testWidgets('removing a role calls the service and drops the chip', (tester) async {
      when(() => adminService.removeUserRole(email: any(named: 'email'), role: any(named: 'role'))).thenAnswer(
        (_) async {},
      );

      await pumpDialog(tester);
      await open(tester);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      verify(() => adminService.removeUserRole(email: 'jordan@example.com', role: UserRole.ems)).called(1);
      expect(find.text('ems'), findsNothing);
      expect(changedCount, 1);
    });

    testWidgets('a failed role removal shows a snackbar and keeps the chip', (tester) async {
      when(() => adminService.removeUserRole(email: any(named: 'email'), role: any(named: 'role'))).thenThrow(
        Exception('message: cannot remove'),
      );

      await pumpDialog(tester);
      await open(tester);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.textContaining('cannot remove'), findsOneWidget);
      expect(find.text('ems'), findsOneWidget);
    });

    testWidgets('the add-role dropdown only offers unassigned roles', (tester) async {
      await pumpDialog(tester);
      await open(tester);

      await tester.ensureVisible(find.byKey(const Key('edit_role_dropdown')));
      await tester.tap(find.byKey(const Key('edit_role_dropdown')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('edit_role_option_physician')), findsOneWidget);
      expect(find.byKey(const Key('edit_role_option_nurse')), findsOneWidget);
      expect(find.byKey(const Key('edit_role_option_ems')), findsNothing);
    });

    testWidgets('adding a role calls the service and shows a new chip', (tester) async {
      when(() => adminService.setUserRole(email: any(named: 'email'), role: any(named: 'role'))).thenAnswer(
        (_) async {},
      );

      await pumpDialog(tester);
      await open(tester);

      await tester.ensureVisible(find.byKey(const Key('edit_role_dropdown')));
      await tester.tap(find.byKey(const Key('edit_role_dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('edit_role_option_physician')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('edit_role_add_button')));
      await tester.pumpAndSettle();

      verify(() => adminService.setUserRole(email: 'jordan@example.com', role: UserRole.physician)).called(1);
      expect(find.text('physician'), findsOneWidget);
      expect(changedCount, 1);
    });

    testWidgets('a failed role add shows the inline error', (tester) async {
      when(() => adminService.setUserRole(email: any(named: 'email'), role: any(named: 'role'))).thenThrow(
        Exception('message: role limit reached'),
      );

      await pumpDialog(tester);
      await open(tester);

      await tester.ensureVisible(find.byKey(const Key('edit_role_dropdown')));
      await tester.tap(find.byKey(const Key('edit_role_dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('edit_role_option_physician')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('edit_role_add_button')));
      await tester.pumpAndSettle();

      expect(find.textContaining('role limit reached'), findsOneWidget);
    });

    testWidgets('all assignable roles already assigned: the add-role controls are hidden', (tester) async {
      await pumpDialog(
        tester,
        user: const ManagedUser(
          uid: 'uid-1',
          email: 'jordan@example.com',
          firstName: 'Jordan',
          lastName: 'Lee',
          role: [UserRole.ems, UserRole.physician, UserRole.nurse],
          disabled: false,
          hasPassword: true,
          mfaEnrolled: false,
        ),
      );
      await open(tester);

      expect(find.byKey(const Key('edit_role_dropdown')), findsNothing);
    });
  });

  group('account status', () {
    testWidgets('active, password-set, MFA off: shows Active + not-set-up pills', (tester) async {
      await pumpDialog(tester);
      await open(tester);

      expect(find.text('ACTIVE'), findsOneWidget);
      expect(find.text('TWO-STEP SIGN-IN NOT SET UP'), findsOneWidget);
    });

    testWidgets('invited (no password yet): shows the Invited pill and a Resend Invite button', (tester) async {
      await pumpDialog(
        tester,
        user: const ManagedUser(
          uid: 'uid-1',
          email: 'jordan@example.com',
          firstName: 'Jordan',
          lastName: 'Lee',
          role: [],
          disabled: false,
          hasPassword: false,
          mfaEnrolled: false,
        ),
      );
      await open(tester);

      expect(find.text('INVITED'), findsOneWidget);
      expect(find.text('Resend Invite'), findsOneWidget);
    });

    testWidgets('suspended: shows the Suspended pill and hides Resend Invite', (tester) async {
      await pumpDialog(
        tester,
        user: const ManagedUser(
          uid: 'uid-1',
          email: 'jordan@example.com',
          firstName: 'Jordan',
          lastName: 'Lee',
          role: [],
          disabled: true,
          hasPassword: false,
          mfaEnrolled: false,
        ),
      );
      await open(tester);

      expect(find.text('SUSPENDED'), findsOneWidget);
      expect(find.text('Resend Invite'), findsNothing);
    });

    testWidgets('MFA enrolled: shows the "is on" pill', (tester) async {
      await pumpDialog(
        tester,
        user: const ManagedUser(
          uid: 'uid-1',
          email: 'jordan@example.com',
          firstName: 'Jordan',
          lastName: 'Lee',
          role: [],
          disabled: false,
          hasPassword: true,
          mfaEnrolled: true,
        ),
      );
      await open(tester);

      expect(find.text('TWO-STEP SIGN-IN ON'), findsOneWidget);
    });

    testWidgets('resending an invite shows the success message', (tester) async {
      when(() => adminService.resendInvite(any())).thenAnswer((_) async {});

      await pumpDialog(
        tester,
        user: const ManagedUser(
          uid: 'uid-1',
          email: 'jordan@example.com',
          firstName: 'Jordan',
          lastName: 'Lee',
          role: [],
          disabled: false,
          hasPassword: false,
          mfaEnrolled: false,
        ),
      );
      await open(tester);

      await tester.ensureVisible(find.text('Resend Invite'));
      await tester.tap(find.text('Resend Invite'));
      await tester.pumpAndSettle();

      verify(() => adminService.resendInvite('uid-1')).called(1);
      expect(find.text('Invite email resent.'), findsOneWidget);
    });

    testWidgets('a failed resend shows the generic message', (tester) async {
      when(() => adminService.resendInvite(any())).thenThrow(Exception('x' * 200));

      await pumpDialog(
        tester,
        user: const ManagedUser(
          uid: 'uid-1',
          email: 'jordan@example.com',
          firstName: 'Jordan',
          lastName: 'Lee',
          role: [],
          disabled: false,
          hasPassword: false,
          mfaEnrolled: false,
        ),
      );
      await open(tester);

      await tester.ensureVisible(find.text('Resend Invite'));
      await tester.tap(find.text('Resend Invite'));
      await tester.pumpAndSettle();

      expect(find.text('Failed to resend invite.'), findsOneWidget);
    });

    testWidgets('suspending requires confirmation; canceling makes no call', (tester) async {
      await pumpDialog(tester);
      await open(tester);

      await tester.ensureVisible(find.text('Suspend'));
      await tester.tap(find.text('Suspend'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      verifyNever(() => adminService.setUserDisabled(uid: any(named: 'uid'), disabled: any(named: 'disabled')));
    });

    testWidgets('confirming suspend flips the pill and shows the status message', (tester) async {
      when(() => adminService.setUserDisabled(uid: any(named: 'uid'), disabled: any(named: 'disabled'))).thenAnswer(
        (_) async {},
      );

      await pumpDialog(tester);
      await open(tester);

      await tester.ensureVisible(find.text('Suspend'));
      await tester.tap(find.text('Suspend'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Suspend').last);
      await tester.pumpAndSettle();

      verify(() => adminService.setUserDisabled(uid: 'uid-1', disabled: true)).called(1);
      expect(find.text('Account suspended.'), findsOneWidget);
      expect(find.text('SUSPENDED'), findsOneWidget);
    });

    testWidgets('reactivating skips the confirm dialog entirely', (tester) async {
      when(() => adminService.setUserDisabled(uid: any(named: 'uid'), disabled: any(named: 'disabled'))).thenAnswer(
        (_) async {},
      );

      await pumpDialog(
        tester,
        user: const ManagedUser(
          uid: 'uid-1',
          email: 'jordan@example.com',
          firstName: 'Jordan',
          lastName: 'Lee',
          role: [],
          disabled: true,
          hasPassword: true,
          mfaEnrolled: false,
        ),
      );
      await open(tester);

      await tester.ensureVisible(find.text('Reactivate'));
      await tester.tap(find.text('Reactivate'));
      await tester.pumpAndSettle();

      verify(() => adminService.setUserDisabled(uid: 'uid-1', disabled: false)).called(1);
      expect(find.text('Account reactivated.'), findsOneWidget);
    });

    testWidgets('while toggling status, the button shows a spinner in place of its icon', (tester) async {
      final completer = Completer<void>();
      when(() => adminService.setUserDisabled(uid: any(named: 'uid'), disabled: any(named: 'disabled'))).thenAnswer(
        (_) => completer.future,
      );

      await pumpDialog(tester);
      await open(tester);

      await tester.ensureVisible(find.text('Suspend'));
      await tester.tap(find.text('Suspend'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Suspend').last);
      await tester.pump();

      expect(
        find.descendant(
          of: find.widgetWithText(OutlinedButton, 'Updating…'),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );

      completer.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('a failed status toggle shows the inline error', (tester) async {
      when(() => adminService.setUserDisabled(uid: any(named: 'uid'), disabled: any(named: 'disabled'))).thenThrow(
        Exception('message: cannot suspend'),
      );

      await pumpDialog(tester);
      await open(tester);

      await tester.ensureVisible(find.text('Suspend'));
      await tester.tap(find.text('Suspend'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Suspend').last);
      await tester.pumpAndSettle();

      expect(find.textContaining('cannot suspend'), findsOneWidget);
    });

    testWidgets('resetting MFA requires confirmation; canceling makes no call', (tester) async {
      await pumpDialog(tester);
      await open(tester);

      await tester.ensureVisible(find.text('Reset Two-Step Sign-In'));
      await tester.tap(find.text('Reset Two-Step Sign-In'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      verifyNever(() => adminService.resetUserMfa(any()));
    });

    testWidgets('confirming resets MFA and flips the pill back off', (tester) async {
      when(() => adminService.resetUserMfa(any())).thenAnswer((_) async {});

      await pumpDialog(
        tester,
        user: const ManagedUser(
          uid: 'uid-1',
          email: 'jordan@example.com',
          firstName: 'Jordan',
          lastName: 'Lee',
          role: [],
          disabled: false,
          hasPassword: true,
          mfaEnrolled: true,
        ),
      );
      await open(tester);

      await tester.ensureVisible(find.text('Reset Two-Step Sign-In'));
      await tester.tap(find.text('Reset Two-Step Sign-In'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();

      verify(() => adminService.resetUserMfa('uid-1')).called(1);
      expect(find.text('Two-step sign-in reset.'), findsOneWidget);
      expect(find.text('TWO-STEP SIGN-IN NOT SET UP'), findsOneWidget);
    });

    testWidgets('a failed MFA reset shows the inline error', (tester) async {
      when(() => adminService.resetUserMfa(any())).thenThrow(Exception('message: cannot reset'));

      await pumpDialog(tester);
      await open(tester);

      await tester.ensureVisible(find.text('Reset Two-Step Sign-In'));
      await tester.tap(find.text('Reset Two-Step Sign-In'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();

      expect(find.textContaining('cannot reset'), findsOneWidget);
    });
  });

  group('danger zone', () {
    testWidgets('deleting requires confirmation; canceling makes no call and keeps the dialog open', (tester) async {
      await pumpDialog(tester);
      await open(tester);

      await tester.ensureVisible(find.text('Delete Account'));
      await tester.tap(find.text('Delete Account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      verifyNever(() => adminService.deleteUser(any()));
      expect(find.text('Edit User'), findsOneWidget);
    });

    testWidgets('confirming deletes the account, notifies onChanged, and closes the dialog', (tester) async {
      when(() => adminService.deleteUser(any())).thenAnswer((_) async {});

      await pumpDialog(tester);
      await open(tester);

      await tester.ensureVisible(find.text('Delete Account'));
      await tester.tap(find.text('Delete Account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      verify(() => adminService.deleteUser('uid-1')).called(1);
      expect(changedCount, 1);
      expect(find.text('Edit User'), findsNothing);
    });

    testWidgets('a failed delete shows the inline error and keeps the dialog open', (tester) async {
      when(() => adminService.deleteUser(any())).thenThrow(Exception('message: has active patients'));

      await pumpDialog(tester);
      await open(tester);

      await tester.ensureVisible(find.text('Delete Account'));
      await tester.tap(find.text('Delete Account'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.textContaining('has active patients'), findsOneWidget);
      expect(find.text('Edit User'), findsOneWidget);
    });
  });

  testWidgets('the Close button dismisses the dialog', (tester) async {
    await pumpDialog(tester);
    await open(tester);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    expect(find.text('Edit User'), findsNothing);
  });
}

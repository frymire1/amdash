import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../classes/organization_country.dart';
import '../services/admin_service.dart';
import '../services/organization_service.dart';
import '../widgets/admin_page.dart';
import '../widgets/hospital_management_section.dart';

/// Mirrors `organization-settings.component.ts`/`.html`: a retention
/// toggle, a country picker, and (Canadian orgs only) a Cloud KMS
/// data-residency request — all bound to the live Firestore value
/// ([ownOrganizationProvider]) rather than local optimistic state — on
/// success the listener reflects the confirmed write on its own; on
/// failure there's nothing to roll back, so no local state to revert
/// either. `retainAllData` semantics: default/missing/false → completed
/// transports (+ their emsLocations doc) are deleted 48h after
/// completion by the daily cleanup job; true → this org's completed
/// patients are skipped by that job entirely.
///
/// Also hosts hospital management ([HospitalManagementSection]) — folded
/// in here rather than kept on its own route/tab, since hospitals are an
/// org-level setting like retention, not a separate management domain the
/// way users are.
class OrganizationSettingsScreen extends ConsumerStatefulWidget {
  const OrganizationSettingsScreen({super.key});

  @override
  ConsumerState<OrganizationSettingsScreen> createState() => _OrganizationSettingsScreenState();
}

class _OrganizationSettingsScreenState extends ConsumerState<OrganizationSettingsScreen> {
  bool _saving = false;
  String? _errorMessage;

  // Local dropdown selection, prefilled once from the live org doc (see
  // _prefillCountryIfNeeded) — same pattern physician's UserSettingsScreen
  // uses for name fields, so a rebuild from the live listener doesn't
  // clobber an in-progress, not-yet-saved selection.
  bool _countryPrefilled = false;
  String? _countrySelection;
  bool _savingCountry = false;
  String? _countryMessage;
  bool _countryIsError = false;

  bool _savingCmek = false;
  String? _cmekMessage;
  bool _cmekIsError = false;

  bool _savingAuditLogging = false;
  String? _auditLoggingMessage;
  bool _auditLoggingIsError = false;

  Future<void> _setRetention(bool value) async {
    setState(() {
      _saving = true;
      _errorMessage = null;
    });
    try {
      await ref.read(adminServiceProvider).setOrganizationRetention(value);
    } catch (error) {
      if (mounted) setState(() => _errorMessage = 'Failed to save. Please try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _prefillCountryIfNeeded(Organization organization) {
    if (_countryPrefilled) return;
    _countryPrefilled = true;
    _countrySelection = organization.country;
  }

  Future<void> _saveCountry() async {
    final country = _countrySelection;
    if (country == null) return;

    setState(() {
      _savingCountry = true;
      _countryMessage = null;
    });
    try {
      await ref.read(adminServiceProvider).setOrganizationCountry(country);
      if (mounted) {
        setState(() {
          _countryMessage = 'Saved.';
          _countryIsError = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _countryMessage = 'Failed to save. Please try again.';
          _countryIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _savingCountry = false);
    }
  }

  Future<void> _setCmekRequested(bool value) async {
    setState(() {
      _savingCmek = true;
      _cmekMessage = null;
    });
    try {
      await ref.read(adminServiceProvider).setOrganizationCmekPreference(value);
    } catch (error) {
      if (mounted) {
        setState(() {
          _cmekMessage = 'Failed to save. Please try again.';
          _cmekIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _savingCmek = false);
    }
  }

  Future<void> _setAuditLoggingEnabled(bool value) async {
    setState(() {
      _savingAuditLogging = true;
      _auditLoggingMessage = null;
    });
    try {
      await ref.read(adminServiceProvider).setOrganizationAuditLogging(value);
    } catch (error) {
      if (mounted) {
        setState(() {
          _auditLoggingMessage = 'Failed to save. Please try again.';
          _auditLoggingIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _savingAuditLogging = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final organization = ref.watch(ownOrganizationProvider).valueOrNull;
    final retainAllData = organization?.retainAllData ?? false;
    if (organization != null) _prefillCountryIfNeeded(organization);
    final isCanadian = organization?.country == 'CA';
    final cmekRequested = organization?.cmekRequested ?? false;
    // Missing/never-set defaults to enabled — matches audit.ts's own
    // default, so an org that's never touched this toggle keeps getting
    // patient-record audit logging exactly as it already did before this
    // setting existed.
    final auditLoggingEnabled = organization?.auditLoggingEnabled ?? true;

    return AdminPage(
      children: [
        const Text('Organization Settings', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        AdminCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Organization Details', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _countrySelection,
                decoration: const InputDecoration(labelText: 'Country'),
                items: [
                  for (final entry in organizationCountries.entries)
                    DropdownMenuItem(value: entry.key, child: Text(entry.value)),
                ],
                onChanged: (value) => setState(() => _countrySelection = value),
              ),
              if (_countryMessage != null) FormMessage(text: _countryMessage!, isError: _countryIsError),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(
                  onPressed: _savingCountry || _countrySelection == null || organization == null ? null : _saveCountry,
                  child: _savingCountry
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Save'),
                ),
              ),
            ],
          ),
        ),
        AdminCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Data Retention', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text(
                'By default, completed transports and their location history are deleted 48 hours after '
                'completion. Turn this on to keep them indefinitely.',
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Switch(
                    value: retainAllData,
                    onChanged: _saving || organization == null ? null : _setRetention,
                  ),
                  const SizedBox(width: 8),
                  Text(retainAllData ? 'Retaining all data' : 'Auto-deleting after 48 hours'),
                  if (_saving) ...[
                    const SizedBox(width: 12),
                    const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  ],
                ],
              ),
              if (_errorMessage != null) FormMessage(text: _errorMessage!, isError: true),
            ],
          ),
        ),
        AdminCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Patient Record Audit Logging', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text(
                'Log who creates, edits, completes, or deletes a patient record, and who views a patient\'s '
                'decrypted name/healthcare number — visible on the Audit Log page. User, hospital, and '
                'organization management actions are always logged regardless of this setting.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Switch(
                    value: auditLoggingEnabled,
                    onChanged: _savingAuditLogging || organization == null ? null : _setAuditLoggingEnabled,
                  ),
                  const SizedBox(width: 8),
                  Text(auditLoggingEnabled ? 'Logging patient record actions' : 'Not logging patient record actions'),
                  if (_savingAuditLogging) ...[
                    const SizedBox(width: 12),
                    const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  ],
                ],
              ),
              if (_auditLoggingMessage != null) FormMessage(text: _auditLoggingMessage!, isError: _auditLoggingIsError),
            ],
          ),
        ),
        if (isCanadian)
          AdminCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Canadian Data Residency (Cloud KMS)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text(
                  "Encrypt this organization's patient name and healthcare number with a dedicated, "
                  "Canada-based Cloud KMS key, as a CLOUD Act / data-residency safeguard. Existing records "
                  "aren't retroactively encrypted — this applies to patients created or edited from when "
                  "it's turned on.",
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Switch(
                      value: cmekRequested,
                      onChanged: _savingCmek || organization == null ? null : _setCmekRequested,
                    ),
                    const SizedBox(width: 8),
                    Text(cmekRequested ? 'Requested' : 'Not requested'),
                    if (_savingCmek) ...[
                      const SizedBox(width: 12),
                      const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    ],
                  ],
                ),
                if (_cmekMessage != null) FormMessage(text: _cmekMessage!, isError: _cmekIsError),
              ],
            ),
          ),
        const SizedBox(height: 8),
        const Text('Hospitals', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        const HospitalManagementSection(),
      ],
    );
  }
}

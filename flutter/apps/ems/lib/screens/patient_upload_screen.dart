import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../classes/uploaded_patient.dart';
import '../services/ems_tracking_service.dart';
import '../services/patient_session_service.dart';
import '../services/patient_upload_service.dart';
import '../widgets/location_tracking_section.dart';

// Standard peripheral IV catheter gauges, largest (trauma) to smallest
// (pediatric/fragile veins) — mirrors patient-upload.component.ts's
// IV_SIZES.
const _ivSizes = ['14G', '16G', '18G', '20G', '22G', '24G'];

const _ivPlacements = [
  'Left Hand',
  'Right Hand',
  'Left Forearm',
  'Right Forearm',
  'Left Antecubital (AC)',
  'Right Antecubital (AC)',
  'External Jugular (EJ)',
  'Other',
];

const _genders = ['Male', 'Female', 'Other'];

/// Mirrors `patient-upload.component.ts`/`.html` — create/edit patient
/// form. `patientId` is null in create mode.
class PatientUploadScreen extends ConsumerStatefulWidget {
  const PatientUploadScreen({super.key, this.patientId});

  final String? patientId;

  @override
  ConsumerState<PatientUploadScreen> createState() => _PatientUploadScreenState();
}

class _PatientUploadScreenState extends ConsumerState<PatientUploadScreen> {
  final _nameController = TextEditingController();
  final _healthcareNumberController = TextEditingController();
  final _ageController = TextEditingController();
  final _heartRateController = TextEditingController();
  final _systolicController = TextEditingController();
  final _diastolicController = TextEditingController();
  final _diastolicFocusNode = FocusNode();
  final _oxygenController = TextEditingController();
  final _temperatureController = TextEditingController();
  final _respiratoryRateController = TextEditingController();
  final _gcsController = TextEditingController();
  final _treatmentController = TextEditingController();
  final _notesController = TextEditingController();

  String? _gender;
  String? _destination;
  String? _ivSize;
  String? _ivPlacement;

  double? _latitude;
  double? _longitude;

  late bool _isEditing;
  String? _editingId;
  bool _formPrefilled = false;

  bool _submitting = false;
  String? _errorMessage;

  bool _liveTrackingEnabled = true;
  bool _hasLocationError = false;
  bool _locationErrorDialogShown = false;

  @override
  void initState() {
    super.initState();
    _isEditing = widget.patientId != null;
    _editingId = widget.patientId;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _healthcareNumberController.dispose();
    _ageController.dispose();
    _heartRateController.dispose();
    _systolicController.dispose();
    _diastolicController.dispose();
    _diastolicFocusNode.dispose();
    _oxygenController.dispose();
    _temperatureController.dispose();
    _respiratoryRateController.dispose();
    _gcsController.dispose();
    _treatmentController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  // The patient list is loaded asynchronously from Firestore, so keep
  // watching until the record we're editing shows up (e.g. a direct
  // reload/deep-link into edit mode before the initial snapshot arrives).
  void _maybePrefill(List<UploadedPatient> uploadedPatients) {
    // _editingId (not widget.patientId) is the source of truth here: on a
    // fresh create, _onSubmit() flips _isEditing to true and sets
    // _editingId to the newly-created doc's id, but widget.patientId
    // itself is immutable and stays null for the lifetime of this widget
    // instance — using it here would null-check-crash on the very next
    // rebuild after a successful create.
    if (_formPrefilled || !_isEditing || _editingId == null) return;
    final uploaded = findUploadedPatient(uploadedPatients, _editingId!);
    if (uploaded == null) return;

    final patient = uploaded.patient;
    _formPrefilled = true;
    _gender = _genders.contains(patient.gender) ? patient.gender : null;
    _ageController.text = patient.age is num ? '${patient.age}' : '';
    _destination = patient.destination;
    _heartRateController.text = patient.vitals.heartRate is num ? '${patient.vitals.heartRate}' : '';
    if (isProvidedValue(patient.vitals.bloodPressure)) {
      final parts = patient.vitals.bloodPressure.split('/');
      _systolicController.text = parts[0];
      _diastolicController.text = parts.length > 1 ? parts[1] : '';
    } else {
      _systolicController.text = '';
      _diastolicController.text = '';
    }
    _oxygenController.text = patient.vitals.oxygen is num ? '${patient.vitals.oxygen}' : '';
    _temperatureController.text = patient.vitals.temperature is num ? '${patient.vitals.temperature}' : '';
    _respiratoryRateController.text = patient.vitals.respiratoryRate?.toString() ?? '';
    _gcsController.text = patient.vitals.gcs?.toString() ?? '';
    _latitude = patient.location?.latitude;
    _longitude = patient.location?.longitude;
    _ivSize = patient.ivSize;
    _ivPlacement = patient.ivPlacement;
    _treatmentController.text = patient.treatment ?? '';
    _notesController.text = patient.notes ?? '';

    // name/healthcareNumber are always pulled fresh here rather than read
    // off patient.name/patient.healthcareNumber (which may be a stale
    // cache hit, or still unresolved if nothing else on screen has
    // decrypted this patient yet) — a wrong/stale prefill on an edit form
    // headed back out to a hospital is a correctness issue, not a UX
    // nicety. Fire-and-forget; results land via setState once resolved.
    _prefillDecryptedFields(_editingId!);
  }

  Future<void> _prefillDecryptedFields(String patientId) async {
    try {
      final resolved = await ref.read(patientDecryptionServiceProvider).decryptFields([patientId]);
      final fields = resolved[patientId];
      if (mounted && fields != null) {
        setState(() {
          _nameController.text = fields.name ?? '';
          _healthcareNumberController.text = fields.healthcareNumber ?? '';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _errorMessage = "Failed to load this patient's name/healthcare number. Please try again.");
      }
    }
  }

  num? _parseNum(String text) => text.isEmpty ? null : num.tryParse(text);
  int? _parseInt(String text) => text.isEmpty ? null : int.tryParse(text);

  // Joins the two separate systolic/diastolic fields back into the single
  // "120/80" string the rest of the app (Firestore, physician's vitals
  // display) expects — matches isProvidedValue's blank check when both are
  // empty, rather than submitting a bare "/".
  String _bloodPressureValue() {
    final systolic = _systolicController.text.trim();
    final diastolic = _diastolicController.text.trim();
    if (systolic.isEmpty && diastolic.isEmpty) return '';
    return '$systolic/$diastolic';
  }

  Future<void> _showLocationPermissionDialog() async {
    if (!mounted) return;
    await showErrorDialog(
      context,
      title: 'Location permission is off',
      message:
          "This patient's location can't be shared, and live tracking won't be available, "
          'until you enable location access for AmDash EMS in Settings.',
    );
  }

  Future<void> _onSubmit() async {
    // Guards against a double-submit even if two tap events land before the
    // button's own `_submitting`-disabled rebuild has visually applied
    // (e.g. a fast real double-tap, or two dispatched-close-together
    // synthetic taps) — not just relying on the button being disabled.
    if (_submitting) return;

    final values = PatientFormValues(
      name: _nameController.text.trim(),
      gender: _gender ?? '',
      age: _parseNum(_ageController.text),
      healthcareNumber: _healthcareNumberController.text.trim(),
      destination: _destination ?? '',
      heartRate: _parseNum(_heartRateController.text),
      bloodPressure: _bloodPressureValue(),
      oxygen: _parseNum(_oxygenController.text),
      temperature: _parseNum(_temperatureController.text),
      respiratoryRate: _parseInt(_respiratoryRateController.text),
      gcs: _parseInt(_gcsController.text),
      latitude: _latitude,
      longitude: _longitude,
      ivSize: _ivSize ?? '',
      ivPlacement: _ivPlacement ?? '',
      treatment: _treatmentController.text.trim(),
      notes: _notesController.text.trim(),
    );

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    final uploadService = ref.read(patientUploadServiceProvider);
    final trackingController = ref.read(emsTrackingProvider.notifier);
    final organizationId = ref.read(userProfileProvider).valueOrNull?.organizationId;

    String id;
    try {
      final PatientSaveResult result;
      if (_editingId != null) {
        id = _editingId!;
        result = await uploadService.updatePatient(id, values);
      } else {
        result = await uploadService.uploadPatient(values, organizationId ?? '');
        id = result.id;
        // If live tracking below fails, stay on this page to retry rather
        // than navigating away — treat the patient as already-created from
        // here on so a retry updates it instead of creating a duplicate.
        _editingId = id;
        _isEditing = true;
      }
      // Seed the decrypt cache (amdash_core) with the value we already
      // know we just wrote, rather than evicting and waiting on an async
      // re-decrypt — confirmed via testing that relying on the cache
      // provider's own reactivity to repaint an already-open dashboard
      // after an edit isn't reliable (a fresh page load's decrypt-pull
      // works fine; an in-place update after returning from the edit
      // screen did not). Writing the known-correct value directly sides
      // steps that entirely, and is instant besides. Scope note: the
      // cache is per-app-instance, not shared across clients — a
      // physician tab that already had this patient cached before the
      // edit won't see the update until its own fingerprint-checked pull
      // notices this write's ciphertext (see PatientField.fingerprint).
      // The fingerprints below are the actual ciphertext this save just
      // produced, so that pull recognizes this seeded value as current
      // rather than immediately re-fetching it as "stale".
      ref.read(patientFieldCacheProvider.notifier).putAll({
        id: DecryptedPatientFields(
          name: resolveBlankField(values.name),
          healthcareNumber: resolveBlankField(values.healthcareNumber),
          nameFingerprint: result.nameFingerprint,
          healthcareNumberFingerprint: result.healthcareNumberFingerprint,
        ),
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to upload patient. Please try again.';
          _submitting = false;
        });
      }
      return;
    }

    try {
      if (_liveTrackingEnabled) {
        await trackingController.startTracking(id);
      } else {
        await trackingController.stopTracking(id);
      }
      if (mounted) context.go('/');
    } catch (error) {
      if (mounted) {
        await showErrorDialog(
          context,
          title: 'Live tracking failed',
          message:
              'The patient was saved, but live tracking could not be started. Please check that location permission is enabled, then try again from this page.',
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    _maybePrefill(ref.watch(uploadedPatientsProvider).valueOrNull ?? const []);
    final hospitalNames = ref.watch(hospitalNamesProvider);

    // No Scaffold/NavBar of its own — this screen lives inside the app's
    // ShellRoute now, which owns those.
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // NavBar (the shell's fixed appBar) has no back button
                    // by design — this screen provides its own way back to
                    // the dashboard.
                    IconButton(
                      icon: const Icon(Icons.arrow_back),
                      tooltip: 'Back',
                      onPressed: () => context.canPop() ? context.pop() : context.go('/'),
                    ),
                    Expanded(
                      child: Text(
                        _isEditing ? 'Edit Patient Information' : 'Upload Patient Information',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                      ),
                    ),
                    // Balances the leading IconButton's width so the title
                    // is actually centered, not just centered within the
                    // remaining space after it.
                    const SizedBox(width: 48),
                  ],
                ),
                const SizedBox(height: 20),
                _section('Patient Details', [
                  TextField(controller: _nameController, decoration: const InputDecoration(labelText: 'Full Name')),
                  _dropdown('Gender', _gender, _genders, (value) => setState(() => _gender = value)),
                  TextField(
                    controller: _ageController,
                    decoration: const InputDecoration(labelText: 'Age'),
                    keyboardType: TextInputType.number,
                  ),
                  TextField(
                    controller: _healthcareNumberController,
                    decoration: const InputDecoration(labelText: 'Healthcare Number'),
                  ),
                  _dropdown('Destination Hospital', _destination, hospitalNames, (value) => setState(() => _destination = value)),
                ]),
                _section('Vitals', [
                  TextField(
                    controller: _heartRateController,
                    decoration: const InputDecoration(labelText: 'Heart Rate (bpm)'),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _systolicController,
                          decoration: const InputDecoration(labelText: 'Systolic BP'),
                          keyboardType: TextInputType.number,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                          textInputAction: TextInputAction.next,
                          onSubmitted: (_) => _diastolicFocusNode.requestFocus(),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Text('/', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                      ),
                      Expanded(
                        child: TextField(
                          controller: _diastolicController,
                          focusNode: _diastolicFocusNode,
                          decoration: const InputDecoration(labelText: 'Diastolic BP'),
                          keyboardType: TextInputType.number,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        ),
                      ),
                    ],
                  ),
                  TextField(
                    controller: _oxygenController,
                    decoration: const InputDecoration(labelText: 'Oxygen (%)'),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                  TextField(
                    controller: _temperatureController,
                    decoration: const InputDecoration(labelText: 'Temperature (°C)'),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$'))],
                  ),
                  TextField(
                    controller: _respiratoryRateController,
                    decoration: const InputDecoration(labelText: 'Respiratory Rate (breaths/min)'),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                  TextField(
                    controller: _gcsController,
                    decoration: const InputDecoration(labelText: 'GCS', hintText: '3-15'),
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                ]),
                _section('IV Access', [
                  _dropdown('IV Size (Gauge)', _ivSize, _ivSizes, (value) => setState(() => _ivSize = value)),
                  _dropdown('IV Placement', _ivPlacement, _ivPlacements, (value) => setState(() => _ivPlacement = value)),
                ]),
                _section('Treatment', [
                  TextField(
                    controller: _treatmentController,
                    decoration: const InputDecoration(
                      labelText: 'Treatment / Medication Given',
                      hintText: 'IV fluids, medications administered, interventions, etc.',
                    ),
                    maxLines: 4,
                  ),
                ]),
                _section('Notes', [
                  TextField(
                    controller: _notesController,
                    decoration: const InputDecoration(labelText: 'Patient Notes', hintText: 'Observations, hazards, etc.'),
                    maxLines: 4,
                  ),
                ]),
                _section('Location', [
                  LocationTrackingSection(
                    patientId: widget.patientId,
                    initialLatitude: _latitude,
                    initialLongitude: _longitude,
                    // Mirrors the section's current values for _onSubmit to
                    // read — no setState needed, nothing in this parent's
                    // build() depends on these beyond submit time, and the
                    // section is already the one rebuilding to reflect its
                    // own status/toggle changes.
                    onChanged: (value) {
                      _latitude = value.latitude;
                      _longitude = value.longitude;
                      _liveTrackingEnabled = value.liveTrackingEnabled;
                      _hasLocationError = value.hasLocationError;
                      // Fires once, the first time the section reports an
                      // error (typically right after it mounts) — not
                      // re-shown on every 15s poll while permission stays
                      // off. This callback can run mid-build (the section
                      // reports its very first value from its own
                      // initState), so the dialog itself has to wait for
                      // the frame to finish rather than opening here
                      // directly.
                      if (_hasLocationError && !_locationErrorDialogShown) {
                        _locationErrorDialogShown = true;
                        WidgetsBinding.instance.addPostFrameCallback((_) => _showLocationPermissionDialog());
                      }
                    },
                  ),
                ]),
                if (_errorMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(_errorMessage!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const Key('patient_upload_submit'),
                    onPressed: _submitting ? null : _onSubmit,
                    child: _submitting
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(_isEditing ? 'Save Changes' : 'Upload Patient'),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      );
  }

  Widget _section(String title, List<Widget> fields) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            for (final field in fields) Padding(padding: const EdgeInsets.only(bottom: 8), child: field),
          ],
        ),
      ),
    );
  }

  Widget _dropdown(String label, String? value, List<String> options, ValueChanged<String?> onChanged) {
    final safeValue = options.contains(value) ? value : null;
    return DropdownButtonFormField<String>(
      initialValue: safeValue,
      decoration: InputDecoration(labelText: label),
      items: [for (final option in options) DropdownMenuItem(value: option, child: Text(option))],
      onChanged: onChanged,
    );
  }
}

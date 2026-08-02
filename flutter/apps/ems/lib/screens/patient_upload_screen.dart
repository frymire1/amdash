import 'package:amdash_core/amdash_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';

import '../classes/uploaded_patient.dart';
import '../services/ems_tracking_service.dart';
import '../services/patient_session_service.dart';
import '../services/patient_upload_service.dart';
import '../widgets/nav_bar.dart';

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
  final _bloodPressureController = TextEditingController();
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

  String? _locationError;
  bool _locationShared = false;
  bool _liveTrackingEnabled = true;

  @override
  void initState() {
    super.initState();
    _isEditing = widget.patientId != null;
    _editingId = widget.patientId;

    if (_isEditing) {
      _liveTrackingEnabled = ref.read(emsTrackingProvider.notifier).isTracking(widget.patientId!);
    } else {
      _useCurrentLocation();
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _healthcareNumberController.dispose();
    _ageController.dispose();
    _heartRateController.dispose();
    _bloodPressureController.dispose();
    _oxygenController.dispose();
    _temperatureController.dispose();
    _respiratoryRateController.dispose();
    _gcsController.dispose();
    _treatmentController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _useCurrentLocation() async {
    setState(() => _locationError = null);

    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 10)),
      );
      if (!mounted) return;
      setState(() {
        _latitude = position.latitude;
        _longitude = position.longitude;
        _locationShared = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _locationShared = false;
        _locationError = 'Could not get your current location. Please allow location access and try again.';
      });
    }
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
    _nameController.text = patient.name;
    _gender = _genders.contains(patient.gender) ? patient.gender : null;
    _ageController.text = patient.age is num ? '${patient.age}' : '';
    _healthcareNumberController.text = patient.healthcareNumber;
    _destination = patient.destination;
    _heartRateController.text = patient.vitals.heartRate is num ? '${patient.vitals.heartRate}' : '';
    _bloodPressureController.text = isProvidedValue(patient.vitals.bloodPressure) ? patient.vitals.bloodPressure : '';
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
    _locationShared = patient.location != null;
  }

  num? _parseNum(String text) => text.isEmpty ? null : num.tryParse(text);
  int? _parseInt(String text) => text.isEmpty ? null : int.tryParse(text);

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
      bloodPressure: _bloodPressureController.text.trim(),
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
      if (_editingId != null) {
        id = _editingId!;
        await uploadService.updatePatient(id, values);
      } else {
        id = await uploadService.uploadPatient(values, organizationId ?? '');
        // If live tracking below fails, stay on this page to retry rather
        // than navigating away — treat the patient as already-created from
        // here on so a retry updates it instead of creating a duplicate.
        _editingId = id;
        _isEditing = true;
      }
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

    return Scaffold(
      appBar: const NavBar(),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isEditing ? 'Edit Patient Information' : 'Upload Patient Information',
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
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
                  ),
                  TextField(
                    controller: _bloodPressureController,
                    decoration: const InputDecoration(labelText: 'Blood Pressure', hintText: '120/80'),
                  ),
                  TextField(
                    controller: _oxygenController,
                    decoration: const InputDecoration(labelText: 'Oxygen (%)'),
                    keyboardType: TextInputType.number,
                  ),
                  TextField(
                    controller: _temperatureController,
                    decoration: const InputDecoration(labelText: 'Temperature (°C)'),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  ),
                  TextField(
                    controller: _respiratoryRateController,
                    decoration: const InputDecoration(labelText: 'Respiratory Rate (breaths/min)'),
                    keyboardType: TextInputType.number,
                  ),
                  TextField(
                    controller: _gcsController,
                    decoration: const InputDecoration(labelText: 'GCS', hintText: '3-15'),
                    keyboardType: TextInputType.number,
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
                  if (_locationError != null)
                    Text(_locationError!, style: TextStyle(color: Theme.of(context).colorScheme.error))
                  else if (!_liveTrackingEnabled)
                    const _LocationStatus(icon: Icons.location_off, text: 'Location sharing is off')
                  else if (_locationShared)
                    _LocationStatus(icon: Icons.check_circle, text: 'Location is being shared', color: AppColors.success)
                  else
                    const _LocationStatus(icon: Icons.location_searching, text: 'Locating…'),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Live-track this patient'),
                    value: _liveTrackingEnabled,
                    onChanged: (value) => setState(() => _liveTrackingEnabled = value),
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

class _LocationStatus extends StatelessWidget {
  const _LocationStatus({required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 6),
        Text(text, style: TextStyle(color: color)),
      ],
    );
  }
}

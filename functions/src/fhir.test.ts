import { describe, expect, it } from 'vitest';
import { FhirExportPatientInput, FhirExportVitalsEntry, buildPatientFhirBundle } from './fhir';

const BASE_PATIENT: FhirExportPatientInput = {
  name: 'Jordan Smith',
  healthcareNumber: '1234567890',
  gender: 'Male',
  age: 42,
  destination: 'St. Michael\'s Hospital',
  organizationName: 'Northside EMS',
  treatment: 'IV fluids administered, oxygen via nasal cannula',
  notes: 'Patient found alert and oriented at scene.',
  ivSize: '18G',
  ivPlacement: 'Left Antecubital (AC)',
  status: 'completed',
  submittedAt: new Date('2026-08-24T20:00:00Z'),
  completedAt: new Date('2026-08-24T20:35:00Z'),
};

function resourcesOf(bundle: any, resourceType: string): any[] {
  return bundle.entry.filter((e: any) => e.resource.resourceType === resourceType).map((e: any) => e.resource);
}

describe('buildPatientFhirBundle', () => {
  it('builds a document Bundle led by a Composition, with Patient/Encounter/Organization always present', () => {
    const bundle: any = buildPatientFhirBundle(BASE_PATIENT, []);

    expect(bundle.resourceType).toBe('Bundle');
    expect(bundle.type).toBe('document');
    expect(bundle.entry[0].resource.resourceType).toBe('Composition');

    const patients = resourcesOf(bundle, 'Patient');
    expect(patients).toHaveLength(1);
    expect(patients[0].name[0].text).toBe('Jordan Smith');
    expect(patients[0].gender).toBe('male');
    expect(patients[0].identifier[0].value).toBe('1234567890');

    const encounters = resourcesOf(bundle, 'Encounter');
    expect(encounters).toHaveLength(1);
    expect(encounters[0].status).toBe('finished');
    expect(encounters[0].class.code).toBe('EMER');
    expect(encounters[0].period.start).toBe('2026-08-24T20:00:00.000Z');
    expect(encounters[0].period.end).toBe('2026-08-24T20:35:00.000Z');
    expect(encounters[0].location[0].location.display).toBe("St. Michael's Hospital");

    const organizations = resourcesOf(bundle, 'Organization');
    expect(organizations).toHaveLength(1);
    expect(organizations[0].name).toBe('Northside EMS');
  });

  it('includes an Age observation from a known age, never a fabricated birthDate', () => {
    const bundle: any = buildPatientFhirBundle(BASE_PATIENT, []);

    const patients = resourcesOf(bundle, 'Patient');
    expect(patients[0].birthDate).toBeUndefined();

    const observations = resourcesOf(bundle, 'Observation');
    const age = observations.find((o) => o.code.coding[0].code === '30525-0');
    expect(age).toBeDefined();
    expect(age.valueQuantity.value).toBe(42);
  });

  it('omits the Age observation entirely when age is the "Unknown" sentinel', () => {
    const bundle: any = buildPatientFhirBundle({ ...BASE_PATIENT, age: 'Unknown' }, []);
    const observations = resourcesOf(bundle, 'Observation');
    expect(observations.find((o) => o.code.coding[0].code === '30525-0')).toBeUndefined();
  });

  it('produces one Observation per provided vital per vitalsHistory entry, skipping unprovided ones', () => {
    const history: FhirExportVitalsEntry[] = [
      {
        heartRate: 88,
        bloodPressure: '120/80',
        oxygen: 98,
        temperature: 37.1,
        respiratoryRate: 16,
        gcs: 15,
        recordedAt: new Date('2026-08-24T20:05:00Z'),
      },
      {
        // Second reading: only heart rate changed/was re-recorded — the
        // rest are the 'Unknown' sentinel or genuinely absent, matching
        // how a real partially-filled vitalsHistory entry looks.
        heartRate: 92,
        bloodPressure: '',
        oxygen: 'Unknown',
        temperature: 'Unknown',
        recordedAt: new Date('2026-08-24T20:20:00Z'),
      },
    ];
    const bundle: any = buildPatientFhirBundle(BASE_PATIENT, history);
    const observations = resourcesOf(bundle, 'Observation');

    const heartRates = observations.filter((o) => o.code?.coding?.[0]?.code === '8867-4');
    expect(heartRates).toHaveLength(2);
    expect(heartRates.map((o) => o.valueQuantity.value)).toEqual([88, 92]);

    // Blood pressure panel (with systolic/diastolic components) only from
    // the first reading — the second's bloodPressure is blank.
    const bloodPressures = observations.filter((o) => o.code?.coding?.[0]?.code === '85354-9');
    expect(bloodPressures).toHaveLength(1);
    expect(bloodPressures[0].component[0].valueQuantity.value).toBe(120);
    expect(bloodPressures[0].component[1].valueQuantity.value).toBe(80);

    // Oxygen/temperature only from the first reading — the second's are
    // the 'Unknown' sentinel, not real values.
    expect(observations.filter((o) => o.code?.coding?.[0]?.code === '59408-5')).toHaveLength(1);
    expect(observations.filter((o) => o.code?.coding?.[0]?.code === '8310-5')).toHaveLength(1);

    // respiratoryRate/gcs are optional and only present on the first
    // reading at all.
    expect(observations.filter((o) => o.code?.coding?.[0]?.code === '9279-1')).toHaveLength(1);
    expect(observations.filter((o) => o.code?.coding?.[0]?.code === '9269-2')).toHaveLength(1);
  });

  it('references every vitals Observation (but not Age) from the Composition\'s Vital Signs section', () => {
    const history: FhirExportVitalsEntry[] = [
      { heartRate: 88, bloodPressure: '', oxygen: 'Unknown', temperature: 'Unknown', recordedAt: new Date('2026-08-24T20:05:00Z') },
    ];
    const bundle: any = buildPatientFhirBundle(BASE_PATIENT, history);
    const composition = bundle.entry[0].resource;
    const vitalsSection = composition.section.find((s: any) => s.title === 'Vital Signs');
    const observationEntries = bundle.entry.filter((e: any) => e.resource.resourceType === 'Observation');
    const ageEntry = observationEntries.find((e: any) => e.resource.code.coding[0].code === '30525-0');
    const heartRateEntry = observationEntries.find((e: any) => e.resource.code.coding[0].code === '8867-4');

    // Only the heart rate reading — age is a real Observation in the
    // bundle (see the two tests above) but not a vital sign, so it's
    // deliberately excluded from this section.
    expect(vitalsSection.entry).toHaveLength(1);
    expect(vitalsSection.entry[0].reference).toBe(heartRateEntry.fullUrl);
    expect(vitalsSection.entry.some((ref: any) => ref.reference === ageEntry.fullUrl)).toBe(false);
  });

  it('omits the Vital Signs section entirely when there is no vitals history', () => {
    const bundle: any = buildPatientFhirBundle(BASE_PATIENT, []);
    const composition = bundle.entry[0].resource;
    expect(composition.section.find((s: any) => s.title === 'Vital Signs')).toBeUndefined();
  });

  it('puts treatment/notes/IV access into a narrative section, not fabricated coded data', () => {
    const bundle: any = buildPatientFhirBundle(BASE_PATIENT, []);
    const composition = bundle.entry[0].resource;
    const section = composition.section.find((s: any) => s.title === 'Treatment & Notes');
    expect(section.text.div).toContain('IV fluids administered');
    expect(section.text.div).toContain('18G');
    expect(section.text.div).toContain('Left Antecubital (AC)');
    expect(section.text.div).toContain('alert and oriented');
    // No Procedure/coded resource was fabricated for free-text treatment.
    expect(resourcesOf(bundle, 'Procedure')).toHaveLength(0);
  });

  it('escapes narrative text so free-text EMS notes can\'t break the XHTML', () => {
    const bundle: any = buildPatientFhirBundle({ ...BASE_PATIENT, notes: 'BP <90 & falling' }, []);
    const composition = bundle.entry[0].resource;
    const section = composition.section.find((s: any) => s.title === 'Treatment & Notes');
    expect(section.text.div).toContain('BP &lt;90 &amp; falling');
    expect(section.text.div).not.toContain('BP <90 & falling');
  });

  it('references the destination hospital by display name only, not a fabricated resource', () => {
    const bundle: any = buildPatientFhirBundle(BASE_PATIENT, []);
    const encounters = resourcesOf(bundle, 'Encounter');
    expect(encounters[0].location[0].location).toEqual({ display: "St. Michael's Hospital" });
    expect(resourcesOf(bundle, 'Location')).toHaveLength(0);
  });

  it('drops Encounter.location and shows "Not recorded" when destination is the "Unknown" sentinel', () => {
    const bundle: any = buildPatientFhirBundle({ ...BASE_PATIENT, destination: 'Unknown' }, []);
    const encounters = resourcesOf(bundle, 'Encounter');
    expect(encounters[0].location).toBeUndefined();

    const composition = bundle.entry[0].resource;
    const transportSection = composition.section.find((s: any) => s.title === 'Transport');
    expect(transportSection.text.div).toContain('Not recorded');
  });

  it('marks the Encounter in-progress for a not-yet-completed patient', () => {
    const bundle: any = buildPatientFhirBundle({ ...BASE_PATIENT, status: 'active', completedAt: null }, []);
    const encounters = resourcesOf(bundle, 'Encounter');
    expect(encounters[0].status).toBe('in-progress');
    expect(encounters[0].period.end).toBeUndefined();
  });

  it('omits period entirely when both submittedAt and completedAt are null', () => {
    const bundle: any = buildPatientFhirBundle({ ...BASE_PATIENT, submittedAt: null, completedAt: null }, []);
    const encounters = resourcesOf(bundle, 'Encounter');
    expect(encounters[0].period).toBeUndefined();
  });

  it('omits Patient.identifier when healthcareNumber is the "Unknown" sentinel', () => {
    const bundle: any = buildPatientFhirBundle({ ...BASE_PATIENT, healthcareNumber: 'Unknown' }, []);
    const patients = resourcesOf(bundle, 'Patient');
    expect(patients[0].identifier).toBeUndefined();
  });

  it('maps gender to "unknown" for a value outside Male/Female/Other', () => {
    const bundle: any = buildPatientFhirBundle({ ...BASE_PATIENT, gender: 'Unknown' }, []);
    const patients = resourcesOf(bundle, 'Patient');
    expect(patients[0].gender).toBe('unknown');
  });

  it('omits effectiveDateTime on a vital Observation when the reading has no recordedAt', () => {
    const history: FhirExportVitalsEntry[] = [
      { heartRate: 88, bloodPressure: '', oxygen: 'Unknown', temperature: 'Unknown', recordedAt: null },
    ];
    const bundle: any = buildPatientFhirBundle(BASE_PATIENT, history);
    const heartRateObs = resourcesOf(bundle, 'Observation').find((o) => o.code.coding[0].code === '8867-4');
    expect(heartRateObs.effectiveDateTime).toBeUndefined();
  });

  it('omits effectiveDateTime on a blood-pressure-panel Observation with no recordedAt either', () => {
    const history: FhirExportVitalsEntry[] = [
      { heartRate: 'Unknown', bloodPressure: '120/80', oxygen: 'Unknown', temperature: 'Unknown', recordedAt: null },
    ];
    const bundle: any = buildPatientFhirBundle(BASE_PATIENT, history);
    const bpObs = resourcesOf(bundle, 'Observation').find((o) => o.code.coding[0].code === '85354-9');
    expect(bpObs.effectiveDateTime).toBeUndefined();
  });

  it('skips a heart-rate Observation entirely when the reading is the "Unknown" sentinel', () => {
    const history: FhirExportVitalsEntry[] = [
      { heartRate: 'Unknown', bloodPressure: '', oxygen: 'Unknown', temperature: 'Unknown', recordedAt: new Date() },
    ];
    const bundle: any = buildPatientFhirBundle(BASE_PATIENT, history);
    expect(resourcesOf(bundle, 'Observation').find((o) => o.code.coding[0].code === '8867-4')).toBeUndefined();
  });

  it('does not build a blood-pressure panel from a non-string reading, or one with non-numeric parts', () => {
    const history: FhirExportVitalsEntry[] = [
      { heartRate: 'Unknown', bloodPressure: 12080 /* not a string at all */, oxygen: 'Unknown', temperature: 'Unknown', recordedAt: null },
      { heartRate: 'Unknown', bloodPressure: 'abc/def' /* non-numeric parts */, oxygen: 'Unknown', temperature: 'Unknown', recordedAt: null },
    ];
    const bundle: any = buildPatientFhirBundle(BASE_PATIENT, history);
    expect(resourcesOf(bundle, 'Observation').filter((o) => o.code.coding[0].code === '85354-9')).toHaveLength(0);
  });

  it('omits the Treatment & Notes section entirely when treatment/notes/IV fields are all absent', () => {
    const bundle: any = buildPatientFhirBundle(
      { ...BASE_PATIENT, treatment: undefined, notes: undefined, ivSize: undefined, ivPlacement: undefined },
      [],
    );
    const composition = bundle.entry[0].resource;
    expect(composition.section.find((s: any) => s.title === 'Treatment & Notes')).toBeUndefined();
  });

  it('includes only the IV-access line when treatment/notes are absent but IV fields are present', () => {
    const bundle: any = buildPatientFhirBundle(
      { ...BASE_PATIENT, treatment: undefined, notes: undefined, ivSize: '18G', ivPlacement: undefined },
      [],
    );
    const composition = bundle.entry[0].resource;
    const section = composition.section.find((s: any) => s.title === 'Treatment & Notes');
    expect(section.text.div).toContain('IV access');
    expect(section.text.div).toContain('18G');
    expect(section.text.div).not.toContain('Treatment given');
    expect(section.text.div).not.toContain('Notes');
  });
});

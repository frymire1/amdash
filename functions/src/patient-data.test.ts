import { beforeEach, describe, expect, it, vi } from 'vitest';
import { fakeCallableRequest, fakeDocumentEvent, fakeDocumentUpdatedEvent } from './test-utils';

// vi.hoisted() is required (not plain top-level consts, and not a plain
// top-level class either) — see audit.test.ts's comment for why.
const {
  FakeTimestamp,
  mockOrgGet,
  mockPatientGet,
  mockPatientDelete,
  mockNewPatientId,
  mockBatchSet,
  mockBatchCommit,
  mockCollection,
  mockBatch,
  mockLocationDocRef,
  mockLocationSet,
  mockGetCallerProfile,
  mockVitalsHistoryOrderBy,
  mockVitalsHistoryGet,
  mockVitalsHistoryAdd,
  mockEncryptField,
  mockDecryptField,
  mockIsEncryptedField,
  mockLogAudit,
  mockResolveActor,
  mockBuildPatientFhirBundle,
} = vi.hoisted(() => {
  const mockNewPatientId = 'new-patient-id';
  const mockLocationSet = vi.fn();
  // A fixed sentinel object identity (not a fresh {} each call) — lets
  // tests assert "batch.set was called with *this exact* location doc
  // ref" by reference, the same way real Firestore doc refs are stable
  // objects you can compare. Also carries its own .set — onPatientUpdated's
  // reroute fix calls patientLocationRef(id).set(...) directly (not
  // through the batch), unlike uploadPatientDocument's batch.set(ref, ...).
  const mockLocationDocRef = { __ref: 'location-current-doc', set: mockLocationSet };
  // A minimal stand-in for firebase-admin's real Timestamp class — needs
  // to support `instanceof` (patient-data.ts's toDateOrNull checks
  // `value instanceof Timestamp`) and .toDate(), nothing else.
  class FakeTimestamp {
    constructor(private readonly date: Date) {}
    toDate() {
      return this.date;
    }
  }
  const mockVitalsHistoryOrderBy = vi.fn();
  const mockVitalsHistoryGet = vi.fn();
  const mockVitalsHistoryAdd = vi.fn();
  const mockPatientGet = vi.fn();
  const mockPatientDelete = vi.fn();
  const mockOrgGet = vi.fn();
  return {
    FakeTimestamp,
    mockOrgGet,
    mockPatientGet,
    mockPatientDelete,
    mockNewPatientId,
    mockBatchSet: vi.fn(),
    mockBatchCommit: vi.fn(),
    mockLocationDocRef,
    mockLocationSet,
    mockVitalsHistoryOrderBy,
    mockVitalsHistoryGet,
    mockVitalsHistoryAdd,
    // patientLocationRef/patientVitalsHistoryCollection now live directly
    // in patient-data.ts (moved from shared.ts/auth.ts in this session's
    // reorg) — they're real functions under test here, not mocked away,
    // so this Firestore mock has to support the .collection(id).collection(sub)
    // chain they actually make, not just the flatter .collection(id).get()
    // shape the other callables in this file use.
    mockCollection: vi.fn((name: string) => {
      if (name === 'organizations') return { doc: () => ({ get: mockOrgGet }) };
      if (name === 'patients') {
        return {
          doc: (id?: string) => {
            if (id === undefined) return { id: mockNewPatientId };
            return {
              get: mockPatientGet,
              delete: mockPatientDelete,
              collection: (subName: string) => {
                if (subName === 'location') return { doc: () => mockLocationDocRef };
                if (subName === 'vitalsHistory') return { orderBy: mockVitalsHistoryOrderBy, add: mockVitalsHistoryAdd };
                throw new Error(`Unexpected patient subcollection in test: ${subName}`);
              },
            };
          },
        };
      }
      throw new Error(`Unexpected collection in test: ${name}`);
    }),
    mockBatch: vi.fn(() => ({ set: mockBatchSet, commit: mockBatchCommit })),
    mockGetCallerProfile: vi.fn(),
    mockEncryptField: vi.fn(),
    mockDecryptField: vi.fn(),
    mockIsEncryptedField: vi.fn(),
    mockLogAudit: vi.fn(),
    mockResolveActor: vi.fn(),
    mockBuildPatientFhirBundle: vi.fn(),
  };
});

vi.mock('firebase-admin/firestore', () => ({
  getFirestore: () => ({ collection: mockCollection, batch: mockBatch }),
  FieldValue: { serverTimestamp: () => 'SERVER_TIMESTAMP', delete: () => 'FIELD_DELETED' },
  Timestamp: FakeTimestamp,
}));

vi.mock('./auth', () => ({
  REGION: 'northamerica-northeast2',
  getCallerProfile: mockGetCallerProfile,
}));

vi.mock('./kms', () => ({
  encryptField: mockEncryptField,
  decryptField: mockDecryptField,
  isEncryptedField: mockIsEncryptedField,
}));

vi.mock('./audit', () => ({
  logAudit: mockLogAudit,
  resolveActor: mockResolveActor,
}));

vi.mock('./fhir', () => ({
  buildPatientFhirBundle: mockBuildPatientFhirBundle,
}));

import {
  decryptPatientFields,
  deletePatientRecord,
  encryptPatientFields,
  exportPatientFhirBundle,
  onPatientCreated,
  onPatientUpdated,
  patientLocationRef,
  patientVitalsHistoryCollection,
  uploadPatientDocument,
} from './patient-data';

const EMS_PROFILE = { uid: 'ems-uid', email: 'ems@example.com', role: ['ems'], organizationId: 'org-1' };

beforeEach(() => {
  vi.resetAllMocks();
  mockVitalsHistoryOrderBy.mockReturnValue({ get: mockVitalsHistoryGet });
  mockVitalsHistoryGet.mockResolvedValue({ docs: [] });
});

describe('patientLocationRef / patientVitalsHistoryCollection', () => {
  it('resolves to patients/{id}/location/current', () => {
    const ref = patientLocationRef('patient-1');
    expect(mockCollection).toHaveBeenCalledWith('patients');
    expect(ref).toBe(mockLocationDocRef);
  });

  it('resolves to the patients/{id}/vitalsHistory collection', () => {
    const ref = patientVitalsHistoryCollection('patient-2');
    expect(mockCollection).toHaveBeenCalledWith('patients');
    expect(ref).toEqual({ orderBy: mockVitalsHistoryOrderBy, add: mockVitalsHistoryAdd });
  });
});

describe('encryptPatientFields', () => {
  it('throws permission-denied for a non-EMS caller', async () => {
    mockGetCallerProfile.mockResolvedValue({ ...EMS_PROFILE, role: ['physician'] });
    await expect(
      encryptPatientFields.run(fakeCallableRequest({ name: 'a', healthcareNumber: 'b' }, 'uid-1')),
    ).rejects.toThrow('Only EMS accounts can prepare patient fields.');
  });

  it('throws failed-precondition when the caller has no organization', async () => {
    mockGetCallerProfile.mockResolvedValue({ ...EMS_PROFILE, organizationId: undefined });
    await expect(
      encryptPatientFields.run(fakeCallableRequest({ name: 'a', healthcareNumber: 'b' }, 'uid-1')),
    ).rejects.toThrow('Your account is not part of an organization.');
  });

  it('throws invalid-argument when name/healthcareNumber are not strings', async () => {
    mockGetCallerProfile.mockResolvedValue(EMS_PROFILE);
    await expect(
      encryptPatientFields.run(fakeCallableRequest({ name: 123, healthcareNumber: 'b' } as never, 'uid-1')),
    ).rejects.toThrow('name and healthcareNumber (strings) are required.');
  });

  it('passes fields through unchanged when the organization has not requested CMEK', async () => {
    mockGetCallerProfile.mockResolvedValue(EMS_PROFILE);
    mockOrgGet.mockResolvedValue({ data: () => ({ cmekRequested: false }) });

    const result = await encryptPatientFields.run(
      fakeCallableRequest({ name: 'Jordan Smith', healthcareNumber: '123' }, 'uid-1'),
    );

    expect(result).toEqual({ name: 'Jordan Smith', healthcareNumber: '123' });
    expect(mockEncryptField).not.toHaveBeenCalled();
  });

  it('encrypts both fields when the organization has CMEK requested with a real key', async () => {
    mockGetCallerProfile.mockResolvedValue(EMS_PROFILE);
    mockOrgGet.mockResolvedValue({ data: () => ({ cmekRequested: true, kmsKeyName: 'projects/p/.../org-1' }) });
    mockEncryptField.mockImplementation(async (value: string) => ({ __enc: 1, ciphertext: `cipher(${value})` }));

    const result = await encryptPatientFields.run(
      fakeCallableRequest({ name: 'Jordan Smith', healthcareNumber: '123' }, 'uid-1'),
    );

    expect(mockEncryptField).toHaveBeenCalledWith('Jordan Smith', 'projects/p/.../org-1');
    expect(mockEncryptField).toHaveBeenCalledWith('123', 'projects/p/.../org-1');
    expect(result).toEqual({
      name: { __enc: 1, ciphertext: 'cipher(Jordan Smith)' },
      healthcareNumber: { __enc: 1, ciphertext: 'cipher(123)' },
    });
  });

  it('throws failed-precondition if CMEK is requested but no key is on record (should never happen, but fails loudly)', async () => {
    mockGetCallerProfile.mockResolvedValue(EMS_PROFILE);
    mockOrgGet.mockResolvedValue({ data: () => ({ cmekRequested: true }) });

    await expect(
      encryptPatientFields.run(fakeCallableRequest({ name: 'a', healthcareNumber: 'b' }, 'uid-1')),
    ).rejects.toThrow("encryption key isn't set up yet");
  });
});

describe('uploadPatientDocument', () => {
  const baseRequest = {
    name: 'Jordan Smith',
    healthcareNumber: '123',
    gender: 'Male',
    age: 42,
    destination: 'General Hospital',
    vitals: { heartRate: 80 },
  };

  beforeEach(() => {
    mockGetCallerProfile.mockResolvedValue(EMS_PROFILE);
    mockOrgGet.mockResolvedValue({ data: () => ({ cmekRequested: false }) });
    mockBatchCommit.mockResolvedValue(undefined);
  });

  it('throws permission-denied for a non-EMS caller', async () => {
    mockGetCallerProfile.mockResolvedValue({ ...EMS_PROFILE, role: ['physician'] });
    await expect(uploadPatientDocument.run(fakeCallableRequest(baseRequest, 'uid-1'))).rejects.toThrow(
      'Only EMS accounts can create a patient record.',
    );
  });

  it('throws invalid-argument when name/healthcareNumber/vitals are missing or the wrong shape', async () => {
    await expect(
      uploadPatientDocument.run(fakeCallableRequest({ ...baseRequest, vitals: 'not-an-object' } as never, 'uid-1')),
    ).rejects.toThrow('name, healthcareNumber, and vitals are required.');
  });

  it('throws failed-precondition when the caller has no organization', async () => {
    mockGetCallerProfile.mockResolvedValue({ ...EMS_PROFILE, organizationId: undefined });
    await expect(uploadPatientDocument.run(fakeCallableRequest(baseRequest, 'uid-1'))).rejects.toThrow(
      'Your account is not part of an organization.',
    );
  });

  it('writes the patient doc with the right defaults for falsy/missing optional fields', async () => {
    await uploadPatientDocument.run(
      fakeCallableRequest({ name: 'Jordan Smith', healthcareNumber: '123', vitals: { heartRate: 80 } }, 'uid-1'),
    );

    expect(mockBatchSet).toHaveBeenCalledWith(
      { id: mockNewPatientId },
      expect.objectContaining({
        gender: 'Unknown',
        age: 'Unknown',
        destination: 'Unknown',
        notes: '',
        organizationId: 'org-1',
        status: 'active',
        createdBy: 'ems-uid',
        updatedBy: 'ems-uid',
      }),
    );
    // Falsy-omitted optional fields shouldn't appear on the write at all.
    const written = mockBatchSet.mock.calls[0][1];
    expect(written).not.toHaveProperty('ivSize');
    expect(written).not.toHaveProperty('ivPlacement');
    expect(written).not.toHaveProperty('treatment');
  });

  it('includes ivSize/ivPlacement/treatment when actually provided, and commits the batch', async () => {
    await uploadPatientDocument.run(
      fakeCallableRequest({ ...baseRequest, ivSize: '18G', ivPlacement: 'Left AC', treatment: 'IV fluids' }, 'uid-1'),
    );

    const written = mockBatchSet.mock.calls[0][1];
    expect(written.ivSize).toBe('18G');
    expect(written.ivPlacement).toBe('Left AC');
    expect(written.treatment).toBe('IV fluids');
    expect(mockBatchCommit).toHaveBeenCalledTimes(1);
  });

  it('seeds the initial location fix when latitude/longitude are both provided', async () => {
    await uploadPatientDocument.run(fakeCallableRequest({ ...baseRequest, latitude: 43.65, longitude: -79.38 }, 'uid-1'));

    // mockLocationDocRef is the fixed sentinel patientLocationRef's own
    // (real, not mocked) implementation resolves to via the Firestore
    // mock's .collection('location').doc('current') chain — batch.set
    // being called with that exact object proves the real ref-building
    // logic ran, not just that *some* set() happened.
    expect(mockBatchSet).toHaveBeenCalledWith(
      mockLocationDocRef,
      expect.objectContaining({ patientId: mockNewPatientId, organizationId: 'org-1', active: true, latitude: 43.65, longitude: -79.38 }),
    );
  });

  it('does not seed a location fix when latitude/longitude are omitted (live tracking off)', async () => {
    await uploadPatientDocument.run(fakeCallableRequest(baseRequest, 'uid-1'));
    // Only the patient doc itself was set — one batch.set call, not two.
    expect(mockBatchSet).toHaveBeenCalledTimes(1);
  });

  it('returns the new id and the (possibly encrypted) name/healthcareNumber', async () => {
    const result = await uploadPatientDocument.run(fakeCallableRequest(baseRequest, 'uid-1'));
    expect(result).toEqual({ id: mockNewPatientId, name: 'Jordan Smith', healthcareNumber: '123' });
  });
});

describe('decryptPatientFields', () => {
  it('throws invalid-argument when patientIds is missing or empty', async () => {
    mockGetCallerProfile.mockResolvedValue({ ...EMS_PROFILE, role: ['physician'] });
    await expect(decryptPatientFields.run(fakeCallableRequest({ patientIds: [] }, 'uid-1'))).rejects.toThrow(
      'patientIds (a non-empty array) is required.',
    );
  });

  it('returns nulls (not an error) for a patient that does not exist, without revealing that distinction', async () => {
    mockGetCallerProfile.mockResolvedValue({ ...EMS_PROFILE, role: ['physician'] });
    mockPatientGet.mockResolvedValue({ exists: false, data: () => undefined });

    const result = await decryptPatientFields.run(fakeCallableRequest({ patientIds: ['missing-1'] }, 'uid-1'));

    expect(result).toEqual({ results: [{ patientId: 'missing-1', name: null, healthcareNumber: null }] });
    expect(mockLogAudit).not.toHaveBeenCalled();
  });

  it('returns nulls for a patient in a different organization (non-super-admin caller)', async () => {
    mockGetCallerProfile.mockResolvedValue({ ...EMS_PROFILE, role: ['physician'], organizationId: 'org-1' });
    mockPatientGet.mockResolvedValue({ exists: true, data: () => ({ organizationId: 'org-2', name: 'x', healthcareNumber: 'y' }) });

    const result = await decryptPatientFields.run(fakeCallableRequest({ patientIds: ['other-org-patient'] }, 'uid-1'));

    expect(result.results[0]).toEqual({ patientId: 'other-org-patient', name: null, healthcareNumber: null });
  });

  it('a super-admin can read across organizations', async () => {
    mockGetCallerProfile.mockResolvedValue({ uid: 'sa', email: 'sa@example.com', role: ['super-admin'], organizationId: undefined });
    mockPatientGet.mockResolvedValue({ exists: true, data: () => ({ organizationId: 'org-2', name: 'Plain Name', healthcareNumber: '999' }) });

    const result = await decryptPatientFields.run(fakeCallableRequest({ patientIds: ['cross-org-patient'] }, 'sa'));

    expect(result.results[0]).toEqual({ patientId: 'cross-org-patient', name: 'Plain Name', healthcareNumber: '999' });
  });

  it('resolves neither-a-string-nor-encrypted (e.g. a totally missing field) to null, not an error', async () => {
    mockGetCallerProfile.mockResolvedValue({ ...EMS_PROFILE, role: ['physician'] });
    mockPatientGet.mockResolvedValue({
      exists: true,
      data: () => ({ organizationId: 'org-1', name: undefined, healthcareNumber: 'x' }),
    });
    mockIsEncryptedField.mockReturnValue(false);

    const result = await decryptPatientFields.run(fakeCallableRequest({ patientIds: ['patient-1'] }, 'uid-1'));

    expect(result.results[0]).toEqual({ patientId: 'patient-1', name: null, healthcareNumber: 'x' });
  });

  it('resolves a plain string field directly, and an encrypted field via decryptField', async () => {
    mockGetCallerProfile.mockResolvedValue({ ...EMS_PROFILE, role: ['physician'] });
    mockPatientGet.mockResolvedValue({
      exists: true,
      data: () => ({ organizationId: 'org-1', name: 'Plain Name', healthcareNumber: { __enc: 1, ciphertext: 'c' } }),
    });
    mockIsEncryptedField.mockImplementation((v: unknown) => typeof v === 'object' && v !== null);
    mockDecryptField.mockResolvedValue('Decrypted HCN');

    const result = await decryptPatientFields.run(fakeCallableRequest({ patientIds: ['patient-1'] }, 'uid-1'));

    expect(result.results[0]).toEqual({ patientId: 'patient-1', name: 'Plain Name', healthcareNumber: 'Decrypted HCN' });
  });

  it('logs one audit entry covering only the patients actually authorized', async () => {
    mockGetCallerProfile.mockResolvedValue({ ...EMS_PROFILE, role: ['physician'], organizationId: 'org-1' });
    mockPatientGet.mockImplementation(async () => ({
      exists: true,
      data: () => ({ organizationId: 'org-1', name: 'Plain', healthcareNumber: 'x' }),
    }));

    await decryptPatientFields.run(fakeCallableRequest({ patientIds: ['patient-1', 'patient-2'] }, 'uid-1'));

    expect(mockLogAudit).toHaveBeenCalledWith(
      expect.objectContaining({
        action: 'patient.decrypt',
        details: expect.objectContaining({ patientIds: ['patient-1', 'patient-2'] }),
      }),
    );
  });
});

describe('exportPatientFhirBundle', () => {
  const completedPatientData = {
    organizationId: 'org-1',
    status: 'completed',
    name: 'Jordan Smith',
    healthcareNumber: '123',
    gender: 'Male',
    destination: 'General Hospital',
  };

  beforeEach(() => {
    mockGetCallerProfile.mockResolvedValue({ ...EMS_PROFILE, role: ['physician'] });
    mockIsEncryptedField.mockReturnValue(false);
    mockBuildPatientFhirBundle.mockReturnValue({ resourceType: 'Bundle' });
  });

  it('throws invalid-argument when patientId is missing', async () => {
    await expect(exportPatientFhirBundle.run(fakeCallableRequest({ patientId: '' }, 'uid-1'))).rejects.toThrow(
      'patientId is required.',
    );
  });

  it('throws failed-precondition when the patient record has no organization on it at all (malformed data)', async () => {
    // Only reachable by a super-admin: a non-super-admin caller would
    // already be rejected as not-found by the same-org check above this
    // one, since undefined !== the caller's own organizationId.
    mockGetCallerProfile.mockResolvedValue({ uid: 'sa', email: 'sa@example.com', role: ['super-admin'], organizationId: undefined });
    mockPatientGet.mockResolvedValue({ exists: true, data: () => ({ ...completedPatientData, organizationId: undefined }) });

    await expect(exportPatientFhirBundle.run(fakeCallableRequest({ patientId: 'p1' }, 'sa'))).rejects.toThrow(
      'This patient has no organization on record.',
    );
  });

  it('throws not-found for a patient that does not exist', async () => {
    mockPatientGet.mockResolvedValue({ exists: false, data: () => undefined });
    await expect(exportPatientFhirBundle.run(fakeCallableRequest({ patientId: 'missing' }, 'uid-1'))).rejects.toThrow(
      'No patient found with id missing.',
    );
  });

  it('throws failed-precondition when the organization has no fhirExportEnabled flag on', async () => {
    mockPatientGet.mockResolvedValue({ exists: true, data: () => completedPatientData });
    mockOrgGet.mockResolvedValue({ data: () => ({ fhirExportEnabled: false }) });

    await expect(exportPatientFhirBundle.run(fakeCallableRequest({ patientId: 'p1' }, 'uid-1'))).rejects.toThrow(
      'FHIR export is not enabled for this organization.',
    );
  });

  it('throws failed-precondition when the patient is not yet marked completed', async () => {
    mockPatientGet.mockResolvedValue({ exists: true, data: () => ({ ...completedPatientData, status: 'active' }) });
    mockOrgGet.mockResolvedValue({ data: () => ({ fhirExportEnabled: true }) });

    await expect(exportPatientFhirBundle.run(fakeCallableRequest({ patientId: 'p1' }, 'uid-1'))).rejects.toThrow(
      'must be marked complete before it can be exported',
    );
  });

  it('builds and returns the bundle, and logs a gated patient.fhirExport audit entry, on the happy path', async () => {
    mockPatientGet.mockResolvedValue({ exists: true, data: () => completedPatientData });
    mockOrgGet.mockResolvedValue({ data: () => ({ fhirExportEnabled: true, name: 'Northside EMS' }) });

    const result = await exportPatientFhirBundle.run(fakeCallableRequest({ patientId: 'p1' }, 'uid-1'));

    expect(result).toEqual({ bundle: { resourceType: 'Bundle' } });
    expect(mockBuildPatientFhirBundle).toHaveBeenCalledWith(
      expect.objectContaining({ name: 'Jordan Smith', healthcareNumber: '123', organizationName: 'Northside EMS' }),
      [],
    );
    expect(mockLogAudit).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'patient.fhirExport', organizationId: 'org-1', target: 'p1' }),
    );
  });

  it('maps vitalsHistory entries, converting Firestore Timestamps to real Dates, respiratoryRate/gcs when numeric', async () => {
    mockPatientGet.mockResolvedValue({ exists: true, data: () => completedPatientData });
    mockOrgGet.mockResolvedValue({ data: () => ({ fhirExportEnabled: true }) });
    const recordedAt = new FakeTimestamp(new Date('2026-08-24T20:00:00Z'));
    mockVitalsHistoryGet.mockResolvedValue({
      docs: [{ data: () => ({ heartRate: 88, bloodPressure: '120/80', respiratoryRate: 16, gcs: 15, recordedAt }) }],
    });

    await exportPatientFhirBundle.run(fakeCallableRequest({ patientId: 'p1' }, 'uid-1'));

    const [, vitalsHistoryArg] = mockBuildPatientFhirBundle.mock.calls[0];
    expect(vitalsHistoryArg).toEqual([
      expect.objectContaining({
        heartRate: 88,
        bloodPressure: '120/80',
        respiratoryRate: 16,
        gcs: 15,
        recordedAt: new Date('2026-08-24T20:00:00Z'),
      }),
    ]);
  });

  it('omits respiratoryRate/gcs from a history entry when they are not real numbers', async () => {
    mockPatientGet.mockResolvedValue({ exists: true, data: () => completedPatientData });
    mockOrgGet.mockResolvedValue({ data: () => ({ fhirExportEnabled: true }) });
    mockVitalsHistoryGet.mockResolvedValue({
      docs: [{ data: () => ({ heartRate: 88, bloodPressure: '120/80', respiratoryRate: 'Unknown', recordedAt: null }) }],
    });

    await exportPatientFhirBundle.run(fakeCallableRequest({ patientId: 'p1' }, 'uid-1'));

    const [, vitalsHistoryArg] = mockBuildPatientFhirBundle.mock.calls[0];
    expect(vitalsHistoryArg).toEqual([expect.objectContaining({ respiratoryRate: undefined, gcs: undefined })]);
  });

  it('falls back gender/destination to "Unknown" when they are not real strings', async () => {
    mockPatientGet.mockResolvedValue({ exists: true, data: () => ({ ...completedPatientData, gender: undefined, destination: undefined }) });
    mockOrgGet.mockResolvedValue({ data: () => ({ fhirExportEnabled: true }) });

    await exportPatientFhirBundle.run(fakeCallableRequest({ patientId: 'p1' }, 'uid-1'));

    expect(mockBuildPatientFhirBundle).toHaveBeenCalledWith(
      expect.objectContaining({ gender: 'Unknown', destination: 'Unknown' }),
      [],
    );
  });

  it('passes treatment/notes/ivSize/ivPlacement through when they are real strings on the patient doc', async () => {
    mockPatientGet.mockResolvedValue({
      exists: true,
      data: () => ({ ...completedPatientData, treatment: 'IV fluids', notes: 'Alert', ivSize: '18G', ivPlacement: 'Left AC' }),
    });
    mockOrgGet.mockResolvedValue({ data: () => ({ fhirExportEnabled: true }) });

    await exportPatientFhirBundle.run(fakeCallableRequest({ patientId: 'p1' }, 'uid-1'));

    expect(mockBuildPatientFhirBundle).toHaveBeenCalledWith(
      expect.objectContaining({ treatment: 'IV fluids', notes: 'Alert', ivSize: '18G', ivPlacement: 'Left AC' }),
      [],
    );
  });

  it('falls back name/healthcareNumber to "Unknown" when resolveField cannot resolve either one', async () => {
    mockPatientGet.mockResolvedValue({
      exists: true,
      data: () => ({ ...completedPatientData, name: undefined, healthcareNumber: undefined }),
    });
    mockOrgGet.mockResolvedValue({ data: () => ({ fhirExportEnabled: true }) });

    await exportPatientFhirBundle.run(fakeCallableRequest({ patientId: 'p1' }, 'uid-1'));

    expect(mockBuildPatientFhirBundle).toHaveBeenCalledWith(
      expect.objectContaining({ name: 'Unknown', healthcareNumber: 'Unknown' }),
      [],
    );
  });
});

describe('deletePatientRecord', () => {
  it('throws permission-denied for a non-EMS caller', async () => {
    mockGetCallerProfile.mockResolvedValue({ ...EMS_PROFILE, role: ['physician'] });
    await expect(deletePatientRecord.run(fakeCallableRequest({ patientId: 'p1' }, 'uid-1'))).rejects.toThrow(
      'Only EMS accounts can delete a patient record.',
    );
  });

  it('throws invalid-argument when patientId is missing', async () => {
    mockGetCallerProfile.mockResolvedValue(EMS_PROFILE);
    await expect(deletePatientRecord.run(fakeCallableRequest({ patientId: '' }, 'uid-1'))).rejects.toThrow(
      'patientId is required.',
    );
  });

  it('throws not-found when the patient does not exist', async () => {
    mockGetCallerProfile.mockResolvedValue(EMS_PROFILE);
    mockPatientGet.mockResolvedValue({ exists: false, data: () => undefined });
    await expect(deletePatientRecord.run(fakeCallableRequest({ patientId: 'missing' }, 'uid-1'))).rejects.toThrow(
      'No patient found with id missing.',
    );
  });

  it('throws permission-denied when the patient belongs to a different organization', async () => {
    mockGetCallerProfile.mockResolvedValue(EMS_PROFILE);
    mockPatientGet.mockResolvedValue({ exists: true, data: () => ({ organizationId: 'org-2' }) });
    await expect(deletePatientRecord.run(fakeCallableRequest({ patientId: 'p1' }, 'uid-1'))).rejects.toThrow(
      'That patient belongs to a different organization.',
    );
  });

  it('deletes and logs a patient.delete audit entry on success', async () => {
    mockGetCallerProfile.mockResolvedValue(EMS_PROFILE);
    mockPatientGet.mockResolvedValue({ exists: true, data: () => ({ organizationId: 'org-1' }) });

    const result = await deletePatientRecord.run(fakeCallableRequest({ patientId: 'p1' }, 'uid-1'));

    expect(mockPatientDelete).toHaveBeenCalledTimes(1);
    expect(mockLogAudit).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'patient.delete', organizationId: 'org-1', target: 'p1' }),
    );
    expect(result).toEqual({ deleted: true });
  });
});

describe('onPatientCreated', () => {
  beforeEach(() => {
    mockResolveActor.mockResolvedValue({ uid: 'ems-uid', email: 'ems@example.com' });
  });

  it('is a no-op when the event carries no document data', async () => {
    await onPatientCreated.run(fakeDocumentEvent(undefined, { patientId: 'p1' }) as never);
    expect(mockLogAudit).not.toHaveBeenCalled();
  });

  it('logs a patient.create audit entry and appends the initial vitals history entry', async () => {
    await onPatientCreated.run(
      fakeDocumentEvent(
        { organizationId: 'org-1', createdBy: 'ems-uid', vitals: { heartRate: 80 } },
        { patientId: 'p1' },
      ) as never,
    );

    expect(mockLogAudit).toHaveBeenCalledWith(
      expect.objectContaining({ action: 'patient.create', organizationId: 'org-1', target: 'p1' }),
    );
    expect(mockVitalsHistoryAdd).toHaveBeenCalledWith(expect.objectContaining({ heartRate: 80 }));
  });

  it('appends an empty vitals history entry when the doc somehow has no vitals object at all', async () => {
    await onPatientCreated.run(fakeDocumentEvent({ organizationId: 'org-1', createdBy: 'ems-uid' }, { patientId: 'p1' }) as never);
    expect(mockVitalsHistoryAdd).toHaveBeenCalledTimes(1);
  });

  it('logs organizationId: undefined when the doc has no (string) organizationId', async () => {
    await onPatientCreated.run(fakeDocumentEvent({ createdBy: 'ems-uid', vitals: {} }, { patientId: 'p1' }) as never);
    expect(mockLogAudit).toHaveBeenCalledWith(expect.objectContaining({ organizationId: undefined }));
  });

  it('includes respiratoryRate/gcs in the history entry when they are real numbers, and recordedBy when createdBy is a real uid string', async () => {
    await onPatientCreated.run(
      fakeDocumentEvent(
        { organizationId: 'org-1', createdBy: 'ems-uid', vitals: { heartRate: 80, respiratoryRate: 16, gcs: 15 } },
        { patientId: 'p1' },
      ) as never,
    );
    expect(mockVitalsHistoryAdd).toHaveBeenCalledWith(
      expect.objectContaining({ respiratoryRate: 16, gcs: 15, recordedBy: 'ems-uid' }),
    );
  });

  it('omits recordedBy from the history entry when createdBy is not a real uid string', async () => {
    await onPatientCreated.run(
      fakeDocumentEvent({ organizationId: 'org-1', createdBy: undefined, vitals: { heartRate: 80 } }, { patientId: 'p1' }) as never,
    );
    const written = mockVitalsHistoryAdd.mock.calls[0][0];
    expect(written).not.toHaveProperty('recordedBy');
  });
});

describe('onPatientUpdated', () => {
  beforeEach(() => {
    mockResolveActor.mockResolvedValue({ uid: 'ems-uid', email: 'ems@example.com' });
  });

  it('is a no-op when before/after data is missing', async () => {
    await onPatientUpdated.run(fakeDocumentUpdatedEvent(undefined, undefined, { patientId: 'p1' }) as never);
    expect(mockLogAudit).not.toHaveBeenCalled();
  });

  it('logs patient.update for a regular edit (no status transition to completed)', async () => {
    await onPatientUpdated.run(
      fakeDocumentUpdatedEvent(
        { status: 'active', vitals: { heartRate: 80 } },
        { status: 'active', vitals: { heartRate: 80 }, organizationId: 'org-1', updatedBy: 'ems-uid' },
        { patientId: 'p1' },
      ) as never,
    );

    expect(mockLogAudit).toHaveBeenCalledWith(expect.objectContaining({ action: 'patient.update' }));
  });

  it('logs patient.complete specifically when status transitions into completed', async () => {
    await onPatientUpdated.run(
      fakeDocumentUpdatedEvent(
        { status: 'active', vitals: {} },
        { status: 'completed', vitals: {}, organizationId: 'org-1', updatedBy: 'ems-uid' },
        { patientId: 'p1' },
      ) as never,
    );

    expect(mockLogAudit).toHaveBeenCalledWith(expect.objectContaining({ action: 'patient.complete' }));
  });

  it('does not log patient.complete for an edit that keeps status completed (already-completed record corrected)', async () => {
    await onPatientUpdated.run(
      fakeDocumentUpdatedEvent(
        { status: 'completed', vitals: {}, notes: 'old' },
        { status: 'completed', vitals: {}, notes: 'new', organizationId: 'org-1', updatedBy: 'ems-uid' },
        { patientId: 'p1' },
      ) as never,
    );

    expect(mockLogAudit).toHaveBeenCalledWith(expect.objectContaining({ action: 'patient.update' }));
  });

  it('appends a new vitals history entry only when vitals actually changed', async () => {
    await onPatientUpdated.run(
      fakeDocumentUpdatedEvent(
        { status: 'active', vitals: { heartRate: 80 } },
        { status: 'active', vitals: { heartRate: 95 }, organizationId: 'org-1', updatedBy: 'ems-uid' },
        { patientId: 'p1' },
      ) as never,
    );

    expect(mockVitalsHistoryAdd).toHaveBeenCalledWith(expect.objectContaining({ heartRate: 95 }));
  });

  it('does not append a vitals history entry for an edit that leaves vitals unchanged', async () => {
    await onPatientUpdated.run(
      fakeDocumentUpdatedEvent(
        { status: 'active', vitals: { heartRate: 80 }, notes: 'old' },
        { status: 'active', vitals: { heartRate: 80 }, notes: 'new', organizationId: 'org-1', updatedBy: 'ems-uid' },
        { patientId: 'p1' },
      ) as never,
    );

    expect(mockVitalsHistoryAdd).not.toHaveBeenCalled();
  });

  it('treats a vitals object appearing/disappearing entirely as a real change (vitalsEqual\'s !a || !b case)', async () => {
    await onPatientUpdated.run(
      fakeDocumentUpdatedEvent(
        { status: 'active' }, // no 'vitals' key at all on the before side
        { status: 'active', vitals: { heartRate: 80 }, organizationId: 'org-1', updatedBy: 'ems-uid' },
        { patientId: 'p1' },
      ) as never,
    );

    expect(mockVitalsHistoryAdd).toHaveBeenCalledWith(expect.objectContaining({ heartRate: 80 }));
  });

  it('appends an empty-vitals history entry when vitals disappears entirely between before and after', async () => {
    await onPatientUpdated.run(
      fakeDocumentUpdatedEvent(
        { status: 'active', vitals: { heartRate: 80 } },
        { status: 'active', organizationId: 'org-1', updatedBy: 'ems-uid' }, // no 'vitals' key on the after side
        { patientId: 'p1' },
      ) as never,
    );

    expect(mockVitalsHistoryAdd).toHaveBeenCalledWith(expect.not.objectContaining({ heartRate: expect.anything() }));
  });

  it('logs organizationId: undefined when the after-doc has no (string) organizationId', async () => {
    await onPatientUpdated.run(
      fakeDocumentUpdatedEvent(
        { status: 'active', vitals: {} },
        { status: 'active', vitals: {}, updatedBy: 'ems-uid' },
        { patientId: 'p1' },
      ) as never,
    );

    expect(mockLogAudit).toHaveBeenCalledWith(expect.objectContaining({ organizationId: undefined }));
  });

  describe('destination reroute', () => {
    it('clears notifiedThresholds/lastEtaCheckAt on the location doc when destination changes', async () => {
      await onPatientUpdated.run(
        fakeDocumentUpdatedEvent(
          { status: 'active', vitals: {}, destination: 'General Hospital' },
          { status: 'active', vitals: {}, destination: 'St. Michael\'s Hospital', organizationId: 'org-1', updatedBy: 'ems-uid' },
          { patientId: 'p1' },
        ) as never,
      );

      expect(mockLocationSet).toHaveBeenCalledWith(
        { notifiedThresholds: 'FIELD_DELETED', lastEtaCheckAt: 'FIELD_DELETED' },
        { merge: true },
      );
    });

    it('does nothing to the location doc when destination is unchanged', async () => {
      await onPatientUpdated.run(
        fakeDocumentUpdatedEvent(
          { status: 'active', vitals: {}, destination: 'General Hospital' },
          { status: 'active', vitals: {}, destination: 'General Hospital', organizationId: 'org-1', updatedBy: 'ems-uid' },
          { patientId: 'p1' },
        ) as never,
      );

      expect(mockLocationSet).not.toHaveBeenCalled();
    });

    it('does nothing when neither side ever had a destination (an edit unrelated to it)', async () => {
      await onPatientUpdated.run(
        fakeDocumentUpdatedEvent(
          { status: 'active', vitals: { heartRate: 80 } },
          { status: 'active', vitals: { heartRate: 95 }, organizationId: 'org-1', updatedBy: 'ems-uid' },
          { patientId: 'p1' },
        ) as never,
      );

      expect(mockLocationSet).not.toHaveBeenCalled();
    });
  });
});

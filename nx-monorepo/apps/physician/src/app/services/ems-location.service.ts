import { Injectable, effect, inject, signal } from '@angular/core';
import { Unsubscribe, collection, getFirestore, onSnapshot, query, Timestamp, where } from 'firebase/firestore';
import { getFirebaseApp } from '../firebase';
import { ActiveLocation } from '../classes/active-location';
import { UserProfileService } from '@amdash/auth';

// The EMS app publishes an update every 15s. If a device stops publishing
// (page reload, tab closed, network loss) without sending an explicit stop
// signal, its Firestore record is left stuck at active: true. Treat updates
// older than this as stale so the dot self-corrects instead of staying
// green forever.
const STALE_AFTER_MS = 35000;

@Injectable({ providedIn: 'root' })
export class EmsLocationService {
  private readonly firestore = getFirestore(getFirebaseApp());
  private readonly userProfileService = inject(UserProfileService);
  private latestActiveLocations = new Map<string, ActiveLocation>();

  readonly trackedPatientIds = signal<ReadonlySet<string>>(new Set());
  readonly activeLocations = signal<ReadonlyMap<string, ActiveLocation>>(new Map());

  private unsubscribe: Unsubscribe | undefined;

  constructor() {
    // Re-subscribes whenever the signed-in user's own profile changes —
    // the query itself depends on organizationId, which isn't known until
    // the profile has loaded.
    effect(() => {
      const organizationId = this.userProfileService.profile()?.organizationId;

      this.unsubscribe?.();
      this.unsubscribe = undefined;
      this.latestActiveLocations = new Map();

      if (!organizationId) {
        this.trackedPatientIds.set(new Set());
        this.activeLocations.set(new Map());
        return;
      }

      const activeLocationsQuery = query(
        collection(this.firestore, 'emsLocations'),
        where('organizationId', '==', organizationId),
        where('active', '==', true),
      );

      this.unsubscribe = onSnapshot(activeLocationsQuery, (snapshot) => {
        const previousLocations = this.latestActiveLocations;
        const nextLocations = new Map<string, ActiveLocation>();

        for (const docSnapshot of snapshot.docs) {
          const patientId = docSnapshot.id;
          const data = docSnapshot.data();
          const updatedAt = data['updatedAt'] as Timestamp | undefined;
          const latitude = data['latitude'] as number | undefined;
          const longitude = data['longitude'] as number | undefined;

          // Carries the previous fix forward so the physician app can
          // interpolate a smooth glide between two known points instead of
          // the marker jumping every time a new fix lands (see
          // patient-viewer.component.ts's animation loop).
          const previous = previousLocations.get(patientId);

          nextLocations.set(patientId, {
            patientId,
            updatedAtMs: updatedAt ? updatedAt.toMillis() : 0,
            latitude,
            longitude,
            previousLatitude: previous?.latitude,
            previousLongitude: previous?.longitude,
            previousUpdatedAtMs: previous?.updatedAtMs,
          });
        }

        this.latestActiveLocations = nextLocations;
        this.recomputeFreshIds();
      });
    });

    setInterval(() => this.recomputeFreshIds(), 5000);
  }

  isTracked(patientId: string | undefined): boolean {
    return !!patientId && this.trackedPatientIds().has(patientId);
  }

  activeLocation(patientId: string | undefined): ActiveLocation | undefined {
    return patientId ? this.activeLocations().get(patientId) : undefined;
  }

  private recomputeFreshIds() {
    const now = Date.now();
    const fresh = new Map(
      [...this.latestActiveLocations].filter(([, entry]) => now - entry.updatedAtMs <= STALE_AFTER_MS),
    );
    this.activeLocations.set(fresh);
    this.trackedPatientIds.set(new Set(fresh.keys()));
  }
}

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
  private latestActiveLocations: ActiveLocation[] = [];

  readonly trackedPatientIds = signal<ReadonlySet<string>>(new Set());

  private unsubscribe: Unsubscribe | undefined;

  constructor() {
    // Re-subscribes whenever the signed-in user's own profile changes —
    // the query itself depends on organizationId, which isn't known until
    // the profile has loaded.
    effect(() => {
      const organizationId = this.userProfileService.profile()?.organizationId;

      this.unsubscribe?.();
      this.unsubscribe = undefined;
      this.latestActiveLocations = [];

      if (!organizationId) {
        this.trackedPatientIds.set(new Set());
        return;
      }

      const activeLocationsQuery = query(
        collection(this.firestore, 'emsLocations'),
        where('organizationId', '==', organizationId),
        where('active', '==', true),
      );

      this.unsubscribe = onSnapshot(activeLocationsQuery, (snapshot) => {
        this.latestActiveLocations = snapshot.docs.map((docSnapshot) => {
          const updatedAt = docSnapshot.data()['updatedAt'] as Timestamp | undefined;
          return { patientId: docSnapshot.id, updatedAtMs: updatedAt ? updatedAt.toMillis() : 0 };
        });
        this.recomputeFreshIds();
      });
    });

    setInterval(() => this.recomputeFreshIds(), 5000);
  }

  isTracked(patientId: string | undefined): boolean {
    return !!patientId && this.trackedPatientIds().has(patientId);
  }

  private recomputeFreshIds() {
    const now = Date.now();
    const fresh = new Set(
      this.latestActiveLocations
        .filter((entry) => now - entry.updatedAtMs <= STALE_AFTER_MS)
        .map((entry) => entry.patientId),
    );
    this.trackedPatientIds.set(fresh);
  }
}

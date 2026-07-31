import { Injectable, signal } from '@angular/core';
import { getFunctions, httpsCallable } from 'firebase/functions';
import { getFirebaseApp } from '../firebase';
import { PublishLocationRequest } from '../classes/publish-location-request';
import { StopLocationRequest } from '../classes/stop-location-request';

const UPDATE_INTERVAL_MS = 15000;
const FUNCTIONS_REGION = 'northamerica-northeast2';
const STORAGE_KEY_PREFIX = 'amdash-ems-tracking:';

@Injectable({ providedIn: 'root' })
export class EmsTrackingService {
  private readonly functions = getFunctions(getFirebaseApp(), FUNCTIONS_REGION);
  private readonly publishLocationFn = httpsCallable<PublishLocationRequest, { published: boolean }>(
    this.functions,
    'publishEmsLocation',
  );
  private readonly stopLocationFn = httpsCallable<StopLocationRequest, { published: boolean }>(
    this.functions,
    'stopEmsLocation',
  );

  private readonly intervals = new Map<string, ReturnType<typeof setInterval>>();

  readonly trackedPatientIds = signal<ReadonlySet<string>>(new Set());
  readonly error = signal<string | null>(null);

  // This service's tracking state (the recurring interval, trackedPatientIds)
  // is otherwise pure in-memory state, wiped by anything that tears down the
  // page — a mobile browser discarding a backgrounded tab under memory
  // pressure (very common once an EMS phone's screen locks mid-transport),
  // an accidental refresh, a network blip that reloads the SPA. Without this,
  // tracking would silently stop until someone notices the toggle reverted
  // to "off" and manually turns it back on. localStorage survives a reload (it's
  // per-device, which is the right scope: "this phone is currently
  // live-tracking this patient" doesn't need to sync anywhere else), so on
  // startup this resumes every patient this browser was tracking when it was
  // last torn down, with no action needed from EMS.
  constructor() {
    for (const patientId of this.readPersistedPatientIds()) {
      this.resumeTracking(patientId);
    }
  }

  isTracking(patientId: string): boolean {
    return this.trackedPatientIds().has(patientId);
  }

  // Resolves once a publish (this call's own position fetch +
  // publishEmsLocation round trip) has actually landed, so a caller can
  // confirm live tracking really is working rather than just fired-and-forgot
  // it. Deliberately does NOT short-circuit when `isTracking(patientId)` is
  // already true: "already tracking" is only ever this tab's in-memory
  // record that a *previous* publish once succeeded, not proof tracking
  // still works now (e.g. the user could have revoked location permission
  // since). A caller like "save this patient with live-tracking still on"
  // needs a fresh confirm every time, or a permission revoked mid-session
  // would silently keep reporting success on every re-save. The recurring
  // interval publishes below stay fire-and-forget — only the triggering
  // call's own publish is awaited here.
  async startTracking(patientId: string): Promise<void> {
    if (!('geolocation' in navigator)) {
      const message = 'Geolocation is not supported by this browser.';
      this.error.set(message);
      throw new Error(message);
    }

    const alreadyTracking = this.isTracking(patientId);
    this.error.set(null);

    try {
      await this.publishCurrentPosition(patientId);
    } catch (error) {
      // Whether this was the first attempt or a re-confirm of a patient
      // already believed to be tracking, a failed publish means tracking
      // isn't actually working — don't leave a stale "tracking" state or
      // a doomed interval (permission revoked mid-session would otherwise
      // keep silently failing every 15s forever) around.
      this.deactivate(patientId);
      throw error;
    }

    if (!alreadyTracking) {
      this.activate(patientId);
    }
  }

  stopTracking(patientId: string) {
    this.deactivate(patientId);

    this.stopLocationFn({ patientId }).catch((error) => {
      console.error('Failed to stop EMS location tracking', error);
    });
  }

  // Marks a patient tracked and starts its interval immediately —
  // synchronously, before any network round trip — so a component reading
  // isTracking() right after this service is constructed (e.g. the
  // live-tracking toggle's initial state on the edit page) reflects "still
  // tracking" without waiting on a publish confirmation. If the confirming
  // publish below fails (location permission revoked while the tab was
  // gone, say), this rolls back to "not tracking" the same way
  // startTracking's own failure path does.
  private resumeTracking(patientId: string) {
    this.activate(patientId);

    this.publishCurrentPosition(patientId).catch((error) => {
      console.error('Failed to resume EMS location tracking', error);
      this.deactivate(patientId);
    });
  }

  private activate(patientId: string) {
    this.addTrackedPatient(patientId);
    this.persistTracking(patientId);
    this.intervals.set(
      patientId,
      setInterval(() => {
        this.publishCurrentPosition(patientId).catch(() => {
          // Already recorded on `error` inside publishCurrentPosition —
          // the interval just needs to not throw an unhandled rejection.
        });
      }, UPDATE_INTERVAL_MS),
    );
  }

  private deactivate(patientId: string) {
    this.clearTrackingInterval(patientId);
    this.removeTrackedPatient(patientId);
    this.clearPersistedTracking(patientId);
  }

  private clearTrackingInterval(patientId: string) {
    const intervalId = this.intervals.get(patientId);
    if (intervalId !== undefined) {
      clearInterval(intervalId);
      this.intervals.delete(patientId);
    }
  }

  private addTrackedPatient(patientId: string) {
    this.trackedPatientIds.update((ids) => new Set(ids).add(patientId));
  }

  private removeTrackedPatient(patientId: string) {
    this.trackedPatientIds.update((ids) => {
      const next = new Set(ids);
      next.delete(patientId);
      return next;
    });
  }

  // Persistence is a resume-on-reload convenience, not core to tracking
  // itself (the interval + Firestore publish work fine without it) — if
  // localStorage is unavailable or throws (disabled storage, some private
  // browsing modes), degrade to today's in-memory-only behavior rather than
  // breaking tracking altogether.
  private readPersistedPatientIds(): string[] {
    try {
      const ids: string[] = [];
      for (let i = 0; i < localStorage.length; i++) {
        const key = localStorage.key(i);
        if (key?.startsWith(STORAGE_KEY_PREFIX)) {
          ids.push(key.slice(STORAGE_KEY_PREFIX.length));
        }
      }
      return ids;
    } catch {
      return [];
    }
  }

  private persistTracking(patientId: string) {
    try {
      localStorage.setItem(STORAGE_KEY_PREFIX + patientId, '1');
    } catch {
      // See readPersistedPatientIds above.
    }
  }

  private clearPersistedTracking(patientId: string) {
    try {
      localStorage.removeItem(STORAGE_KEY_PREFIX + patientId);
    } catch {
      // See readPersistedPatientIds above.
    }
  }

  private publishCurrentPosition(patientId: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      navigator.geolocation.getCurrentPosition(
        (position) => {
          this.publishLocationFn({
            patientId,
            latitude: position.coords.latitude,
            longitude: position.coords.longitude,
          })
            .then(() => resolve())
            .catch((error) => {
              this.error.set('Failed to publish location update.');
              console.error('Failed to publish EMS location', error);
              reject(error instanceof Error ? error : new Error('Failed to publish location update.'));
            });
        },
        (error) => {
          this.error.set('Could not get current location.');
          console.error('Failed to get current position', error);
          reject(new Error('Could not get current location.'));
        },
        { enableHighAccuracy: true, timeout: 10000 },
      );
    });
  }
}

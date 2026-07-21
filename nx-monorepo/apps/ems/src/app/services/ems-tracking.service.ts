import { Injectable, signal } from '@angular/core';
import { getFunctions, httpsCallable } from 'firebase/functions';
import { getFirebaseApp } from '../firebase';
import { PublishLocationRequest } from '../classes/publish-location-request';
import { StopLocationRequest } from '../classes/stop-location-request';

const UPDATE_INTERVAL_MS = 15000;
const FUNCTIONS_REGION = 'northamerica-northeast2';

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
      this.clearTrackingInterval(patientId);
      this.removeTrackedPatient(patientId);
      throw error;
    }

    if (!alreadyTracking) {
      this.addTrackedPatient(patientId);
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
  }

  stopTracking(patientId: string) {
    this.clearTrackingInterval(patientId);
    this.removeTrackedPatient(patientId);

    this.stopLocationFn({ patientId }).catch((error) => {
      console.error('Failed to stop EMS location tracking', error);
    });
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

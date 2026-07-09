import { Injectable, signal } from '@angular/core';
import { getFunctions, httpsCallable } from 'firebase/functions';
import { getFirebaseApp } from '../firebase';

const UPDATE_INTERVAL_MS = 15000;
const FUNCTIONS_REGION = 'northamerica-northeast2';

interface PublishLocationRequest {
  patientId: string;
  latitude: number;
  longitude: number;
}

interface StopLocationRequest {
  patientId: string;
}

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

  startTracking(patientId: string) {
    if (this.isTracking(patientId)) {
      return;
    }

    if (!('geolocation' in navigator)) {
      this.error.set('Geolocation is not supported by this browser.');
      return;
    }

    this.error.set(null);
    this.addTrackedPatient(patientId);
    this.publishCurrentPosition(patientId);
    this.intervals.set(
      patientId,
      setInterval(() => this.publishCurrentPosition(patientId), UPDATE_INTERVAL_MS),
    );
  }

  stopTracking(patientId: string) {
    const intervalId = this.intervals.get(patientId);
    if (intervalId !== undefined) {
      clearInterval(intervalId);
      this.intervals.delete(patientId);
    }
    this.removeTrackedPatient(patientId);

    this.stopLocationFn({ patientId }).catch((error) => {
      console.error('Failed to stop EMS location tracking', error);
    });
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

  private publishCurrentPosition(patientId: string) {
    navigator.geolocation.getCurrentPosition(
      (position) => {
        this.publishLocationFn({
          patientId,
          latitude: position.coords.latitude,
          longitude: position.coords.longitude,
        }).catch((error) => {
          this.error.set('Failed to publish location update.');
          console.error('Failed to publish EMS location', error);
        });
      },
      (error) => {
        this.error.set('Could not get current location.');
        console.error('Failed to get current position', error);
      },
      { enableHighAccuracy: true, timeout: 10000 },
    );
  }
}

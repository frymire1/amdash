import { Injectable, inject } from '@angular/core';
import { Timestamp } from 'firebase/firestore';
import { getMessaging, getToken, isSupported } from 'firebase/messaging';
import { getFirebaseApp } from '../firebase-app';
import { UserProfileService } from './user-profile.service';

// Generated in Firebase Console (Project Settings > Cloud Messaging >
// Web Push certificates) — a public identifier, not a secret, but specific
// to this Firebase project.
const VAPID_KEY = 'BOyziwdy1IYAaRdmBO0KZlyCwrRtxPoacISCqUoJiTYPkTpgVAAlAw7ScAVqUC4uCs2JTYn7cifydpr-I1XpGlQ';

// Lives in @amdash/auth (rather than the physician app) because
// UserSettingsComponent — the only place that calls this — is itself shared
// across the physician/ems/admin apps, gated by the same physician/nurse
// role check the hospital field already uses. Only the physician app ships
// public/firebase-messaging-sw.js, so enableAlerts() below is expected to
// only actually succeed when the current origin is the physician app; it
// fails soft (returns granted: false) rather than throwing if called from
// elsewhere, which only matters for the rare multi-role account viewing
// settings from a different app's origin.
//
// Detection of "a new patient arrived" is entirely server-side (see
// functions/src/physician.ts's sendNewPatientAlerts), and *delivery* is
// entirely the service worker's job too (see firebase-messaging-sw.js's raw
// `push` listener) — nothing here needs to run on every app load. This
// service is purely for arming/disarming alerts for the current device,
// invoked on demand from the settings UI.
@Injectable({ providedIn: 'root' })
export class PatientAlertService {
  private readonly userProfileService = inject(UserProfileService);

  // Called from a real click in the settings UI (required for the browser's
  // permission-prompt rules) with the chosen 1-12h duration.
  async enableAlerts(hours: number): Promise<{ granted: boolean }> {
    // isSupported() rejects/false in environments with no service-worker or
    // Notification API (older Safari, unit tests running under jsdom) —
    // checked before ever touching getMessaging(), which throws otherwise.
    if (!(await isSupported())) {
      return { granted: false };
    }

    let registration: ServiceWorkerRegistration;
    try {
      await navigator.serviceWorker.register('/firebase-messaging-sw.js');
      // register() resolves as soon as the registration exists, not once
      // it's actually active (installing -> activating -> activated is
      // async) — subscribing via a not-yet-active registration fails with
      // "no active Service Worker", most likely on a physician's very first
      // Enable click on a given device. .ready only resolves once there's
      // an active worker for this scope.
      registration = await navigator.serviceWorker.ready;
    } catch (error) {
      console.error('Failed to register the push service worker', error);
      return { granted: false };
    }

    const permission = await Notification.requestPermission();
    if (permission !== 'granted') {
      return { granted: false };
    }

    let token: string;
    try {
      const messaging = getMessaging(getFirebaseApp());
      token = await getToken(messaging, { vapidKey: VAPID_KEY, serviceWorkerRegistration: registration });
    } catch (error) {
      // e.g. messaging/permission-blocked — the browser's actual permission
      // state can still refuse a token even after requestPermission() itself
      // resolved 'granted' (site settings changed since, or an automation
      // layer reporting a permission grant to JS that the browser process
      // itself doesn't actually honor).
      console.error('Failed to acquire a push token', error);
      return { granted: false };
    }

    const expiresAt = Timestamp.fromMillis(Date.now() + hours * 60 * 60 * 1000);
    await this.userProfileService.enableNewPatientAlerts(expiresAt, token);

    return { granted: true };
  }

  async disableAlerts(): Promise<void> {
    await this.userProfileService.disableNewPatientAlerts();
  }
}

import { Injectable, signal } from '@angular/core';
import { collection, getFirestore, onSnapshot, orderBy, query } from 'firebase/firestore';
import { getFirebaseApp, Organization } from '@amdash/auth';

// Unconstrained across every organization — only legal under
// firestore.rules for a super-admin, so only ever inject this from the
// super-admin-gated /organizations route (see app.routes.ts's
// superAdminGuard). Every other admin page stays scoped to the caller's own
// org via the Cloud Functions it calls, never a direct client query here.
@Injectable({ providedIn: 'root' })
export class OrganizationService {
  private readonly firestore = getFirestore(getFirebaseApp());

  readonly organizations = signal<Organization[]>([]);

  constructor() {
    const organizationsQuery = query(collection(this.firestore, 'organizations'), orderBy('name'));
    onSnapshot(organizationsQuery, (snapshot) => {
      this.organizations.set(
        snapshot.docs.map((docSnapshot) => ({ id: docSnapshot.id, ...(docSnapshot.data() as Omit<Organization, 'id'>) })),
      );
    });
  }
}

import { Component, OnDestroy, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { MatSlideToggleModule } from '@angular/material/slide-toggle';
import { Unsubscribe, doc, getFirestore, onSnapshot } from 'firebase/firestore';
import { getFirebaseApp, Organization, UserProfileService } from '@amdash/auth';
import { AdminService } from '../../services/admin.service';

// The one org-admin page that reads a single organizations/{orgId} doc
// directly — legal per firestore.rules' sameOrgAsCaller(orgId) get rule,
// unlike OrganizationService (super-admin-only, reads every org).
@Component({
  selector: 'app-organization-settings',
  standalone: true,
  imports: [CommonModule, MatProgressSpinnerModule, MatSlideToggleModule],
  templateUrl: './organization-settings.component.html',
  styleUrls: ['./organization-settings.component.scss'],
})
export class OrganizationSettingsComponent implements OnDestroy {
  private readonly firestore = getFirestore(getFirebaseApp());
  private readonly userProfileService = inject(UserProfileService);
  private readonly adminService = inject(AdminService);

  private unsubscribe: Unsubscribe | undefined;

  readonly organization = signal<Organization | null>(null);
  readonly saving = signal(false);
  readonly error = signal<string | null>(null);

  constructor() {
    const organizationId = this.userProfileService.profile()?.organizationId;
    if (organizationId) {
      this.unsubscribe = onSnapshot(doc(this.firestore, 'organizations', organizationId), (snapshot) => {
        this.organization.set(
          snapshot.exists() ? ({ id: snapshot.id, ...(snapshot.data() as Omit<Organization, 'id'>) }) : null,
        );
      });
    }
  }

  ngOnDestroy() {
    this.unsubscribe?.();
  }

  // The toggle's own checked state stays bound to the live Firestore value
  // (organization()?.retainAllData) rather than optimistic local state — on
  // success the listener above reflects the confirmed write on its own; on
  // failure there's nothing to roll back.
  async onToggleRetainAllData(retainAllData: boolean) {
    this.saving.set(true);
    this.error.set(null);

    try {
      await this.adminService.setOrganizationRetention(retainAllData);
    } catch (error) {
      this.error.set('Failed to update the retention setting. Please try again.');
      console.error('Failed to set organization retention', error);
    } finally {
      this.saving.set(false);
    }
  }
}

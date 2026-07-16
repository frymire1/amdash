import { Component, computed, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { APP_URLS } from '../app-urls';
import { UserProfileService } from '../services/user-profile.service';

interface AppLink {
  label: string;
  url: string;
}

@Component({
  selector: 'lib-access-denied',
  standalone: true,
  imports: [CommonModule, MatButtonModule, MatIconModule],
  templateUrl: './access-denied.component.html',
  styleUrls: ['./access-denied.component.scss'],
})
export class AccessDeniedComponent {
  private readonly userProfileService = inject(UserProfileService);

  readonly appUrls = APP_URLS;

  // Only ever links to apps this account's actual role(s) grant access to —
  // never the app it's currently locked out of (by definition, landing on
  // this page means none of its roles matched this app's guard).
  readonly matchingApps = computed<AppLink[]>(() => {
    const roles = this.userProfileService.profile()?.role ?? [];
    const links: AppLink[] = [];

    if (roles.includes('physician') || roles.includes('nurse')) {
      links.push({ label: 'Physician app', url: APP_URLS.physician });
    }
    if (roles.includes('ems')) {
      links.push({ label: 'EMS app', url: APP_URLS.ems });
    }
    if (roles.includes('admin')) {
      links.push({ label: 'Admin app', url: APP_URLS.admin });
    }

    return links;
  });
}

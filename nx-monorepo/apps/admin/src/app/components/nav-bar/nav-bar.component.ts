import { Component, inject } from '@angular/core';
import { CommonModule } from '@angular/common';
import { Router, RouterLink } from '@angular/router';
import { MatToolbarModule } from '@angular/material/toolbar';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { AuthService, UserProfileService } from '@amdash/auth';

@Component({
  selector: 'app-nav-bar',
  standalone: true,
  imports: [CommonModule, MatToolbarModule, MatButtonModule, MatIconModule, RouterLink],
  templateUrl: './nav-bar.component.html',
  styleUrls: ['./nav-bar.component.scss']
})
export class NavBarComponent {
  protected readonly authService = inject(AuthService);
  protected readonly userProfileService = inject(UserProfileService);
  private readonly router = inject(Router);

  async logOut() {
    await this.authService.signOut();
    this.router.navigateByUrl('/login');
  }
}

import { Component, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { Router, RouterLink } from '@angular/router';
import { MatToolbarModule } from '@angular/material/toolbar';
import { MatButtonModule } from '@angular/material/button';
import { MatIconModule } from '@angular/material/icon';
import { MatMenuModule } from '@angular/material/menu';
import { MatProgressSpinnerModule } from '@angular/material/progress-spinner';
import { MatSnackBar } from '@angular/material/snack-bar';
import { AuthService, UserProfileService } from '@amdash/auth';

@Component({
  selector: 'app-nav-bar',
  standalone: true,
  imports: [CommonModule, MatToolbarModule, MatButtonModule, MatIconModule, MatMenuModule, MatProgressSpinnerModule, RouterLink],
  templateUrl: './nav-bar.component.html',
  styleUrls: ['./nav-bar.component.scss']
})
export class NavBarComponent {
  protected readonly authService = inject(AuthService);
  protected readonly userProfileService = inject(UserProfileService);
  private readonly router = inject(Router);
  private readonly snackBar = inject(MatSnackBar);

  readonly loggingOut = signal(false);

  async logOut() {
    this.loggingOut.set(true);

    try {
      await this.authService.signOut();
      this.router.navigateByUrl('/login');
    } catch (error) {
      this.snackBar.open('Failed to log out. Please try again.', 'Dismiss', { duration: 5000 });
      console.error('Failed to sign out', error);
    } finally {
      this.loggingOut.set(false);
    }
  }
}

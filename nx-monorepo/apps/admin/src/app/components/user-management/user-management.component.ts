import { Component, OnInit, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormBuilder, ReactiveFormsModule, Validators } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatIconModule } from '@angular/material/icon';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { AdminService, AssignableRole } from '../../services/admin.service';

interface RoleOption {
  value: AssignableRole;
  label: string;
}

const ROLE_OPTIONS: RoleOption[] = [
  { value: 'ems', label: 'EMS' },
  { value: 'physician', label: 'Physician' },
  { value: 'nurse', label: 'Nurse' },
];

@Component({
  selector: 'app-user-management',
  standalone: true,
  imports: [
    CommonModule,
    ReactiveFormsModule,
    MatButtonModule,
    MatFormFieldModule,
    MatIconModule,
    MatInputModule,
    MatSelectModule,
  ],
  templateUrl: './user-management.component.html',
  styleUrls: ['./user-management.component.scss'],
})
export class UserManagementComponent implements OnInit {
  private readonly formBuilder = inject(FormBuilder);
  private readonly adminService = inject(AdminService);

  readonly roleOptions = ROLE_OPTIONS;
  readonly submitting = signal(false);
  readonly errorMessage = signal<string | null>(null);
  readonly successMessage = signal<string | null>(null);

  readonly users = this.adminService.users;
  readonly loadingUsers = this.adminService.loadingUsers;

  readonly roleForm = this.formBuilder.nonNullable.group({
    email: ['', [Validators.required, Validators.email]],
    role: [null as AssignableRole | null, Validators.required],
  });

  ngOnInit() {
    this.refreshUsers();
  }

  refreshUsers() {
    this.adminService.refreshUsers().catch((error) => {
      console.error('Failed to load users', error);
    });
  }

  async onSubmit() {
    if (this.roleForm.invalid) {
      this.roleForm.markAllAsTouched();
      return;
    }

    const { email, role } = this.roleForm.getRawValue();

    this.submitting.set(true);
    this.errorMessage.set(null);
    this.successMessage.set(null);

    try {
      await this.adminService.setUserRole(email, role as AssignableRole);
      this.successMessage.set(`${email} is now assigned the ${role} role.`);
      this.roleForm.reset({ email: '', role: null });
      await this.adminService.refreshUsers();
    } catch (error) {
      this.errorMessage.set(this.toErrorMessage(error));
      console.error('Failed to assign role', error);
    } finally {
      this.submitting.set(false);
    }
  }

  private toErrorMessage(error: unknown): string {
    if (error instanceof Error && error.message) {
      return error.message;
    }
    return 'Failed to assign role. Please try again.';
  }
}

import { Component, OnInit, ViewChild, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { FormBuilder, FormGroupDirective, ReactiveFormsModule, Validators } from '@angular/forms';
import { MatButtonModule } from '@angular/material/button';
import { MatFormFieldModule } from '@angular/material/form-field';
import { MatIconModule } from '@angular/material/icon';
import { MatInputModule } from '@angular/material/input';
import { MatSelectModule } from '@angular/material/select';
import { AdminService, AssignableRole, ManagedUser } from '../../services/admin.service';

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

  // FormGroup.reset() alone clears values/touched but not the *directive's*
  // own `submitted` flag, which Material's default ErrorStateMatcher also
  // checks — so a plain reset() left every required field showing red after
  // a successful submit. FormGroupDirective.resetForm() clears both.
  @ViewChild('createUserFormDirective') private readonly createUserFormDirective!: FormGroupDirective;
  @ViewChild('roleFormDirective') private readonly roleFormDirective!: FormGroupDirective;

  readonly roleOptions = ROLE_OPTIONS;
  readonly submitting = signal(false);
  readonly removingRole = signal<string | null>(null);
  readonly errorMessage = signal<string | null>(null);
  readonly successMessage = signal<string | null>(null);

  readonly creatingUser = signal(false);
  readonly createUserError = signal<string | null>(null);
  readonly createUserSuccess = signal<string | null>(null);

  readonly users = this.adminService.users;
  readonly loadingUsers = this.adminService.loadingUsers;

  readonly createUserForm = this.formBuilder.nonNullable.group({
    email: ['', [Validators.required, Validators.email]],
    firstName: ['', Validators.required],
    lastName: ['', Validators.required],
    role: [null as AssignableRole | null, Validators.required],
  });

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

  async onCreateUser() {
    if (this.createUserForm.invalid) {
      this.createUserForm.markAllAsTouched();
      return;
    }

    const { email, firstName, lastName, role } = this.createUserForm.getRawValue();

    this.creatingUser.set(true);
    this.createUserError.set(null);
    this.createUserSuccess.set(null);

    try {
      await this.adminService.createUser(email, firstName, lastName, role as AssignableRole);
      this.createUserSuccess.set(
        `${email} was created with the ${role} role. They'll set their password the next time they use "Create Account" on the login page with this same email.`,
      );
      this.createUserFormDirective.resetForm();
      await this.adminService.refreshUsers();
    } catch (error) {
      this.createUserError.set(this.toErrorMessage(error, 'Failed to create user. Please try again.'));
      console.error('Failed to create user', error);
    } finally {
      this.creatingUser.set(false);
    }
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
      this.roleFormDirective.resetForm();
      await this.adminService.refreshUsers();
    } catch (error) {
      this.errorMessage.set(this.toErrorMessage(error));
      console.error('Failed to assign role', error);
    } finally {
      this.submitting.set(false);
    }
  }

  removingRoleKey(user: ManagedUser, role: AssignableRole): string {
    return `${user.uid}:${role}`;
  }

  async removeRole(user: ManagedUser, role: AssignableRole) {
    this.removingRole.set(this.removingRoleKey(user, role));
    this.errorMessage.set(null);
    this.successMessage.set(null);

    try {
      await this.adminService.removeUserRole(user.email, role);
      this.successMessage.set(`Removed the ${role} role from ${user.email}.`);
      await this.adminService.refreshUsers();
    } catch (error) {
      this.errorMessage.set(this.toErrorMessage(error));
      console.error('Failed to remove role', error);
    } finally {
      this.removingRole.set(null);
    }
  }

  private toErrorMessage(error: unknown, fallback = 'Failed to assign role. Please try again.'): string {
    if (error instanceof Error && error.message) {
      return error.message;
    }
    return fallback;
  }
}

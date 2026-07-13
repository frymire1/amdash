import { Component, inject } from '@angular/core';
import { MatButtonModule } from '@angular/material/button';
import { MAT_DIALOG_DATA, MatDialogModule, MatDialogRef } from '@angular/material/dialog';

export interface ErrorDialogData {
  title: string;
  message: string;
}

@Component({
  selector: 'app-error-dialog',
  standalone: true,
  imports: [MatButtonModule, MatDialogModule],
  templateUrl: './error-dialog.component.html',
  styleUrls: ['./error-dialog.component.scss'],
})
export class ErrorDialogComponent {
  private readonly dialogRef = inject(MatDialogRef<ErrorDialogComponent>);

  readonly data = inject<ErrorDialogData>(MAT_DIALOG_DATA);

  onDismiss() {
    this.dialogRef.close();
  }
}

import { Component } from '@angular/core';
import { CommonModule } from '@angular/common';
import { RouterOutlet } from '@angular/router';
import { NavBarComponent } from './components/nav-bar/nav-bar.component';

@Component({
  selector: 'app-root',
  imports: [CommonModule, RouterOutlet, NavBarComponent],
  templateUrl: './app.html',
  styleUrl: './app.scss',
})
export class App {}

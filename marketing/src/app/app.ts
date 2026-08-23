import { Component, inject } from '@angular/core';
import { Meta, Title } from '@angular/platform-browser';
import { DemoShowcase } from './demo-showcase/demo-showcase';

const PAGE_TITLE = 'AmDash — Real-time EMS-to-hospital patient handoff';
const PAGE_DESCRIPTION =
  'AmDash connects EMS crews and hospital teams in real time: live vitals, GPS tracking, and ETA, from the field to the ER.';

// Runs during prerendering (see app.routes.server.ts — every route renders
// at build time), so these land in the actual static HTML served to
// crawlers and link-preview scrapers, not just the runtime DOM.
@Component({
  selector: 'app-root',
  imports: [DemoShowcase],
  templateUrl: './app.html',
  styleUrl: './app.scss',
})
export class App {
  protected readonly currentYear = new Date().getFullYear();

  constructor() {
    const title = inject(Title);
    const meta = inject(Meta);

    title.setTitle(PAGE_TITLE);
    meta.addTags([
      { name: 'description', content: PAGE_DESCRIPTION },
      { property: 'og:title', content: PAGE_TITLE },
      { property: 'og:description', content: PAGE_DESCRIPTION },
      { property: 'og:type', content: 'website' },
      { name: 'twitter:card', content: 'summary' },
      { name: 'twitter:title', content: PAGE_TITLE },
      { name: 'twitter:description', content: PAGE_DESCRIPTION },
    ]);
  }
}

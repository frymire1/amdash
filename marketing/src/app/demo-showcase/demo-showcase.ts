import { AfterViewInit, Component, ElementRef, QueryList, ViewChild, ViewChildren, signal } from '@angular/core';

interface Callout {
  yPercent: number;
  label: string;
}

interface DemoSlide {
  src: string;
  alt: string;
  eyebrow: string;
  title: string;
  caption: string;
  callouts: Callout[];
}

/// A swipeable/scrollable screenshot carousel for the "See it in action"
/// section — real screens from all three apps (mocked up with made-up demo
/// data, not live captures), each annotated with 1-2 callout markers
/// pointing at a specific capability. The only stateful/interactive piece
/// of UI on this otherwise-static site, so it gets its own component
/// rather than living inline in App.
///
/// Layout: the horizontal `.track` (native scroll-snap, so touch/trackpad
/// swipe works for free) holds only the images/callouts — the caption
/// block below is a single element bound to `slides[currentIndex()]`,
/// updating instantly rather than scrolling with the row, so it never has
/// to fight the row's own height. `.track-wrap`'s height is synced in JS
/// to the *current* slide's natural height (images vary — 6 different
/// real screens, not a uniform crop) rather than defaulting to CSS flex's
/// usual "as tall as the tallest row item" behavior, which would leave
/// visible dead space under every shorter slide.
@Component({
  selector: 'app-demo-showcase',
  templateUrl: './demo-showcase.html',
  styleUrl: './demo-showcase.scss',
})
export class DemoShowcase implements AfterViewInit {
  readonly slides: DemoSlide[] = [
    {
      src: '/demo/ems-upload.webp',
      alt: "EMS's Upload Patient Information form, filled in with a patient's details and vitals",
      eyebrow: 'In the field',
      title: 'EMS enters vitals in seconds',
      caption:
        "Patient details, vitals, treatment, and IV access — captured on scene and synced the moment it's saved.",
      callouts: [{ yPercent: 18.3, label: '🔒 Encrypted end-to-end' }],
    },
    {
      src: '/demo/ems-tracking.webp',
      alt: 'EMS Dashboard showing a patient card with a Tracking Online status pill',
      eyebrow: 'Always in sync',
      title: 'EMS stays in the loop too',
      caption: "The crew can see tracking status and update the patient's record right up until handoff.",
      callouts: [{ yPercent: 37.6, label: 'Updates live, right from the field' }],
    },
    {
      src: '/demo/physician-incoming.webp',
      alt: "Physician's incoming patient list with a tracking status pill and vitals chips",
      eyebrow: 'Instantly',
      title: "The hospital sees it the moment it's entered",
      caption: 'The receiving team sees the incoming patient in their own dashboard immediately.',
      callouts: [{ yPercent: 24.4, label: 'Appears instantly' }],
    },
    {
      src: '/demo/physician-live-map.webp',
      alt: "Physician's live map view showing a vehicle marker, hospital marker, route, ETA, and vital signs",
      eyebrow: 'Live',
      title: 'Real-time GPS tracking and ETA',
      caption:
        'A live map, a moving marker, and a continuously updating ETA — so the care team knows exactly when to be ready.',
      callouts: [
        { yPercent: 60.6, label: 'Live GPS tracking & ETA' },
        { yPercent: 18.2, label: 'Vitals update in real time' },
      ],
    },
    {
      src: '/demo/physician-alerts.webp',
      alt: "Physician's User Settings screen showing New Patient Alerts notification controls",
      eyebrow: 'Stay informed',
      title: 'Get notified the moment a patient is inbound',
      caption: 'Arm new-patient push alerts for a set window — no need to keep the app open and watching.',
      callouts: [{ yPercent: 68, label: 'Notification settings' }],
    },
    {
      src: '/demo/admin-settings.webp',
      alt: "Admin's Organization Settings screen showing security toggles and hospital management",
      eyebrow: 'Versatile admin',
      title: 'Secure, flexible, and easy to run',
      caption:
        'Opt into Cloud KMS encryption, audit logging, and data retention per organization — and add hospitals or invite your team in minutes.',
      callouts: [
        { yPercent: 34.8, label: 'Opt into additional protection' },
        { yPercent: 74.4, label: 'Add hospitals in minutes' },
      ],
    },
  ];

  readonly currentIndex = signal(0);
  // Sensible pre-image-load default — corrected via onImageLoad()/the
  // ngAfterViewInit fallback below once the current slide's real height is
  // known, so there's no visible collapse/jump on first paint either way.
  readonly trackHeight = signal(560);

  @ViewChild('track') private trackRef?: ElementRef<HTMLElement>;
  @ViewChildren('slideMedia') private slideMediaRefs?: QueryList<ElementRef<HTMLElement>>;

  ngAfterViewInit(): void {
    queueMicrotask(() => this.syncHeight());
  }

  private syncHeight(): void {
    const el = this.slideMediaRefs?.get(this.currentIndex())?.nativeElement;
    if (el && el.scrollHeight > 0) this.trackHeight.set(el.scrollHeight);
  }

  goTo(index: number): void {
    const track = this.trackRef?.nativeElement;
    const target = track?.children[index] as HTMLElement | undefined;
    target?.scrollIntoView({ behavior: 'smooth', block: 'nearest', inline: 'center' });
  }

  next(): void {
    this.goTo(Math.min(this.currentIndex() + 1, this.slides.length - 1));
  }

  prev(): void {
    this.goTo(Math.max(this.currentIndex() - 1, 0));
  }

  // Fires on both manual swipe/drag and the programmatic scrollIntoView
  // above — one code path keeps the active dot/caption in sync regardless
  // of how the user moved between slides.
  onScroll(): void {
    const track = this.trackRef?.nativeElement;
    if (!track || track.clientWidth === 0) return;
    const index = Math.round(track.scrollLeft / track.clientWidth);
    if (index !== this.currentIndex() && index >= 0 && index < this.slides.length) {
      this.currentIndex.set(index);
      this.syncHeight();
    }
  }

  onImageLoad(index: number): void {
    if (index === this.currentIndex()) this.syncHeight();
  }
}

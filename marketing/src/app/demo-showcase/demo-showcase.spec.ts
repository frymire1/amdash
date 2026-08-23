import { TestBed } from '@angular/core/testing';
import { DemoShowcase } from './demo-showcase';

describe('DemoShowcase', () => {
  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [DemoShowcase],
    }).compileComponents();
  });

  it('should create', () => {
    const fixture = TestBed.createComponent(DemoShowcase);
    expect(fixture.componentInstance).toBeTruthy();
  });

  it('should render all 6 slides', () => {
    const fixture = TestBed.createComponent(DemoShowcase);
    fixture.detectChanges();
    const compiled = fixture.nativeElement as HTMLElement;
    expect(compiled.querySelectorAll('.slide').length).toBe(6);
    expect(compiled.querySelectorAll('.dot').length).toBe(6);
  });

  it('should show the first slide\'s caption initially', () => {
    const fixture = TestBed.createComponent(DemoShowcase);
    fixture.detectChanges();
    const compiled = fixture.nativeElement as HTMLElement;
    expect(compiled.querySelector('.slide-info h3')?.textContent).toContain(
      'EMS enters vitals in seconds',
    );
  });
});

#import <XCTest/XCTest.h>

// Patrol's `patrol build ios` generates the actual test invocation code
// into this target at build time — this file only needs to exist and
// compile so the RunnerUITests target (which Patrol's iOS integration
// requires, but can't create itself — Xcode target creation isn't
// scriptable via patrol_cli) has a real starting point, mirroring what
// Xcode's own "UI Testing Bundle" template produces.
@interface RunnerUITests : XCTestCase
@end

@implementation RunnerUITests

- (void)setUp {
    self.continueAfterFailure = NO;
}

- (void)testMain {
    XCUIApplication *app = [[XCUIApplication alloc] init];
    [app launch];
}

@end

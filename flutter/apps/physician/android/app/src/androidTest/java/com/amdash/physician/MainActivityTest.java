// The Patrol Android "host" test — required native scaffolding, not
// something patrol_cli generates for you (confirmed by reading patrol_cli's
// own source: `patrol build android` only opt-in-codegens per-test JUnit
// methods on TOP of a host class that already exists here; with no host
// class, the compiled androidTest APK has nothing to discover at all). Its
// absence here (this file, and the equivalent Gradle wiring in
// android/app/build.gradle.kts, never existed until now) is why Firebase
// Test Lab's Android e2e job had been reporting a false-positive green —
// `am instrument` genuinely ran and genuinely found zero @Test methods
// ("OK (0 tests)"), which gcloud/GHA both surface as success. Confirmed via
// direct APK decompilation: the generated androidTest APK contained only
// the auto-generated R resource class. See Patrol's own setup doc:
// https://patrol.leancode.co/documentation#android-setup
package com.amdash.physician;

import androidx.test.platform.app.InstrumentationRegistry;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.junit.runners.Parameterized;
import org.junit.runners.Parameterized.Parameters;
import pl.leancode.patrol.PatrolJUnitRunner;

@RunWith(Parameterized.class)
public class MainActivityTest {
    @Parameters(name = "{0}")
    public static Object[] testCases() {
        PatrolJUnitRunner instrumentation = (PatrolJUnitRunner) InstrumentationRegistry.getInstrumentation();
        instrumentation.setUp(MainActivity.class);
        instrumentation.waitForPatrolAppService();
        return instrumentation.listDartTests();
    }

    public MainActivityTest(String dartTestName) {
        this.dartTestName = dartTestName;
    }

    private final String dartTestName;

    @Test
    public void runDartTest() {
        PatrolJUnitRunner instrumentation = (PatrolJUnitRunner) InstrumentationRegistry.getInstrumentation();
        instrumentation.runDartTest(dartTestName);
    }
}

import java.util.Properties
import java.io.FileInputStream

plugins {
    // AGP 9+ ships built-in Kotlin support — the standalone
    // `org.jetbrains.kotlin.android` plugin must NOT be applied alongside
    // it (KGP 2.2.20 fails fast with a clear error if you do).
    // See https://issuetracker.google.com/438678642
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.ksp)
}

android {
    namespace = "com.jarvis.assistant"
    // compileSdk 35 (Android 15) — pulled forward by AndroidX
    // transitives that arrived with the Meta DAT SDK chain
    // (androidx.core 1.16, activity 1.10, compose 1.9, lifecycle
    // 2.9.4 all require minCompileSdk 35).  compileSdk is the API
    // level we compile *against*; runtime behavior is still gated by
    // targetSdk + minSdk, which are deliberately left alone here so
    // this commit is a build-pipeline change only.  Was 34; bumped
    // 2026-05-15.
    compileSdk = 35

    defaultConfig {
        applicationId = "com.jarvis.assistant"
        // minSdk 29 (Android 10) — the Meta Wearables DAT SDK requires
        // it, and Android 10+ has very wide install coverage at this
        // point (released 2019).  Was 26; bumped 2026-05-15 when the
        // SDK landed.  If the wearables feature is later moved into
        // an optional separate module, this can drop back to 26 for
        // the core APK.
        minSdk = 29
        // targetSdk tracks compileSdk (35). Play requires targetSdk >= 35 for
        // updates; running below it hid Android 15 behaviour (FGS timeouts,
        // edge-to-edge enforcement, exact-alarm changes) behind compat mode.
        // Bumped 34 -> 35 2026-06-04. Re-validate FGS start ladder + insets on
        // an API-35 device.
        targetSdk = 35
        versionCode = 1
        versionName = "1.0.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables {
            useSupportLibrary = true
        }

        // ── Meta Wearables DAT — Application ID + Client Token ────────────
        // Loaded from local.properties (gitignored) so the token never
        // lands in the public repo.  The keys are:
        //   meta.wearables.applicationId=<numeric id from Meta dev console>
        //   meta.wearables.clientToken=AR|<id>|<token>
        // If unset, both fall back to an empty string and the manifest
        // entries are still present but inert — Meta's SDK falls back to
        // Developer Mode (per their docs: "Do not set it if you are using
        // Developer Mode to test your integration").
        val metaProps = Properties().apply {
            val f = rootProject.file("local.properties")
            if (f.exists()) FileInputStream(f).use { load(it) }
        }
        manifestPlaceholders["metaWearablesApplicationId"] =
            metaProps.getProperty("meta.wearables.applicationId", "")
        manifestPlaceholders["metaWearablesClientToken"] =
            metaProps.getProperty("meta.wearables.clientToken", "")
    }

    // Tier-A: let JVM unit tests return default values from un-mocked
    // android.* APIs (e.g. android.util.Log) instead of throwing
    // RuntimeException("not mocked").  Without this any pure-JVM test that
    // touches Log.d via production code crashes.  This is the modern Android
    // best practice and reduces the pre-existing failure count.
    testOptions {
        unitTests.isReturnDefaultValues = true
        // Robolectric needs the merged Android resources/assets on the unit-test
        // classpath (JarvisDatabaseMigrationTest reads the exported Room schemas
        // as test assets).
        unitTests.isIncludeAndroidResources = true
        unitTests.all {
            // Force UTF-8 in the JVM that runs unit tests so that Kotlin's
            // incremental compilation can handle Unicode characters in test
            // names (e.g. em-dashes in backtick test names).
            it.jvmArgs("-Dfile.encoding=UTF-8", "-Duser.language=en", "-Duser.country=US")
        }
    }


    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
        debug {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        // Generates com.jarvis.assistant.BuildConfig (VERSION_NAME/CODE, DEBUG).
        // AGP 8+/9 no longer generates it by default; AboutHelpSettingsScreen +
        // CrashReportBuilder reference it, and the diagnostic bundle needs it.
        buildConfig = true
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }

    sourceSets {
        // Exported Room schemas (app/schemas/) are unit-test classpath
        // resources so JarvisDatabaseMigrationTest can rebuild historical
        // database versions and validate the real migration chain.
        // (Robolectric only sees app assets, not test-sourceSet assets,
        // so classpath resources are the reliable channel.)
        getByName("test").resources.srcDir("$projectDir/schemas")
        // Instrumented tests get them as assets for MigrationTestHelper.
        getByName("androidTest").assets.srcDir("$projectDir/schemas")
        // The shared cross-device protocol contract (ws-frame-examples.json)
        // is a test resource so BrainProtocolConformanceTest exercises the
        // exact same examples the daemon's conformance tests use.
        getByName("test").resources.srcDir(rootProject.file("../shared/contracts"))
    }
}

// Room: export the schema JSON for every @Database version into app/schemas/.
// The generated files are committed — they are the ground truth the migration
// tests validate against.
ksp {
    arg("room.schemaLocation", "$projectDir/schemas")
}

// AGP 9's built-in Kotlin support exposes the Kotlin DSL at the top level
// (the old `android { kotlinOptions { … } }` form went away with the
// standalone `org.jetbrains.kotlin.android` plugin).  Pin the JVM target
// to 17 so it matches `compileOptions` above.
kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.activity.compose)

    // Compose BOM — all compose versions come from here
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.ui.graphics)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons)
    implementation(libs.compose.animation)
    debugImplementation(libs.compose.ui.tooling)

    // Navigation
    implementation(libs.navigation.compose)

    // Encrypted storage
    implementation(libs.security.crypto)

    // Biometric + device-credential prompt for the app-level lock (Phase 4b)
    implementation(libs.androidx.biometric)

    // Coroutines
    implementation(libs.kotlinx.coroutines.android)

    // Networking (for LLM API calls).  OkHttp + Gson only — NetworkClient builds
    // requests against OkHttp directly, so Retrofit and the logging-interceptor
    // are intentionally absent (kept the APK ~1.2 MB smaller and avoids the
    // interceptor accidentally leaking bodies into logcat).
    implementation(libs.okhttp)
    implementation(libs.gson)

    // LeakCanary — debug-only memory leak detector. Not packaged into release.
    debugImplementation(libs.leakcanary.android)

    // Runtime permission handling in Compose
    implementation(libs.accompanist.permissions)

    // LocalBroadcastManager (removed from core-ktx, now a standalone artifact)
    implementation(libs.localbroadcastmanager)

    // Google Play Services — Geofencing for location-aware reminders
    implementation("com.google.android.gms:play-services-location:21.3.0")

    // Room — persistent memory + conversation history
    implementation(libs.room.runtime)
    implementation(libs.room.ktx)
    ksp(libs.room.compiler)

    // TensorFlow Lite — neural speaker embedding engine
    // Place speaker_encoder.tflite in app/src/main/assets/ to activate.
    implementation("org.tensorflow:tensorflow-lite:2.14.0")
    implementation("org.tensorflow:tensorflow-lite-support:0.4.4")

    // ONNX Runtime Android — Piper voice synthesis (optional, opt-in).
    // Place model files in app/src/main/assets/voices/ to activate; without
    // them PiperVoiceManager.isReady() returns false and Android system TTS
    // is used.  Bundle size impact ~6-8 MB.
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.18.0")

    // OPTIONAL phonemizer upgrade path.  The bundled SherpaPiperPhonemizer
    // is a pure-Kotlin English G2P — good for common vocabulary, weaker on
    // rare words.  For production-grade phoneme quality, uncomment ONE of
    // the lines below and update SherpaPiperPhonemizer (or write a new
    // PiperPhonemizer impl) to call into it.
    //
    //  - sherpa-onnx ships OfflineTts (end-to-end TTS) plus a phonemizer
    //    bundle; depending on your needs you may use it instead of the
    //    existing PiperOnnxSession path, or just lift its phonemizer.
    //    https://github.com/k2-fsa/sherpa-onnx — coordinates published via
    //    JitPack: see project README for the exact version string.
    //
    //  - espeak-ng-android (community JNI port) gives the same phonemes
    //    mainline Piper was trained against.  Bundle size impact ~3 MB
    //    plus per-language data files (~2 MB for en_GB).
    //
    // No dependency is added here — keeping the APK lean until the user
    // explicitly opts into higher-fidelity phonemisation.

    // Baseline Profile installer — installs compiled profile on first launch
    implementation("androidx.profileinstaller:profileinstaller:1.3.1")

    // CameraX — headless still-image capture from foreground service (no Activity needed)
    // camera-camera2 provides the Camera2 implementation; camera-lifecycle provides
    // ProcessCameraProvider + bindToLifecycle (used with ServiceLifecycleOwner).
    implementation("androidx.camera:camera-core:1.4.0")
    implementation("androidx.camera:camera-camera2:1.4.0")
    implementation("androidx.camera:camera-lifecycle:1.4.0")
    // CameraX view widget — PreviewView used by the Mac Bridge QR scanner
    implementation("androidx.camera:camera-view:1.4.0")

    // ML Kit Barcode Scanning — QR code parsing for Mac Bridge pairing
    implementation("com.google.mlkit:barcode-scanning:17.3.0")

    // Firebase — optional cloud sync. Initialised at RUNTIME via FirebaseOptions
    // read from SettingsStore, so the google-services plugin is NOT applied and
    // google-services.json is NOT required at build time. Users who never sign
    // in pay for the dependency footprint only (~1.5 MB).
    implementation(platform("com.google.firebase:firebase-bom:33.5.1"))
    implementation("com.google.firebase:firebase-auth-ktx")
    implementation("com.google.firebase:firebase-firestore-ktx")
    // Bridges Firebase Task<T> → coroutine .await()
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.8.1")

    // Unit tests
    testImplementation(libs.junit)
    testImplementation(libs.mockito.kotlin)
    testImplementation(libs.kotlinx.coroutines.test)
    testImplementation(libs.androidx.test.core)
    // org.json is provided by the Android platform at runtime but absent on
    // the JVM unit-test classpath. Pull it in so tests that round-trip JSON
    // (e.g. ScreenObservationRepositoryTest) don't hit "Method not mocked".
    testImplementation("org.json:json:20240303")
    // Room migration verification — MigrationTestHelper runs on the JVM under
    // Robolectric against the exported schemas in app/schemas/.
    testImplementation(libs.room.testing)
    testImplementation(libs.robolectric)

    // Instrumented tests
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.core)

    // ── Meta Wearables DAT (optional, gated on github_token) ──────────────
    // The dependency resolves only when settings.gradle.kts registered the
    // GitHub Packages repo (i.e. a token was found in local.properties or
    // the GITHUB_TOKEN env var).  Without a token the deps simply aren't
    // declared — the StubMetaWearablesProvider stays the active backend
    // and Jarvis still builds.  See docs/wearables/meta-dat-integration.md.
    val mwdatTokenPresent = (System.getenv("GITHUB_TOKEN")?.isNotBlank() == true) ||
        run {
            val f = rootProject.file("local.properties")
            f.exists() && Properties().apply { FileInputStream(f).use { load(it) } }
                .getProperty("github_token")?.isNotBlank() == true
        }
    if (mwdatTokenPresent) {
        implementation(libs.mwdat.core)
        implementation(libs.mwdat.camera)
        debugImplementation(libs.mwdat.mockdevice)
    }
}

// ── Meta Wearables DAT — conditional source set ─────────────────────────
// `app/src/mwdat/java/` holds RealMetaWearablesProvider which directly
// imports `com.meta.wearable.mwdat.*` types.  Those types only resolve
// when the SDK is on the classpath, which requires `github_token` in
// local.properties.  We include the directory only in that case so a
// fresh clone without a token still compiles cleanly — the stub stays
// active, the rest of the app is unchanged.
val mwdatSrcEnabled: Boolean = (System.getenv("GITHUB_TOKEN")?.isNotBlank() == true) ||
    run {
        val f = rootProject.file("local.properties")
        f.exists() && Properties().apply { FileInputStream(f).use { load(it) } }
            .getProperty("github_token")?.isNotBlank() == true
    }
if (mwdatSrcEnabled) {
    // AGP 9 + Kotlin 2.2: a Kotlin Android source set exposes BOTH
    // a `java` and a `kotlin` SourceDirectorySet on the same
    // AndroidSourceSet.  `java.srcDir(...)` alone does NOT pull in
    // .kt files — those need `kotlin.srcDir(...)` registered on the
    // same source set.  This was a silent failure in the first wiring
    // commit — the file compiled to nothing, the SDK was bundled but
    // never referenced, and the runtime probe correctly reported
    // SDK_UNAVAILABLE.
    val mwdatSrcPath = "src/mwdat/java"
    android.sourceSets.named("main").configure {
        java.srcDir(mwdatSrcPath)
        kotlin.srcDir(mwdatSrcPath)
    }
    logger.lifecycle("[META_WEARABLES] Including $mwdatSrcPath in main source set " +
        "(java + kotlin) — github_token present → DAT SDK available.")
}

/**
 * Architecture invariants — runs the pure-JVM source scanner under
 * `ArchitectureInvariantsTest`.  See
 * `docs/architecture/routing-invariants.md` for the rules and
 * `app/src/test/java/com/jarvis/assistant/architecture/` for the
 * enforcement code.
 *
 * Wired to `check` so a normal CI run picks it up too.  Run on its
 * own with:
 *   ./gradlew :app:checkArchitectureInvariants
 */
tasks.register("checkArchitectureInvariants") {
    group       = "verification"
    description = "Enforce routing + extraction invariants (see docs/architecture/routing-invariants.md)."
    dependsOn(tasks.named("testDebugUnitTest"))
    doLast {
        logger.lifecycle("✓ Architecture invariants verified — see ArchitectureInvariantsTest.")
    }
}

tasks.named("check") { dependsOn("checkArchitectureInvariants") }

/**
 * AGP 9 dropped the legacy `unitTestClasses` task that older
 * IntelliJ / Android Studio test runners (and some external test
 * tools) still invoke when you tap the green "Run tests" arrow.
 * Without this alias the IDE fails with
 *   "Cannot locate tasks that match ':app:unitTestClasses'"
 *
 * Register it as an alias that depends on the real compile +
 * resource tasks for the debug unit-test source set.  Running this
 * task produces the same classpath the JVM test runner needs, so
 * the IDE play button works again without us migrating every dev
 * machine's run-configuration XML.
 */
tasks.register("unitTestClasses") {
    group       = "build"
    description = "AGP-9 compatibility alias for legacy IDE test runners."
    dependsOn(
        tasks.named("compileDebugUnitTestKotlin"),
        tasks.named("processDebugUnitTestJavaRes"),
        tasks.named("processDebugJavaRes"),
    )
}

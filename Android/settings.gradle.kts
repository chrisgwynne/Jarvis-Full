import java.util.Properties
import java.io.FileInputStream

pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
// foojay-resolver-convention removed: version 0.10.0 does not exist on
// Maven Central (the artifact was never published there).  JVM toolchain
// auto-provisioning is not required because the JetBrains JDK 21 is
// already present in the Gradle JDK cache ($GRADLE_USER_HOME/jdks).
// Re-add when upgrading to a version that is actually available, e.g. 1.0.0.

// ── Meta Wearables DAT credential plumbing ───────────────────────────────
// The DAT SDK is hosted on GitHub Packages
// (https://maven.pkg.github.com/facebook/meta-wearables-dat-android), which
// requires authenticated reads.  We pull a PAT from (in order):
//   1. The GITHUB_TOKEN environment variable, or
//   2. The `github_token` key in local.properties (gitignored).
//
// Without a token Gradle simply cannot resolve `com.meta.wearable:mwdat-*`,
// the StubMetaWearablesProvider stays the active backend, and the app still
// builds — the failure surfaces as a clear "Could not resolve" error during
// Gradle sync rather than a silent runtime miss.
val localProps: Properties = Properties().apply {
    val f = file("local.properties")
    if (f.exists()) FileInputStream(f).use { load(it) }
}

val githubToken: String? =
    System.getenv("GITHUB_TOKEN")?.takeIf { it.isNotBlank() }
        ?: localProps.getProperty("github_token")?.takeIf { it.isNotBlank() }

// GitHub Packages **requires** the GitHub username of the token owner
// as the credential username (HTTP Basic auth).  Using a placeholder
// like "token" gets a 401.  Set `github_username=<your-github-handle>`
// in local.properties or the GITHUB_USERNAME env var.
val githubUsername: String? =
    System.getenv("GITHUB_USERNAME")?.takeIf { it.isNotBlank() }
        ?: localProps.getProperty("github_username")?.takeIf { it.isNotBlank() }

// Fail clearly only when the developer has explicitly set up Meta Wearables
// credentials in local.properties (github_token key) but forgot the username.
// We do NOT fail on a bare GITHUB_TOKEN env var because that is commonly set
// by CI systems for unrelated purposes (e.g. GitHub API / MCP access).
val localPropsToken = localProps.getProperty("github_token")?.takeIf { it.isNotBlank() }
if (localPropsToken != null && githubUsername == null) {
    throw GradleException(
        "github_token is set in local.properties but github_username is missing. " +
        "Add `github_username=<your-github-handle>` to local.properties."
    )
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
        // Meta DAT SDK — only registered when a token is available; that
        // way developers who haven't opted into the wearables module don't
        // get a confusing "401 from maven.pkg.github.com" on every build.
        if (githubToken != null && githubUsername != null) {
            maven {
                name = "MetaWearablesDatGitHubPackages"
                url = uri("https://maven.pkg.github.com/facebook/meta-wearables-dat-android")
                credentials {
                    username = githubUsername
                    password = githubToken
                }
            }
        }
    }
}

rootProject.name = "Jarvis"
include(":app")

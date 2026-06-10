package com.jarvis.assistant.memory.db

import android.app.Application
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.test.core.app.ApplicationProvider
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Migration-chain safety net for jarvis.db (#13 follow-up to the destructive
 * wipe fix in #46).
 *
 * Release builds intentionally have no destructive fallback: a broken or
 * missing migration makes the app fail loudly instead of silently wiping the
 * user's memories. That makes this suite the only thing standing between a
 * schema bump and an un-upgradeable install — it must stay green and must
 * gain a committed schema JSON (app/schemas/) for every version bump.
 *
 * Method: each committed historical schema JSON is replayed onto a raw
 * SQLite file (createSql + indices + room_master_table setupQueries +
 * PRAGMA user_version), then the database is opened through Room with the
 * production migration chain. Room migrates and then verifies its identity
 * hash — a wrong or missing migration throws "Room cannot verify the data
 * integrity", failing the test exactly the way a real device would fail.
 *
 * (MigrationTestHelper is not used because Robolectric only exposes app
 * assets, not test-sourceSet assets; the schema JSONs are classpath
 * resources instead — see build.gradle.kts sourceSets.)
 *
 * `application = Application::class` keeps Robolectric from booting the real
 * JarvisApp.onCreate, which initialises EncryptedSharedPreferences — the
 * Android KeyStore does not exist on the JVM.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class JarvisDatabaseMigrationTest {

    private val schemaDir = JarvisDatabase::class.java.canonicalName!!

    // @Database has BINARY retention, so the version is not readable via
    // reflection. The chain's last endVersion is the same value; the
    // fresh-open test below cross-checks it against the real database's
    // PRAGMA user_version, so a @Database version bump without a matching
    // migration still fails this suite.
    private val latestVersion: Int =
        JarvisDatabase.ALL_MIGRATIONS.maxOf { it.endVersion }

    private fun schemaJson(version: Int): JSONObject? {
        val stream = javaClass.classLoader
            ?.getResourceAsStream("$schemaDir/$version.json") ?: return null
        return JSONObject(stream.bufferedReader().readText())
    }

    private fun committedSchemaVersions(): List<Int> =
        (1..latestVersion).filter { v ->
            javaClass.classLoader?.getResource("$schemaDir/$v.json") != null
        }

    /** Replays a schema JSON onto a raw SQLite file at the given path. */
    private fun createDatabaseAtVersion(version: Int, dbPath: String) {
        val schema = checkNotNull(schemaJson(version)) { "$schemaDir/$version.json missing" }
        val database = schema.getJSONObject("database")
        assertEquals("schema file version mismatch", version, database.getInt("version"))

        val db = SQLiteDatabase.openOrCreateDatabase(dbPath, null)
        db.use {
            val entities = database.getJSONArray("entities")
            for (i in 0 until entities.length()) {
                val entity = entities.getJSONObject(i)
                val table = entity.getString("tableName")
                it.execSQL(entity.getString("createSql").replace("\${TABLE_NAME}", table))
                val indices = entity.optJSONArray("indices")
                if (indices != null) {
                    for (j in 0 until indices.length()) {
                        it.execSQL(
                            indices.getJSONObject(j).getString("createSql")
                                .replace("\${TABLE_NAME}", table)
                        )
                    }
                }
            }
            val setup = database.getJSONArray("setupQueries")
            for (i in 0 until setup.length()) it.execSQL(setup.getString(i))
            it.version = version
        }
    }

    private fun openWithRoom(name: String): JarvisDatabase =
        Room.databaseBuilder(
            ApplicationProvider.getApplicationContext(),
            JarvisDatabase::class.java,
            name,
        )
            .addMigrations(*JarvisDatabase.ALL_MIGRATIONS)
            .setJournalMode(RoomDatabase.JournalMode.TRUNCATE)
            .allowMainThreadQueries()
            .build()

    // ── Tests ───────────────────────────────────────────────────────────────

    @Test
    fun `migration chain is contiguous from version 1 to the current version`() {
        val migrations = JarvisDatabase.ALL_MIGRATIONS.sortedBy { it.startVersion }
        var expectedStart = 1
        for (m in migrations) {
            assertEquals(
                "gap in migration chain before ${m.startVersion}→${m.endVersion}",
                expectedStart, m.startVersion,
            )
            assertEquals(
                "non-adjacent migration ${m.startVersion}→${m.endVersion}",
                m.startVersion + 1, m.endVersion,
            )
            expectedStart = m.endVersion
        }
        assertEquals(latestVersion, expectedStart)
    }

    @Test
    fun `current schema JSON is exported and committed`() {
        assertNotNull(
            "app/schemas/$schemaDir/$latestVersion.json is missing from the " +
                "test classpath. Build once (Room generates it via " +
                "schemaLocation), then commit it.",
            schemaJson(latestVersion),
        )
    }

    @Test
    fun `database migrates from every committed historical schema to the current version`() {
        val historical = committedSchemaVersions().filter { it < latestVersion }
        // Schema export was enabled at v19, so 18.json (derived: v19 minus the
        // three action_journal columns MIGRATION_18_19 adds — the one
        // historical schema documented precisely in JarvisDatabase.kt) plus
        // every schema generated from v19 onward is available. Each must
        // migrate cleanly to the current version.
        assertTrue("expected at least one historical schema", historical.isNotEmpty())

        val context = ApplicationProvider.getApplicationContext<Context>()
        for (version in historical) {
            val name = "migration-test-from-$version.db"
            val dbFile = context.getDatabasePath(name)
            dbFile.parentFile?.mkdirs()
            dbFile.delete()
            createDatabaseAtVersion(version, dbFile.path)

            val db = openWithRoom(name)
            try {
                // Forces open → Room runs the chain $version→$latestVersion and
                // then validates its identity hash. A broken migration throws
                // "Room cannot verify the data integrity" right here.
                val cursor = db.openHelper.readableDatabase.query("PRAGMA user_version")
                cursor.use {
                    assertTrue(it.moveToFirst())
                    assertEquals(
                        "migrating from v$version did not reach v$latestVersion",
                        latestVersion, it.getInt(0),
                    )
                }
            } finally {
                db.close()
            }
        }
    }

    @Test
    fun `fresh database opens at the current version with the full migration chain registered`() {
        val db = openWithRoom("migration-test-fresh.db")
        try {
            val cursor = db.openHelper.readableDatabase.query("PRAGMA user_version")
            cursor.use {
                assertTrue(it.moveToFirst())
                assertEquals(latestVersion, it.getInt(0))
            }
        } finally {
            db.close()
        }
    }
}

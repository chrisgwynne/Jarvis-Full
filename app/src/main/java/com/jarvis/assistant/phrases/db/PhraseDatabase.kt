package com.jarvis.assistant.phrases.db

import android.content.Context
import android.util.Log
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import com.google.gson.Gson
import com.google.gson.GsonBuilder
import com.google.gson.reflect.TypeToken
import com.jarvis.assistant.phrases.PhraseStore
import com.jarvis.assistant.phrases.PhraseVariant
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Database(
    entities = [PhraseEntity::class],
    version = 1,
    exportSchema = false,
)
abstract class PhraseDatabase : RoomDatabase() {

    abstract fun phraseDao(): PhraseDao

    // ── RoomPhraseStore ───────────────────────────────────────────────────────

    /**
     * PhraseStore implementation backed by [PhraseDao].
     *
     * All operations are dispatched to [Dispatchers.IO] internally so callers
     * can invoke them from any coroutine context without risking a
     * main-thread database access crash.
     */
    inner class RoomPhraseStore : PhraseStore {

        private val gson: Gson = GsonBuilder().create()

        override suspend fun getOverride(key: String): List<PhraseVariant> =
            withContext(Dispatchers.IO) {
                phraseDao().getVariants(key).map { it.toVariant() }
            }

        override suspend fun getAllOverrides(): Map<String, List<PhraseVariant>> =
            withContext(Dispatchers.IO) {
                phraseDao().getAllVariants()
                    .groupBy { it.phraseKey }
                    .mapValues { (_, entities) -> entities.map { it.toVariant() } }
            }

        override suspend fun saveVariant(key: String, variant: PhraseVariant) =
            withContext(Dispatchers.IO) {
                phraseDao().insertVariant(variant.toEntity(key))
            }

        override suspend fun deleteVariant(key: String, variantId: String) =
            withContext(Dispatchers.IO) {
                phraseDao().deleteVariant(key, variantId)
            }

        override suspend fun resetKey(key: String) =
            withContext(Dispatchers.IO) {
                phraseDao().deleteKey(key)
            }

        override suspend fun exportJson(): String =
            withContext(Dispatchers.IO) {
                val all = phraseDao().getAllVariants()
                    .groupBy { it.phraseKey }
                    .mapValues { (_, entities) -> entities.map { it.toVariant() } }
                gson.toJson(all)
            }

        override suspend fun importJson(json: String): PhraseStore.ImportResult =
            withContext(Dispatchers.IO) {
                var imported = 0
                var failed = 0
                val errors = mutableListOf<String>()

                try {
                    val type = object : TypeToken<Map<String, List<PhraseVariant>>>() {}.type
                    val parsed: Map<String, List<PhraseVariant>> = gson.fromJson(json, type)

                    parsed.forEach { (key, variants) ->
                        variants.forEach { variant ->
                            try {
                                phraseDao().insertVariant(variant.toEntity(key))
                                imported++
                            } catch (e: Exception) {
                                failed++
                                errors += "key='$key' variantId='${variant.id}': ${e.message}"
                                Log.w(TAG, "importJson: failed to insert variant for key='$key'", e)
                            }
                        }
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "importJson: failed to parse JSON", e)
                    errors += "JSON parse error: ${e.message}"
                    failed++
                }

                PhraseStore.ImportResult(imported = imported, failed = failed, errors = errors)
            }

        // ── Entity ↔ domain mappers ───────────────────────────────────────────

        private fun PhraseEntity.toVariant(): PhraseVariant = PhraseVariant(
            id           = variantId,
            text         = text,
            isEnabled    = isEnabled,
            condition    = condition,
            isDefault    = false,
            updatedAtMs  = updatedAtMs,
        )

        private fun PhraseVariant.toEntity(phraseKey: String): PhraseEntity = PhraseEntity(
            variantId    = id,
            phraseKey    = phraseKey,
            text         = text,
            isEnabled    = isEnabled,
            condition    = condition,
            packId       = "default",
            updatedAtMs  = updatedAtMs,
        )
    }

    // ── Singleton companion ───────────────────────────────────────────────────

    companion object {
        private const val TAG     = "PhraseDatabase"
        private const val DB_NAME = "jarvis_phrases.db"

        @Volatile
        private var INSTANCE: PhraseDatabase? = null

        fun getInstance(context: Context): PhraseDatabase =
            INSTANCE ?: synchronized(this) {
                INSTANCE ?: Room.databaseBuilder(
                    context.applicationContext,
                    PhraseDatabase::class.java,
                    DB_NAME,
                )
                    .setJournalMode(JournalMode.WRITE_AHEAD_LOGGING)
                    .fallbackToDestructiveMigration(dropAllTables = true)
                    .build()
                    .also { INSTANCE = it }
            }

        /** Convenience — returns a ready-to-use [PhraseStore] backed by Room. */
        fun getStore(context: Context): PhraseStore =
            getInstance(context).RoomPhraseStore()
    }
}

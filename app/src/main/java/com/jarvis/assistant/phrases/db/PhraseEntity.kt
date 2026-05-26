package com.jarvis.assistant.phrases.db

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

/**
 * PhraseEntity — one row per user-defined phrase variant.
 *
 * Multiple rows may share the same [phraseKey]; together they form the
 * ordered variant list for that key.  [packId] defaults to "default" and
 * is reserved for future phrase-pack support.
 */
@Entity(
    tableName = "phrase_variants",
    indices = [Index(value = ["phrase_key"])]
)
data class PhraseEntity(
    @PrimaryKey
    @ColumnInfo(name = "variant_id")
    val variantId: String,
    @ColumnInfo(name = "phrase_key")
    val phraseKey: String,
    val text: String,
    @ColumnInfo(name = "is_enabled")
    val isEnabled: Boolean,
    val condition: String?,
    @ColumnInfo(name = "pack_id")
    val packId: String,
    @ColumnInfo(name = "updated_at_ms")
    val updatedAtMs: Long,
)

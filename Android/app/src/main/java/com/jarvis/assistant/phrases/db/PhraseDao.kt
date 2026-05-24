package com.jarvis.assistant.phrases.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

@Dao
interface PhraseDao {

    @Query("SELECT * FROM phrase_variants WHERE phrase_key = :key")
    suspend fun getVariants(key: String): List<PhraseEntity>

    @Query("SELECT * FROM phrase_variants")
    suspend fun getAllVariants(): List<PhraseEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertVariant(entity: PhraseEntity)

    @Query("DELETE FROM phrase_variants WHERE phrase_key = :key AND variant_id = :variantId")
    suspend fun deleteVariant(key: String, variantId: String)

    @Query("DELETE FROM phrase_variants WHERE phrase_key = :key")
    suspend fun deleteKey(key: String)

    @Query("DELETE FROM phrase_variants")
    suspend fun deleteAll()

    @Query("SELECT COUNT(*) FROM phrase_variants")
    suspend fun count(): Int
}

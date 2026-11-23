package com.jhomlala.better_player

import android.content.Context
import android.net.Uri
import android.util.Log
import com.google.android.exoplayer2.MediaItem
import com.google.android.exoplayer2.drm.DefaultDrmSessionManager
import com.google.android.exoplayer2.drm.DummyExoMediaDrm
import com.google.android.exoplayer2.drm.DrmSessionManagerProvider
import com.google.android.exoplayer2.drm.HttpMediaDrmCallback
import com.google.android.exoplayer2.drm.UnsupportedDrmException
import com.google.android.exoplayer2.source.MediaSource
import com.google.android.exoplayer2.source.dash.DashChunkSource
import com.google.android.exoplayer2.source.dash.DashMediaSource
import com.google.android.exoplayer2.source.dash.DefaultDashChunkSource
import com.google.android.exoplayer2.upstream.DataSource
import com.google.android.exoplayer2.upstream.DefaultHttpDataSource
import com.google.android.exoplayer2.util.Util
import java.util.UUID

class DrmHelper {

    fun buildDrmMediaSource(
        uri: Uri,
        context: Context,
        drmToken: String?,
        drmHeaders: Map<String, String>?,
        licenseUrl: String,
        mediaDataSourceFactory: DataSource.Factory? = null,
        onKeyExpired: (() -> Unit)? = null
    ): MediaSource {
        // Force every key/renewal request onto the app-supplied licenseUrl so
        // CustomData (and other query auth) is never dropped for PSSH default URLs.
        // License HTTP stays unwrapped (no CMCD on key fetches).
        val httpMediaDrmCallback =
            HttpMediaDrmCallback(
                licenseUrl,
                /* forceDefaultLicenseUrl= */ true,
                DefaultHttpDataSource.Factory()
            )
        drmHeaders?.forEach { (drmKey, drmValue) ->
            httpMediaDrmCallback.setKeyRequestProperty(drmKey, drmValue)
        }
        val normalizedToken = drmToken?.trim()?.takeIf {
            it.isNotEmpty() && !it.equals("null", ignoreCase = true)
        }
        normalizedToken?.let {
            httpMediaDrmCallback.setKeyRequestProperty("nv-authorizations", it)
        }

        val drmSchemeUuid = Util.getDrmUuid("widevine")
        val defaultDrmSessionManager = if (drmSchemeUuid != null && Util.SDK_INT >= 18) {
            DefaultDrmSessionManager.Builder()
                .setUuidAndExoMediaDrmProvider(drmSchemeUuid) { uuid: UUID? ->
                    try {
                        // L3 + KEY_EXPIRED → silent session recreate (OEM cannot renew in-place).
                        KeyExpiredRemappingExoMediaDrm.createWidevineL3(uuid!!, onKeyExpired)
                    } catch (e: UnsupportedDrmException) {
                        Log.e(TAG, "Widevine unsupported", e)
                        DummyExoMediaDrm()
                    }
                }
                .setMultiSession(true)
                .build(httpMediaDrmCallback)
        } else {
            DefaultDrmSessionManager.Builder().build(httpMediaDrmCallback)
        }

        defaultDrmSessionManager.setMode(
            DefaultDrmSessionManager.MODE_PLAYBACK,
            null
        )

        val drmSessionManagerProvider = DrmSessionManagerProvider {
            defaultDrmSessionManager
        }

        return buildDashMediaSource(drmSessionManagerProvider, uri, mediaDataSourceFactory)
    }

    private fun buildDashMediaSource(
        drmSessionManager: DrmSessionManagerProvider,
        uri: Uri,
        mediaDataSourceFactory: DataSource.Factory?,
    ): DashMediaSource {
        // Optional CMCD-wrapped factory for manifest/segments; never used for license.
        val mediaFactory = mediaDataSourceFactory ?: DefaultHttpDataSource.Factory()
        val dashChunkSourceFactory: DashChunkSource.Factory =
            DefaultDashChunkSource.Factory(mediaFactory)
        return DashMediaSource.Factory(dashChunkSourceFactory, mediaFactory)
            .setDrmSessionManagerProvider(drmSessionManager)
            .createMediaSource(
                MediaItem.Builder()
                    .setUri(uri).build()
            )
    }

    companion object {
        private const val TAG = "DrmHelper"
    }
}

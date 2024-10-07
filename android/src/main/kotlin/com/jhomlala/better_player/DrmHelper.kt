package com.jhomlala.better_player

import android.content.Context
import android.net.Uri
import com.google.android.exoplayer2.MediaItem
import com.google.android.exoplayer2.drm.DefaultDrmSessionManager
import com.google.android.exoplayer2.drm.DrmSessionManagerProvider
import com.google.android.exoplayer2.drm.ExoMediaDrm
import com.google.android.exoplayer2.drm.MediaDrmCallback
import com.google.android.exoplayer2.drm.MediaDrmCallbackException
import com.google.android.exoplayer2.source.MediaSource
import com.google.android.exoplayer2.source.dash.DashChunkSource
import com.google.android.exoplayer2.source.dash.DashMediaSource
import com.google.android.exoplayer2.source.dash.DefaultDashChunkSource
import com.google.android.exoplayer2.upstream.DefaultHttpDataSource
import com.google.android.exoplayer2.util.Util
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import java.util.HashMap
import java.util.UUID

class DrmHelper {

    fun buildDrmMediaSource(
        uri: Uri,
        context: Context,
        drmToken: String,
        licenseUrl: String
    ): MediaSource {
        val defaultDrmSessionManager =
            DefaultDrmSessionManager.Builder().build(object : MediaDrmCallback {
                @Throws(MediaDrmCallbackException::class)
                override fun executeProvisionRequest(
                    uuid: UUID,
                    request: ExoMediaDrm.ProvisionRequest
                ): ByteArray {
                    try {
                        val url = request.defaultUrl + "&signedRequest=" + String(request.data)
                        return executePost(url)
                    } catch (e: IOException) {
                        e.printStackTrace()
                    }

                    return ByteArray(0)
                }

                @Throws(MediaDrmCallbackException::class)
                override fun executeKeyRequest(
                    uuid: UUID,
                    request: ExoMediaDrm.KeyRequest
                ): ByteArray {
                    val postParameters: MutableMap<String, String> = HashMap()
                    postParameters["kid"] = ""
                    postParameters["token"] = drmToken
                    try {
                        return executePost(request.data, postParameters, licenseUrl)
                    } catch (e: IOException) {
                        e.printStackTrace()
                    }

                    return ByteArray(0)
                }
            })

        defaultDrmSessionManager.setMode(
            DefaultDrmSessionManager.MODE_PLAYBACK,
            null
        )

        val drmSessionManagerProvider = DrmSessionManagerProvider {
            defaultDrmSessionManager
        }

        return buildDashMediaSource(drmSessionManagerProvider, context, uri)
    }

    private fun buildDashMediaSource(
        drmSessionManager: DrmSessionManagerProvider,
        context: Context,
        uri: Uri
    ): DashMediaSource {
        val dashChunkSourceFactory: DashChunkSource.Factory =
            DefaultDashChunkSource.Factory(DefaultHttpDataSource.Factory())
        val manifestDataSourceFactory: DefaultHttpDataSource.Factory =
            DefaultHttpDataSource.Factory()
        return DashMediaSource.Factory(dashChunkSourceFactory, manifestDataSourceFactory)
            .setDrmSessionManagerProvider(drmSessionManager)
            .createMediaSource(
                MediaItem.Builder()
                    .setUri(uri).build()
            )
    }

    @Throws(IOException::class)
    private fun executePost(
        bytearray: ByteArray,
        requestProperties: Map<String, String>,
        licenseUrl: String
    ): ByteArray {
        var data: ByteArray? = bytearray
        var urlConnection: HttpURLConnection? = null
        try {
            urlConnection =
                URL(licenseUrl).openConnection() as HttpURLConnection
            urlConnection.requestMethod = "POST"
            urlConnection.doOutput = true
            urlConnection.doInput = true
            urlConnection.setRequestProperty("Content-Type", "application/json")
            urlConnection.connectTimeout = 30000
            urlConnection.readTimeout = 30000

            val json = JSONObject()
            try {
                val jsonArray = JSONArray()
                val bitmask = 0x000000FF
                for (aData in data!!) {
                    val `val` = aData.toInt()
                    jsonArray.put(bitmask and `val`)
                }

                json.put("token", requestProperties["token"])
                json.put("drm_info", jsonArray)
                json.put("kid", requestProperties["kid"])
            } catch (e: JSONException) {
                e.printStackTrace()
            }

            data = json.toString().toByteArray(StandardCharsets.UTF_8)

            val out = urlConnection.outputStream
            out.use {
                it.write(data)
            }

            val responseCode = urlConnection.responseCode
            if (responseCode < 400) {
                // Read and return the response body.
                val inputStream = urlConnection.inputStream
                inputStream.use { input ->
                    val byteArrayOutputStream = ByteArrayOutputStream()
                    val scratch = ByteArray(1024)
                    var bytesRead: Int
                    while ((input.read(scratch).also { bytesRead = it }) != -1) {
                        byteArrayOutputStream.write(scratch, 0, bytesRead)
                    }
                    return byteArrayOutputStream.toByteArray()
                }
            } else {
                throw IOException()
            }
        } finally {
            urlConnection?.disconnect()
        }
    }

    @Throws(IOException::class)
    private fun executePost(
        url: String?
    ): ByteArray {
        val data: ByteArray? = null
        val requestProperties: Map<String?, String?>? = null
        var urlConnection: HttpURLConnection? = null
        try {
            urlConnection = URL(url).openConnection() as HttpURLConnection
            urlConnection.requestMethod = "POST"
            urlConnection.doOutput = data != null
            urlConnection.doInput = true
            if (requestProperties != null) {
                for ((key1, value) in requestProperties) {
                    urlConnection.setRequestProperty(key1, value)
                }
            }
            // Write the request body, if there is one.
            if (data != null) {
                val out = urlConnection.outputStream
                out.use {
                    it.write(data)
                }
            }
            // Read and return the response body.
            val inputStream = urlConnection.inputStream
            try {
                return Util.toByteArray(inputStream)
            } finally {
                Util.closeQuietly(inputStream)
            }
        } finally {
            urlConnection?.disconnect()
        }
    }

}
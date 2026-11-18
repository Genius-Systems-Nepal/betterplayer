package com.jhomlala.better_player.cmcd

import android.net.Uri
import com.google.android.exoplayer2.upstream.DataSpec
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/**
 * CTA-5004 CMCD encode + attach (query or header). Fail-soft callers catch exceptions.
 */
internal object CmcdEncoder {

    private val SKIP_HINTS = listOf(
        "widevine",
        "fairplay",
        "playready",
        "license",
        "drm",
        "acquirelicense",
        "getlicense",
        "ckc",
        "clock",
        "time-sync",
        "utctiming",
    )

    fun shouldSkip(uri: Uri, licenseUrl: String?): Boolean {
        val url = uri.toString().lowercase()
        if (!licenseUrl.isNullOrBlank() && url.contains(licenseUrl.trim().lowercase())) {
            return true
        }
        return SKIP_HINTS.any { url.contains(it) }
    }

    fun alreadyHasCmcd(uri: Uri): Boolean {
        return !uri.getQueryParameter("CMCD").isNullOrEmpty()
    }

    fun objectTypeFor(uri: Uri): String {
        val path = (uri.lastPathSegment ?: uri.path ?: "").lowercase()
        return when {
            path.endsWith(".m3u8") || path.endsWith(".mpd") || path.contains("manifest") -> "m"
            path.contains("init") || path.contains("map") || path.endsWith(".mp4") && path.contains(
                "init"
            ) -> "i"

            path.endsWith(".vtt") || path.endsWith(".ttml") || path.contains("subtitle") || path.contains(
                "caption"
            ) -> "tt"

            path.endsWith(".m4a") || path.contains("audio") || path.contains("/a/") -> "a"
            path.endsWith(".m4s") || path.endsWith(".ts") || path.endsWith(".mp4") || path.contains(
                "video"
            ) -> "v"

            path.contains("key") || path.endsWith(".key") -> "k"
            else -> "o"
        }
    }

    fun streamingFormatFor(uri: Uri): String {
        val path = (uri.path ?: "").lowercase()
        return when {
            path.contains(".m3u8") || path.contains("hls") -> "h"
            path.contains(".mpd") || path.contains("dash") -> "d"
            else -> "o"
        }
    }

    fun apply(
        dataSpec: DataSpec,
        session: CmcdSession,
        config: CmcdRuntimeConfig,
        metrics: CmcdMetrics,
    ): DataSpec {
        if (!config.isActive) return dataSpec
        val uri = dataSpec.uri
        if (shouldSkip(uri, null)) return dataSpec
        if (config.mode == "query" && alreadyHasCmcd(uri)) return dataSpec

        val payload = buildPayload(session, metrics)
        if (payload.isEmpty()) return dataSpec

        return when (config.mode) {
            "query" -> {
                val encoded = URLEncoder.encode(payload, StandardCharsets.UTF_8.name())
                val joiner = if (uri.query.isNullOrEmpty()) "?" else "&"
                val next = Uri.parse(uri.toString() + joiner + "CMCD=" + encoded)
                dataSpec.buildUpon().setUri(next).build()
            }

            "header" -> {
                val headers = LinkedHashMap(dataSpec.httpRequestHeaders)
                headers.putAll(headerGroups(payloadKeys(session, metrics)))
                dataSpec.buildUpon().setHttpRequestHeaders(headers).build()
            }

            else -> dataSpec
        }
    }

    /** iOS / shared: payload string without URL-encoding. */
    fun buildPayload(session: CmcdSession, metrics: CmcdMetrics): String {
        return payloadKeys(session, metrics).entries.joinToString(",") { (k, v) ->
            if (v == null) k else "$k=$v"
        }
    }

    fun headerGroups(keys: Map<String, String?>): Map<String, String> {
        fun pick(vararg names: String): String {
            return names.mapNotNull { n ->
                if (!keys.containsKey(n)) null
                else if (keys[n] == null) n else "$n=${keys[n]}"
            }.joinToString(",")
        }

        val out = LinkedHashMap<String, String>()
        val obj = pick("br", "d", "ot", "tb")
        val req = pick("bl", "dl", "mtp", "nor", "nrr", "su")
        val ses = pick("cid", "pr", "sf", "sid", "st", "v")
        val sta = pick("bs", "rtp")
        if (obj.isNotEmpty()) out["CMCD-Object"] = obj
        if (req.isNotEmpty()) out["CMCD-Request"] = req
        if (ses.isNotEmpty()) out["CMCD-Session"] = ses
        if (sta.isNotEmpty()) out["CMCD-Status"] = sta
        return out
    }

    private fun payloadKeys(
        session: CmcdSession,
        metrics: CmcdMetrics
    ): LinkedHashMap<String, String?> {
        val keys = LinkedHashMap<String, String?>()
        keys["sid"] = quote(session.sessionId)
        if (session.contentId.isNotEmpty()) {
            keys["cid"] = quote(session.contentId)
        }
        keys["ot"] = metrics.objectType
        keys["sf"] = metrics.streamingFormat
        keys["st"] = if (session.isLive) "l" else "v"
        if (metrics.playbackRate != 1f) {
            keys["pr"] = formatNumber(metrics.playbackRate.toDouble())
        }
        metrics.encodedBitrateKbps?.takeIf { it > 0 }?.let { keys["br"] = it.toString() }
        metrics.topBitrateKbps?.takeIf { it > 0 }?.let { keys["tb"] = it.toString() }
        metrics.throughputKbps?.takeIf { it > 0 }?.let { keys["mtp"] = it.toString() }
        metrics.bufferLengthMs?.takeIf { it >= 0 }?.let { bl ->
            keys["bl"] = bl.toString()
            val rate = if (metrics.playbackRate > 0f) metrics.playbackRate else 1f
            keys["dl"] = (bl / rate).roundToLong().toString()
        }
        if (session.startup) keys["su"] = null
        if (session.bufferStarvation) keys["bs"] = null
        // Omit v when it would be 1.
        return keys
    }

    private fun quote(value: String): String {
        val escaped = value.replace("\\", "\\\\").replace("\"", "\\\"")
        return "\"$escaped\""
    }

    private fun formatNumber(value: Double): String {
        val rounded = (value * 1000.0).roundToInt() / 1000.0
        return if (rounded == rounded.toLong().toDouble()) {
            rounded.toLong().toString()
        } else {
            rounded.toString()
        }
    }
}

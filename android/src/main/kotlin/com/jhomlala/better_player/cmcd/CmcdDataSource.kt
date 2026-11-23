package com.jhomlala.better_player.cmcd

import android.net.Uri
import android.util.Log
import com.google.android.exoplayer2.upstream.DataSource
import com.google.android.exoplayer2.upstream.DataSpec
import com.google.android.exoplayer2.upstream.TransferListener
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/**
 * Wraps an upstream [DataSource] and attaches CTA-5004 CMCD to each open.
 * Fail-soft: any encode error uses the original [DataSpec].
 */
internal class CmcdDataSource(
    private val upstream: DataSource,
    private val sessionRef: AtomicReference<CmcdSession?>,
    private val configRef: AtomicReference<CmcdRuntimeConfig?>,
    private val metricsProvider: () -> CmcdMetrics,
    private val licenseUrlProvider: () -> String?,
) : DataSource {

    override fun addTransferListener(transferListener: TransferListener) {
        upstream.addTransferListener(transferListener)
    }

    override fun open(dataSpec: DataSpec): Long {
        val tagged = try {
            val config = configRef.get()
            val session = sessionRef.get()
            if (config == null || session == null || !config.isActive) {
                dataSpec
            } else if (CmcdEncoder.shouldSkip(dataSpec.uri, licenseUrlProvider())) {
                logSparse("skip drm/clock uri=${truncate(dataSpec.uri)}")
                dataSpec
            } else {
                val base = metricsProvider()
                val metrics = base.copy(
                    objectType = CmcdEncoder.objectTypeFor(dataSpec.uri),
                    streamingFormat = CmcdEncoder.streamingFormatFor(dataSpec.uri),
                )
                val next = CmcdEncoder.apply(dataSpec, session, config, metrics)
                val changed = next.uri != dataSpec.uri ||
                        next.httpRequestHeaders != dataSpec.httpRequestHeaders
                if (changed) {
                    logSparse(
                        "mode=${config.mode} ot=${metrics.objectType} " +
                                "su=${session.startup} bs=${session.bufferStarvation} " +
                                "uri=${truncate(next.uri)}"
                    )
                }
                next
            }
        } catch (e: Exception) {
            Log.w(TAG, "encode failed; sending original request", e)
            dataSpec
        }
        return upstream.open(tagged)
    }

    private fun logSparse(message: String) {
        val n = logCount.incrementAndGet()
        // Log first 20 opens fully, then every 25th — avoids flooding logcat on long plays.
        if (n <= 20 || n % 25 == 0) {
            Log.d(TAG, "#$n $message")
        }
    }

    private fun truncate(uri: Uri): String {
        val text = uri.toString()
        return if (text.length <= 220) text else text.substring(0, 220) + "…"
    }

    companion object {
        private const val TAG = "CMCD"
        private val logCount = AtomicInteger(0)

        fun resetLogCount() {
            logCount.set(0)
        }
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        return upstream.read(buffer, offset, length)
    }

    override fun getUri(): Uri? = upstream.uri

    override fun getResponseHeaders(): Map<String, List<String>> = upstream.responseHeaders

    override fun close() {
        upstream.close()
    }

    class Factory(
        private val upstreamFactory: DataSource.Factory,
        private val sessionRef: AtomicReference<CmcdSession?>,
        private val configRef: AtomicReference<CmcdRuntimeConfig?>,
        private val metricsProvider: () -> CmcdMetrics,
        private val licenseUrlProvider: () -> String?,
    ) : DataSource.Factory {
        override fun createDataSource(): DataSource {
            return CmcdDataSource(
                upstreamFactory.createDataSource(),
                sessionRef,
                configRef,
                metricsProvider,
                licenseUrlProvider,
            )
        }
    }
}

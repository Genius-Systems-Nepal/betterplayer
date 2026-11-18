package com.jhomlala.better_player

import android.net.Uri
import com.google.android.exoplayer2.upstream.BandwidthMeter
import com.google.android.exoplayer2.upstream.DataSource
import com.google.android.exoplayer2.upstream.DefaultDataSource
import com.google.android.exoplayer2.upstream.DefaultHttpDataSource
import com.google.android.exoplayer2.upstream.TransferListener

internal object DataSourceUtils {
    private const val USER_AGENT = "User-Agent"
    private const val USER_AGENT_PROPERTY = "http.agent"

    @JvmStatic
    fun getUserAgent(headers: Map<String, String>?): String? {
        var userAgent = System.getProperty(USER_AGENT_PROPERTY)
        if (headers != null && headers.containsKey(USER_AGENT)) {
            val userAgentHeader = headers[USER_AGENT]
            if (userAgentHeader != null) {
                userAgent = userAgentHeader
            }
        }
        return userAgent
    }

    @JvmStatic
    fun getDataSourceFactory(
        userAgent: String?,
        headers: Map<String, String>?,
        bandwidthMeter: BandwidthMeter? = null
    ): DataSource.Factory {
        val dataSourceFactory = DefaultHttpDataSource.Factory()
            .setUserAgent(userAgent)
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(DefaultHttpDataSource.DEFAULT_CONNECT_TIMEOUT_MILLIS)
            .setReadTimeoutMs(DefaultHttpDataSource.DEFAULT_READ_TIMEOUT_MILLIS)
        if (headers != null) {
            val notNullHeaders = mutableMapOf<String, String>()
            headers.forEach { entry ->
                notNullHeaders[entry.key] = entry.value
            }
            dataSourceFactory.setDefaultRequestProperties(notNullHeaders)
        }
        transferListener(bandwidthMeter)?.let { dataSourceFactory.setTransferListener(it) }
        return dataSourceFactory
    }

    /// ExoPlayer 2.17 [BandwidthMeter] does not extend [TransferListener].
    /// [DefaultBandwidthMeter] implements both; attach that listener once.
    @JvmStatic
    fun attachBandwidthMeter(
        factory: DataSource.Factory,
        bandwidthMeter: BandwidthMeter
    ): DataSource.Factory {
        val listener = transferListener(bandwidthMeter) ?: return factory
        when (factory) {
            is DefaultHttpDataSource.Factory -> factory.setTransferListener(listener)
            is DefaultDataSource.Factory -> factory.setTransferListener(listener)
        }
        return factory
    }

    private fun transferListener(bandwidthMeter: BandwidthMeter?): TransferListener? {
        return bandwidthMeter as? TransferListener
    }

    @JvmStatic
    fun isHTTP(uri: Uri?): Boolean {
        if (uri == null || uri.scheme == null) {
            return false
        }
        val scheme = uri.scheme
        return scheme == "http" || scheme == "https"
    }
}
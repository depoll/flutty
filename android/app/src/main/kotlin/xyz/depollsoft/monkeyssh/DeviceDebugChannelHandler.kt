package xyz.depollsoft.monkeyssh

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.SocketException
import java.util.ArrayDeque
import java.util.Collections

object DeviceDebugChannelHandler {
    private const val CHANNEL = "xyz.depollsoft.monkeyssh/device_debug"
    private const val TAG = "DeviceDebugChannel"
    private const val PAIRING_SERVICE_TYPE = "_adb-tls-pairing._tcp."
    private const val CONNECT_SERVICE_TYPE = "_adb-tls-connect._tcp."

    private var methodChannel: MethodChannel? = null

    fun attachToEngine(flutterEngine: FlutterEngine, applicationContext: Context) {
        if (methodChannel != null) {
            return
        }

        methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).apply {
            setMethodCallHandler { call, result ->
                handleMethodCall(
                    call = call,
                    result = result,
                    applicationContext = applicationContext,
                )
            }
        }
    }

    private fun handleMethodCall(
        call: MethodCall,
        result: MethodChannel.Result,
        applicationContext: Context,
    ) {
        when (call.method) {
            "openDeveloperOptions" -> result.success(
                openDeveloperOptions(applicationContext),
            )
            "discoverAdbEndpoint" -> {
                val serviceType = when (call.argument<String>("kind")) {
                    "pairing" -> PAIRING_SERVICE_TYPE
                    "connect" -> CONNECT_SERVICE_TYPE
                    else -> {
                        result.error(
                            "invalid_kind",
                            "ADB discovery kind must be pairing or connect",
                            null,
                        )
                        return
                    }
                }
                val timeoutMs = (
                    call.argument<Number>("timeoutMs")?.toLong() ?: 6000L
                ).coerceIn(1000L, 15000L)
                AdbEndpointDiscovery(
                    context = applicationContext,
                    serviceType = serviceType,
                    timeoutMs = timeoutMs,
                    result = result,
                ).start()
            }
            else -> result.notImplemented()
        }
    }

    private fun openDeveloperOptions(context: Context): Boolean {
        val intent = Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (intent.resolveActivity(context.packageManager) == null) {
            return false
        }
        return try {
            context.startActivity(intent)
            true
        } catch (error: SecurityException) {
            Log.w(TAG, "Developer options launch denied", error)
            false
        } catch (error: ActivityNotFoundException) {
            Log.w(TAG, "Developer options activity missing", error)
            false
        }
    }

    private class AdbEndpointDiscovery(
        context: Context,
        private val serviceType: String,
        private val timeoutMs: Long,
        private val result: MethodChannel.Result,
    ) {
        private val nsdManager =
            context.getSystemService(Context.NSD_SERVICE) as NsdManager
        private val mainHandler = Handler(Looper.getMainLooper())
        private val localAddresses = readLocalAddresses()
        private val pendingServices = ArrayDeque<NsdServiceInfo>()
        private val wifiManager =
            context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        private var resolving = false
        private var discoveryStarted = false
        private var completed = false
        private var multicastLock: WifiManager.MulticastLock? = null

        private val timeoutRunnable = Runnable { complete(null) }

        private val discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(registrationType: String) {
                discoveryStarted = true
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                pendingServices.add(serviceInfo)
                resolveNext()
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit

            override fun onDiscoveryStopped(serviceType: String) = Unit

            override fun onStartDiscoveryFailed(
                serviceType: String,
                errorCode: Int,
            ) {
                fail("discovery_start_failed", errorCode)
            }

            override fun onStopDiscoveryFailed(
                serviceType: String,
                errorCode: Int,
            ) {
                if (!completed) {
                    fail("discovery_stop_failed", errorCode)
                }
            }
        }

        fun start() {
            mainHandler.postDelayed(timeoutRunnable, timeoutMs)
            try {
                multicastLock = wifiManager.createMulticastLock(
                    "monkeyssh:wireless_adb_discovery",
                ).apply {
                    setReferenceCounted(false)
                    acquire()
                }
                discoveryStarted = true
                nsdManager.discoverServices(
                    serviceType,
                    NsdManager.PROTOCOL_DNS_SD,
                    discoveryListener,
                )
            } catch (error: SecurityException) {
                completeError(
                    code = "discovery_permission_denied",
                    message = error.message ?: "ADB discovery permission was denied",
                )
            } catch (error: IllegalArgumentException) {
                completeError(
                    code = "discovery_unavailable",
                    message = error.message ?: "ADB discovery is unavailable",
                )
            }
        }

        private fun resolveNext() {
            if (completed || resolving || pendingServices.isEmpty()) {
                return
            }
            resolving = true
            val service = pendingServices.removeFirst()
            @Suppress("DEPRECATION")
            nsdManager.resolveService(
                service,
                object : NsdManager.ResolveListener {
                    override fun onResolveFailed(
                        serviceInfo: NsdServiceInfo,
                        errorCode: Int,
                    ) {
                        resolving = false
                        resolveNext()
                    }

                    override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                        resolving = false
                        val address = resolvedAddresses(serviceInfo)
                            .sortedBy { if (it is Inet4Address) 0 else 1 }
                            .firstOrNull(::isLocalAddress)
                        if (address != null && serviceInfo.port in 1..65535) {
                            complete(
                                mapOf(
                                    "serviceName" to serviceInfo.serviceName,
                                    "host" to address.hostAddress,
                                    "port" to serviceInfo.port,
                                ),
                            )
                            return
                        }
                        resolveNext()
                    }
                },
            )
        }

        private fun isLocalAddress(address: InetAddress): Boolean {
            if (address.isLoopbackAddress) {
                return true
            }
            return normalizeAddress(address.hostAddress) in localAddresses
        }

        private fun fail(code: String, errorCode: Int) {
            completeError(
                code = code,
                message = "ADB discovery failed with Android error $errorCode",
            )
        }

        private fun complete(endpoint: Map<String, Any>?) {
            if (completed) {
                return
            }
            completed = true
            cleanup()
            result.success(endpoint)
        }

        private fun completeError(code: String, message: String) {
            if (completed) {
                return
            }
            completed = true
            cleanup()
            result.error(code, message, null)
        }

        private fun cleanup() {
            mainHandler.removeCallbacks(timeoutRunnable)
            if (!discoveryStarted) {
                return
            }
            try {
                nsdManager.stopServiceDiscovery(discoveryListener)
            } catch (_: IllegalArgumentException) {
                // Android may already have stopped a failed discovery.
            }
            multicastLock?.let { lock ->
                if (lock.isHeld) {
                    lock.release()
                }
            }
            multicastLock = null
        }

        private fun resolvedAddresses(serviceInfo: NsdServiceInfo): List<InetAddress> =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                serviceInfo.hostAddresses
            } else {
                @Suppress("DEPRECATION")
                listOfNotNull(serviceInfo.host)
            }

        private fun readLocalAddresses(): Set<String> {
            return try {
                buildSet {
                    val interfaces =
                        NetworkInterface.getNetworkInterfaces() ?: return@buildSet
                    for (networkInterface in Collections.list(interfaces)) {
                        for (address in Collections.list(networkInterface.inetAddresses)) {
                            if (!address.isLoopbackAddress) {
                                add(normalizeAddress(address.hostAddress))
                            }
                        }
                    }
                }
            } catch (error: SocketException) {
                Log.w(TAG, "Unable to enumerate local addresses", error)
                emptySet()
            }
        }

        private fun normalizeAddress(address: String): String =
            address.substringBefore('%').lowercase()
    }
}

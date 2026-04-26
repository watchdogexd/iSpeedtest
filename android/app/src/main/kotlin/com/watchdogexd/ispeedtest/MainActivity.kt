package com.watchdogexd.ispeedtest

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val themeChannelName = "ispeedtest/theme_preferences"
    private val networkBindingChannelName = "ispeedtest/network_binding"
    private val preferencesName = "ispeedtest_preferences"
    private val themeColorIdKey = "theme_color_id"
    private val bypassVpnKey = "bypass_vpn"
    private var savedBoundNetwork: Network? = null
    private var hasSavedBoundNetwork = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            themeChannelName,
        ).setMethodCallHandler { call, result ->
            val preferences = getSharedPreferences(preferencesName, MODE_PRIVATE)
            when (call.method) {
                "getThemeColorId" -> result.success(preferences.getString(themeColorIdKey, null))
                "setThemeColorId" -> {
                    val themeColorId = call.arguments as? String
                    if (themeColorId.isNullOrBlank()) {
                        result.error("invalid_theme_color_id", "Theme color id must not be empty.", null)
                        return@setMethodCallHandler
                    }

                    preferences.edit().putString(themeColorIdKey, themeColorId).apply()
                    result.success(null)
                }
                "getBypassVpn" -> result.success(preferences.getBoolean(bypassVpnKey, false))
                "setBypassVpn" -> {
                    val bypassVpn = call.arguments as? Boolean
                    if (bypassVpn == null) {
                        result.error("invalid_bypass_vpn", "Bypass VPN must be a boolean.", null)
                        return@setMethodCallHandler
                    }

                    preferences.edit().putBoolean(bypassVpnKey, bypassVpn).apply()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            networkBindingChannelName,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "bindToNonVpnNetwork" -> {
                    try {
                        result.success(bindToNonVpnNetwork())
                    } catch (error: SecurityException) {
                        result.error(
                            "network_binding_permission_denied",
                            error.message ?: "Missing network state permission.",
                            null,
                        )
                    }
                }
                "restoreNetworkBinding" -> {
                    restoreNetworkBinding()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun bindToNonVpnNetwork(): Map<String, Any> {
        val connectivityManager =
            getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        if (!hasSavedBoundNetwork) {
            savedBoundNetwork = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                connectivityManager.boundNetworkForProcess
            } else {
                @Suppress("DEPRECATION")
                ConnectivityManager.getProcessDefaultNetwork()
            }
            hasSavedBoundNetwork = true
        }

        val candidates = connectivityManager.allNetworks.mapNotNull { candidate ->
            val capabilities = connectivityManager.getNetworkCapabilities(candidate)
            if (capabilities == null) {
                null
            } else {
                NetworkCandidate(candidate, capabilities)
            }
        }
        val network = candidates
            .filter { candidate ->
                candidate.capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                    !candidate.capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
            }
            .sortedWith(
                compareByDescending<NetworkCandidate> {
                    it.capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                }.thenBy { candidate ->
                    when {
                        candidate.capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> 0
                        candidate.capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> 1
                        candidate.capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> 2
                        else -> 3
                    }
                },
            )
            .firstOrNull()
            ?.network

        val bound = network != null && bindProcessToNetwork(connectivityManager, network)
        return mapOf(
            "bound" to bound,
            "diagnostic" to if (network == null) {
                "没有发现非 VPN 的 INTERNET 网络；可用网络: ${describeNetworks(candidates)}"
            } else if (!bound) {
                "系统拒绝绑定到非 VPN 网络；目标网络: ${describeNetwork(connectivityManager, network)}"
            } else {
                "已绑定到 ${describeNetwork(connectivityManager, network)}"
            },
        )
    }

    private fun restoreNetworkBinding() {
        if (!hasSavedBoundNetwork) {
            return
        }

        val connectivityManager =
            getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        bindProcessToNetwork(connectivityManager, savedBoundNetwork)
        savedBoundNetwork = null
        hasSavedBoundNetwork = false
    }

    private fun bindProcessToNetwork(
        connectivityManager: ConnectivityManager,
        network: Network?,
    ): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            connectivityManager.bindProcessToNetwork(network)
        } else {
            @Suppress("DEPRECATION")
            ConnectivityManager.setProcessDefaultNetwork(network)
        }
    }

    private fun describeNetworks(candidates: List<NetworkCandidate>): String {
        if (candidates.isEmpty()) {
            return "none"
        }
        return candidates.joinToString("; ") { candidate ->
            describeCapabilities(candidate.capabilities)
        }
    }

    private fun describeNetwork(
        connectivityManager: ConnectivityManager,
        network: Network,
    ): String {
        val capabilities = connectivityManager.getNetworkCapabilities(network)
        return if (capabilities == null) {
            "unknown"
        } else {
            describeCapabilities(capabilities)
        }
    }

    private fun describeCapabilities(capabilities: NetworkCapabilities): String {
        val transports = mutableListOf<String>()
        if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
            transports.add("wifi")
        }
        if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) {
            transports.add("cellular")
        }
        if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) {
            transports.add("ethernet")
        }
        if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
            transports.add("vpn")
        }
        if (transports.isEmpty()) {
            transports.add("other")
        }
        val flags = mutableListOf<String>()
        if (capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
            flags.add("internet")
        }
        if (capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) {
            flags.add("validated")
        }
        return "${transports.joinToString("+")} ${flags.joinToString("+")}"
    }

    private data class NetworkCandidate(
        val network: Network,
        val capabilities: NetworkCapabilities,
    )
}

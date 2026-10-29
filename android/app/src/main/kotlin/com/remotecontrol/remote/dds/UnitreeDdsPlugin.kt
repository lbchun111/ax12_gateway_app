package com.remotecontrol.remote.dds

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * 把Flutter方法调用桥接到Android ARM64 CycloneDDS原生模块。
 *
 * 所有DDS操作在单线程执行器中串行运行，避免Sport请求和响应交叉。
 */
class UnitreeDdsPlugin(
    context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL = "com.remotecontrol.remote/unitree_dds"

        // 仅开放当前遥操作实际使用的Go2 Sport API。
        private val ALLOWED_API_IDS = setOf<Long>(
            1,
            1001,
            1002,
            1003,
            1004,
            1005,
            1006,
            1007,
            1008,
        )
    }

    private val applicationContext = context.applicationContext
    private val methodChannel = MethodChannel(messenger, CHANNEL)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private var multicastLock: WifiManager.MulticastLock? = null

    /** 注册Flutter MethodChannel处理器。 */
    fun register() {
        methodChannel.setMethodCallHandler(this)
    }

    /**
     * 接收Flutter请求；耗时的DDS发现与RPC统一转移到后台线程。
     */
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "interfaces" -> complete(result) { listInterfaces() }
            "connect" -> complete(result) {
                val interfaceName = call.argument<String>("interface")?.trim().orEmpty()
                require(interfaceName.isNotEmpty()) { "请选择连接Go2的Android网卡" }
                acquireMulticastLock()
                val version = UnitreeDdsNative.connect(interfaceName)
                mapOf(
                    "connected" to true,
                    "interface" to interfaceName,
                    "serverApiVersion" to version,
                )
            }
            "call" -> complete(result) {
                val apiId = call.argument<Number>("apiId")?.toLong()
                    ?: error("缺少Sport API ID")
                require(apiId in ALLOWED_API_IDS) { "Sport API $apiId 不在安全白名单中" }
                val parameter = call.argument<String>("parameter") ?: "{}"
                val noReply = call.argument<Boolean>("noReply") ?: false
                val timeoutMs = (call.argument<Number>("timeoutMs")?.toInt() ?: 2000)
                    .coerceIn(100, 5000)
                val data = UnitreeDdsNative.call(apiId, parameter, noReply, timeoutMs)
                mapOf("code" to 0, "data" to data, "apiId" to apiId)
            }
            "close" -> complete(result) {
                UnitreeDdsNative.close()
                releaseMulticastLock()
                null
            }
            else -> result.notImplemented()
        }
    }

    /** 关闭DDS资源、MethodChannel和后台执行器。 */
    fun dispose() {
        methodChannel.setMethodCallHandler(null)
        executor.execute {
            runCatching { UnitreeDdsNative.close() }
            releaseMulticastLock()
        }
        executor.shutdown()
    }

    /**
     * 枚举Android当前可用的IPv4网卡，供Flutter选择DDS绑定接口。
     */
    private fun listInterfaces(): List<Map<String, Any>> =
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { it.isUp && !it.isLoopback }
            .mapNotNull { networkInterface ->
                val addresses = networkInterface.inetAddresses.toList()
                    .filterIsInstance<Inet4Address>()
                    .map { it.hostAddress.orEmpty() }
                if (addresses.isEmpty()) {
                    null
                } else {
                    mapOf(
                        "name" to networkInterface.name,
                        "displayName" to networkInterface.displayName,
                        "addresses" to addresses,
                        "multicast" to networkInterface.supportsMulticast(),
                    )
                }
            }
            .sortedWith(
                compareByDescending<Map<String, Any>> {
                    @Suppress("UNCHECKED_CAST")
                    (it["addresses"] as List<String>).any { address ->
                        address.startsWith("192.168.123.")
                    }
                }.thenBy { it["name"].toString() },
            )

    /** Wi-Fi链路需要MulticastLock才能稳定接收DDS发现组播。 */
    private fun acquireMulticastLock() {
        if (multicastLock?.isHeld == true) return
        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifiManager.createMulticastLock("ax12-unitree-dds").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    /** 释放Wi-Fi组播锁；以太网连接调用也可以安全执行。 */
    private fun releaseMulticastLock() {
        multicastLock?.let { lock ->
            if (lock.isHeld) lock.release()
        }
        multicastLock = null
    }

    /** 在DDS单线程执行任务，并把结果或异常切回Flutter主线程。 */
    private fun complete(
        result: MethodChannel.Result,
        operation: () -> Any?,
    ) {
        executor.execute {
            try {
                val value = operation()
                mainHandler.post { result.success(value) }
            } catch (error: Throwable) {
                mainHandler.post {
                    result.error(
                        "UNITREE_DDS_ERROR",
                        error.message ?: error.javaClass.simpleName,
                        null,
                    )
                }
            }
        }
    }
}


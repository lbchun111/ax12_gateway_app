package com.remotecontrol.remote.dds

/**
 * CycloneDDS JNI入口。
 *
 * 该对象只暴露最小Sport RPC能力；DDS实体和请求序列化均由原生层负责。
 */
internal object UnitreeDdsNative {
    init {
        System.loadLibrary("ddsc")
        System.loadLibrary("unitree_dds_bridge")
    }

    /** 绑定Android网卡、发现Go2 Sport服务，并返回服务API版本。 */
    @JvmStatic external fun connect(interfaceName: String): String

    /** 发送一个已由上层白名单校验的Sport API请求并返回响应数据。 */
    @JvmStatic external fun call(
        apiId: Long,
        parameter: String,
        noReply: Boolean,
        timeoutMs: Int,
    ): String

    /** 释放当前DDS Domain、Participant、Topic、Reader和Writer。 */
    @JvmStatic external fun close()
}


package com.remotecontrol.remote

import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import com.remotecontrol.remote.dds.UnitreeDdsPlugin
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity(), EventChannel.StreamHandler {
    companion object {
        private const val CHANNEL = "com.remotecontrol.remote/umbus"
        private const val SERIAL_PORT = "/dev/ttyS0"
        private const val SYNC = 0xA6
        private const val AX12_FRAME_SIZE = 0x63
        private const val GIMBAL_CENTER_DEAD_ZONE = 5
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    @Volatile private var running = false
    @Volatile private var eventSink: EventChannel.EventSink? = null
    @Volatile private var serialInput: FileInputStream? = null
    @Volatile private var serialOutput: FileOutputStream? = null
    @Volatile private var keepAliveExecutor: ScheduledExecutorService? = null
    private var sequence = 0L
    private var unitreeDdsPlugin: UnitreeDdsPlugin? = null

    /** 注册 UMBUS EventChannel，使 Dart 侧可以订阅 AX12 串口事件。 */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setStreamHandler(this)
        unitreeDdsPlugin = UnitreeDdsPlugin(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        ).also { it.register() }
    }

    /** Dart 开始监听时保存事件出口，并启动后台串口读取任务。 */
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        startSerialReader()
    }

    /** Dart 取消监听时停止串口任务并释放事件出口。 */
    override fun onCancel(arguments: Any?) {
        stopSerialReader()
        eventSink = null
    }

    /** Activity 销毁时关闭串口与线程池，防止后台任务泄漏。 */
    override fun onDestroy() {
        stopSerialReader()
        unitreeDdsPlugin?.dispose()
        unitreeDdsPlugin = null
        executor.shutdownNow()
        super.onDestroy()
    }

    /**
     * 在单线程执行器中启动完整 AX12 串口会话。
     *
     * 方法会检查原厂应用占用、配置驱动和 921600 8N1、启动心跳，
     * 然后进入帧读取循环；异常与资源清理都在后台任务内统一处理。
     */
    private fun startSerialReader() {
        if (running) return
        running = true
        executor.execute {
            try {
                if (isRadioMasterOsRunning()) {
                    emitError(
                        "SERIAL_BUSY",
                        "RadioMasterOS 正在运行并可能占用 $SERIAL_PORT。请先从最近任务中关闭 RadioMasterOS，再重新打开本应用。",
                    )
                    return@execute
                }

                configureReceiveTrigger()
                configureSerialPort()
                val input = FileInputStream(SERIAL_PORT)
                val output = FileOutputStream(SERIAL_PORT)
                serialInput = input
                serialOutput = output
                startKeepAlive(output)
                emitStatus("listening", "正在读取 AX12 MCU · $SERIAL_PORT · 921600 8N1")
                readFrames(input)
            } catch (error: Exception) {
                if (running) {
                    emitError("SERIAL_OPEN_FAILED", error.message ?: error.javaClass.simpleName)
                }
            } finally {
                stopKeepAlive()
                try {
                    serialInput?.close()
                } catch (_: IOException) {
                }
                try {
                    serialOutput?.close()
                } catch (_: IOException) {
                }
                serialInput = null
                serialOutput = null
                running = false
            }
        }
    }

    /** 停止读取与心跳并关闭输入输出流；关闭流会解除阻塞中的 read。 */
    private fun stopSerialReader() {
        running = false
        stopKeepAlive()
        try {
            serialInput?.close()
        } catch (_: IOException) {
        }
        try {
            serialOutput?.close()
        } catch (_: IOException) {
        }
        serialInput = null
        serialOutput = null
    }

    /**
     * 每 500 ms 按当前 AX12 固件的原厂行为发送配置、心跳、保活和轮询帧。
     *
     * @param output 已打开的 ttyS0 输出流。
     */
    private fun startKeepAlive(output: FileOutputStream) {
        // Captured from the stock RadioMasterOS on this AX12 firmware.
        val poll = bytesOf(0xA6, 0x0E, 0x10, 0x04, 0x02, 0x02, 0x06, 0, 0, 0, 0, 0, 0, 0xAD)
        val heartbeat = bytesOf(0xA6, 0x08, 0x35, 0x04, 0x05, 0x01, 0x80, 0x84)
        val config = bytesOf(0xA6, 0x0C, 0x10, 0x04, 0x02, 0x81, 0x01, 0x20, 0, 0, 0, 0x80)
        val keepAlive = bytesOf(0xA6, 0x07, 0x2B, 0x04, 0xFF, 0x01, 0xF4)
        var tick = 0
        keepAliveExecutor = Executors.newSingleThreadScheduledExecutor().also { scheduler ->
            scheduler.scheduleAtFixedRate(
                {
                    if (!running) return@scheduleAtFixedRate
                    try {
                        if (tick % 2 == 0) output.write(config) else output.write(heartbeat)
                        if (tick % 4 == 0) output.write(keepAlive)
                        output.write(poll)
                        output.flush()
                        tick += 1
                    } catch (error: IOException) {
                        if (running) emitError("SERIAL_WRITE_FAILED", error.message ?: "心跳写入失败")
                    }
                },
                0,
                500,
                TimeUnit.MILLISECONDS,
            )
        }
    }

    /** 立即停止心跳调度器并清空引用。 */
    private fun stopKeepAlive() {
        keepAliveExecutor?.shutdownNow()
        keepAliveExecutor = null
    }

    /**
     * 使用 stty 将 ttyS0 配置为 921600、8N1、raw、无软硬件流控。
     *
     * @throws IOException stty 返回非零退出码时抛出。
     */
    private fun configureSerialPort() {
        val command =
            "stty -F $SERIAL_PORT 921600 cs8 -cstopb -parenb -crtscts " +
                "-ixon -ixoff clocal cread raw -echo min 1 time 1"
        val process = ProcessBuilder("sh", "-c", command)
            .redirectErrorStream(true)
            .start()
        val output = process.inputStream.bufferedReader().readText().trim()
        val result = process.waitFor()
        if (result != 0) {
            throw IOException("串口配置失败($result): $output")
        }
    }

    /**
     * 尝试把 MTK 串口驱动接收触发阈值写为 32，匹配原厂初始化。
     *
     * root 不可用时忽略异常并继续打开串口，因为部分固件已预配置。
     */
    private fun configureReceiveTrigger() {
        // The stock application performs the same sysfs initialization before
        // opening ttyS0. The MTK driver reports 28 after accepting value 32.
        try {
            val process = ProcessBuilder(
                "su",
                "0",
                "sh",
                "-c",
                "echo 32 > /sys/class/tty/ttyS0/rx_trig_bytes",
            ).redirectErrorStream(true).start()
            process.inputStream.bufferedReader().readText()
            process.waitFor()
        } catch (_: Exception) {
            // Some builds already have the correct trigger configured. Opening
            // ttyS0 is still worth trying when root execution is unavailable.
        }
    }

    /**
     * 检查原厂 RadioMasterOS 是否运行，以避免两个进程同时占用 ttyS0。
     *
     * @return 找到原厂进程 PID 时为 true；检测命令失败时返回 false。
     */
    private fun isRadioMasterOsRunning(): Boolean {
        return try {
            val process = ProcessBuilder("sh", "-c", "pidof com.Flyshark.RadioMasterAX")
                .redirectErrorStream(true)
                .start()
            val output = process.inputStream.bufferedReader().readText().trim()
            process.waitFor()
            output.isNotEmpty()
        } catch (_: Exception) {
            false
        }
    }

    /**
     * 持续寻找 A6/0x63 帧，并只把 A6 63 10 02 04 01 控制帧交给解析器。
     *
     * @param input 已配置并打开的 ttyS0 输入流。
     */
    private fun readFrames(input: FileInputStream) {
        while (running) {
            val first = input.read()
            if (first < 0 || first != SYNC) continue

            val frameSize = input.read()
            if (frameSize != AX12_FRAME_SIZE) continue
            val frame = ByteArray(AX12_FRAME_SIZE)
            frame[0] = SYNC.toByte()
            frame[1] = frameSize.toByte()
            if (!readFully(input, frame, 2, AX12_FRAME_SIZE - 2)) return

            // Real AX12 control reports observed on this firmware begin with
            // A6 63 10 02 04 01. Ignore other 0x63 messages defensively.
            if (unsigned(frame[2]) == 0x10 &&
                unsigned(frame[3]) == 0x02 &&
                unsigned(frame[4]) == 0x04 &&
                unsigned(frame[5]) == 0x01
            ) {
                emitChannelFrame(frame)
            }
        }
    }

    /**
     * 循环读取，直到目标数组的指定区域填满、流结束或任务停止。
     *
     * @return 完整读取 [length] 字节时为 true，否则为 false。
     */
    private fun readFully(
        input: FileInputStream,
        target: ByteArray,
        offset: Int,
        length: Int,
    ): Boolean {
        var position = offset
        val end = offset + length
        while (running && position < end) {
            val count = input.read(target, position, end - position)
            if (count < 0) return false
            position += count
        }
        return position == end
    }

    /**
     * 解析 42 个 SRC 值及帧尾 4 个独立 Trim 状态，并发送给 Flutter。
     *
     * 输出同时包含四轴、已知控件映射、帧序号、时间戳与状态字节。
     */
    private fun emitChannelFrame(frame: ByteArray) {
        // RadioMasterOS copies frame[6..89] into RcSysSrcRaw and iterates 0x2A
        // (42) signed 16-bit sources. The following frame[90..93] is copied as
        // four signed 8-bit trim states. AX12 hardware reports the physical
        // trim keys in T4, T2, T3, T1 order, so normalize them here to
        // T1, T2, T3, T4 before exposing virtual indices 42..45. Keeping the
        // correction at the protocol boundary makes the UI, history and
        // device-control router share the same semantic ordering.
        val sources = List(42) { index ->
            val value = signed16(frame, 6 + index * 2)
            if (index < 4) applyGimbalCenterDeadZone(value) else value
        }
        val rawTrims = List(4) { index -> signed8(frame[90 + index]) }
        val trims = listOf(rawTrims[3], rawTrims[1], rawTrims[2], rawTrims[0])
        val channels = sources + trims
        val gimbals = channels.take(4)
        val mapped = mapOf(
            // 42 路布局：POT1..8=4..11，S1..8=12..19，SA..SP=20..35。
            "POT1" to channels[4],
            "POT2" to channels[5],
            "S1" to channels[12],
            "S2" to channels[13],
            "SA" to channels[20],
            "SB" to channels[21],
            "SC" to channels[22],
            "SD" to channels[23],
            "SE" to channels[24],
            "SF" to channels[25],
            "6POS" to channels[35],
            "CNT1" to channels[36],
            "T1" to trims[0],
            "T2" to trims[1],
            "T3" to trims[2],
            "T4" to trims[3],
        )

        sequence += 1
        emit(
            mapOf(
                "type" to "frame",
                "sequence" to sequence,
                "timestamp" to System.currentTimeMillis(),
                "gimbals" to gimbals,
                "channels" to channels,
                "trims" to trims,
                "mapped" to mapped,
            ),
        )
    }

    /**
     * 将四轴摇杆位于机械中心附近的 ADC 残差归零。
     *
     * AX12 的四轴范围为 -500..500，摇杆回中时可能稳定在 -5..5，
     * 这些数值属于传感器量化误差而不是有效操控。仅在协议入口对前四个
     * SRC 应用死区，可以保证界面、历史记录和设备控制使用相同的归零值。
     */
    private fun applyGimbalCenterDeadZone(value: Int): Int =
        if (value in -GIMBAL_CENTER_DEAD_ZONE..GIMBAL_CENTER_DEAD_ZONE) 0 else value

    /** 构造 type=status 事件并发送到 Flutter 主线程。 */
    private fun emitStatus(state: String, message: String) {
        emit(mapOf("type" to "status", "state" to state, "message" to message))
    }

    /** 构造 type=error 事件并发送到 Flutter 主线程。 */
    private fun emitError(code: String, message: String) {
        emit(mapOf("type" to "error", "code" to code, "message" to message))
    }

    /** 将后台串口线程产生的 Map 切换到 Android 主线程交给 EventSink。 */
    private fun emit(value: Map<String, Any>) {
        mainHandler.post { eventSink?.success(value) }
    }

    /** 将 Kotlin 有符号 Byte 转为 0..255 的无符号整数。 */
    private fun unsigned(value: Byte): Int = value.toInt() and 0xFF

    /** 将协议中的单字节二进制补码转换为 -128..127 的 Trim 状态值。 */
    private fun signed8(value: Byte): Int = value.toInt()

    /** 将多个整数的低 8 位依次转换成 ByteArray，便于定义固定协议帧。 */
    private fun bytesOf(vararg values: Int): ByteArray =
        ByteArray(values.size) { index -> values[index].toByte() }

    /** 从 [offset] 读取一个小端 16 位有符号整数。 */
    private fun signed16(bytes: ByteArray, offset: Int): Int {
        val value = unsigned(bytes[offset]) or (unsigned(bytes[offset + 1]) shl 8)
        return if (value >= 0x8000) value - 0x10000 else value
    }

}

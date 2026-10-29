"""Unitree Go2 的官方 unitree_sdk2_python 高层运动适配器。"""

from __future__ import annotations

import time
from typing import Any

from .base import RobotDriver


class Go2RobotDriver(RobotDriver):
    """把通用网关动作翻译为 Go2 SportClient 调用。"""

    def __init__(
        self,
        network_interface: str,
        robot_ip: str = "192.168.123.161",
    ) -> None:
        """保存 DDS 网卡及 Go2 地址；直到 connect 才初始化官方 SDK。"""

        if not network_interface:
            raise ValueError("go2 驱动必须设置 UNITREE_INTERFACE")
        self.network_interface = network_interface
        self.robot_ip = robot_ip
        self._channel_initialized = False
        self._client: Any | None = None
        self._server_api_version: str | None = None
        self._connection_error: str | None = None
        self._last_action = "none"
        self._last_result: int | None = None
        self._next_probe_at = 0.0
        self._external_control_enabled = False
        self._lease_id = 0

    @property
    def name(self) -> str:
        """返回 Go2 驱动名称。"""

        return "unitree-go2"

    def connect(self) -> None:
        """在指定网卡初始化CycloneDDS，并用真实Sport RPC确认服务在线。

        路由器可能限制ICMP但仍正常转发DDS，因此连接判定不能依赖ping。
        SportClient调用有明确超时，并且网关在执行器线程中运行本方法，
        不会阻塞WebSocket握手。
        """

        from unitree_sdk2py.core.channel import ChannelFactoryInitialize
        from unitree_sdk2py.go2.sport.sport_client import SportClient

        # CycloneDDS 进程级工厂只初始化一次。之后的重连仅重建客户端，
        # 允许网关先启动，再等待网线或机器人恢复。
        if not self._channel_initialized:
            ChannelFactoryInitialize(0, self.network_interface)
            self._channel_initialized = True
        # Go2 固件会静默忽略 leaseId=0 的 no-reply Move；必须先取得
        # sport_lease，再把客户端视为可用于外部速度控制。
        client = SportClient(enableLease=True)
        client.SetTimeout(2.0)
        client.Init()
        lease_deadline = time.monotonic() + 5.0
        while time.monotonic() < lease_deadline:
            lease_id = int(client.GetLeaseId() or 0)
            if lease_id != 0:
                self._lease_id = lease_id
                break
            time.sleep(0.1)
        else:
            self._client = None
            self._server_api_version = None
            self._lease_id = 0
            self._connection_error = "Go2 Sport 控制租约申请超时"
            raise RuntimeError(self._connection_error)
        # DDS 发现是异步的。启动时等待 Sport 服务真正可调用，避免连接成功但
        # 所有动作都返回 RPC_ERR_CLIENT_SEND(3102) 的假在线状态。
        for _ in range(12):
            code, version = client.GetServerApiVersion()
            if int(code) == 0:
                self._client = client
                self._server_api_version = str(version)
                self._connection_error = None
                self._next_probe_at = time.monotonic() + 15.0
                return
            time.sleep(0.5)
        self._client = None
        self._server_api_version = None
        self._lease_id = 0
        self._connection_error = (
            f"Go2 Sport 服务不可用，最后返回码={code}，请检查 DDS 网卡和防火墙"
        )
        raise RuntimeError(self._connection_error)

    def probe(self) -> bool:
        """低频调用Sport版本API，但不因诊断RPC超时拆除有效客户端。

        某些Go2固件在首次版本查询成功后，后续查询会偶发3104。真实动作
        仍由[_check_result]检查3102/3104并触发重连，因此诊断查询只更新
        版本和提示，不应造成状态抖动。
        """

        client = self._client
        if client is None:
            return False
        now = time.monotonic()
        if now < self._next_probe_at:
            return True
        self._next_probe_at = now + 15.0
        try:
            code, version = client.GetServerApiVersion()
        except Exception as error:
            self._connection_error = f"Go2 在线检查失败（保持连接）: {error}"
            return True
        if int(code) != 0:
            self._connection_error = (
                f"Go2 Sport 在线检查返回码={code}（保持连接，动作结果单独校验）"
            )
            return True
        self._server_api_version = str(version)
        self._connection_error = None
        return True

    def move(self, vx: float, vy: float, vyaw: float) -> int:
        """调用 SportClient.Move 发送一次三轴速度命令。"""

        return self._check_result(
            "move",
            self._require_client().Move(vx, vy, vyaw),
        )

    def set_external_control(self, enabled: bool) -> int:
        """外部控制时关闭内置摇杆，释放控制时恢复内置摇杆。"""

        result = self._require_client().SwitchJoystick(not enabled)
        code = self._check_result(
            "external_control_on" if enabled else "external_control_off",
            result,
        )
        self._external_control_enabled = enabled
        return code

    def stop(self) -> int:
        """发送零速度停止移动，规避部分 Go2 固件 StopMove 的 3104 超时。"""

        return self._check_result("stop", self._require_client().Move(0.0, 0.0, 0.0))

    def set_pitch(self, pitch: float) -> int:
        """调用 Euler 设置机身俯仰角，横滚和偏航姿态保持为零。"""

        return self._check_result(
            "pitch",
            self._require_client().Euler(0.0, pitch, 0.0),
        )

    def invoke(self, action: str) -> int:
        """按白名单调用安全且明确的 Go2 高层动作。"""

        methods = {
            "stand_up": "StandUp",
            "stand_down": "StandDown",
            "balance_stand": "BalanceStand",
            "recovery_stand": "RecoveryStand",
            "damp": "Damp",
        }
        method_name = methods.get(action)
        if method_name is None:
            raise ValueError(f"Go2 不支持动作 {action}")
        method = getattr(self._require_client(), method_name)
        return self._check_result(action, method())

    def snapshot(self) -> dict[str, Any]:
        """返回驱动初始化状态与当前 DDS 网卡。"""

        return {
            "connected": self._client is not None,
            "networkInterface": self.network_interface,
            "robotIp": self.robot_ip,
            "serverApiVersion": self._server_api_version,
            "connectionError": self._connection_error,
            "lastAction": self._last_action,
            "lastResult": self._last_result,
            "externalControl": self._external_control_enabled,
            "leaseId": self._lease_id,
        }

    def close(self) -> None:
        """尽力停止机器人并清除 SportClient 引用。"""

        if self._client is not None:
            try:
                self.stop()
            except Exception:
                pass
            try:
                self.set_external_control(False)
            except Exception:
                pass
        self._mark_disconnected("Go2 驱动已关闭")

    def _check_result(self, action: str, result: Any) -> int:
        """记录 SDK 返回码；非零时抛错，禁止网关把失败伪装成 ACK。"""

        code = int(result)
        self._last_action = action
        self._last_result = code
        if code != 0:
            if code in {3102, 3104}:
                self._mark_disconnected(
                    f"Go2 {action} 通信失败，SDK 返回码={code}"
                )
            raise RuntimeError(f"Go2 {action} 执行失败，SDK 返回码={code}")
        return code

    def _mark_disconnected(self, message: str) -> None:
        """清除失效客户端并保存供 App 展示的离线原因。"""

        self._client = None
        self._server_api_version = None
        self._connection_error = message
        self._next_probe_at = 0.0
        self._external_control_enabled = False
        self._lease_id = 0

    def _require_client(self) -> Any:
        """返回已初始化客户端，否则抛出明确的状态错误。"""

        if self._client is None:
            raise RuntimeError("Go2 驱动尚未连接")
        return self._client


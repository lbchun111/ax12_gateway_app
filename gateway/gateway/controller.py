"""把 AX12 动作映射为带限速、解锁和失联保护的机器人命令。"""

from __future__ import annotations

import asyncio
import time
from typing import Any

from .config import GatewayConfig
from .drivers.base import RobotDriver
from .protocol import GatewayCommand


class RobotController:
    """维护三轴速度状态，并集中执行所有安全策略。"""

    # T1~T4 每发生一次有效变化就触发对应快捷动作。
    _TRIM_POSTURES = {
        "trim_t1": "stand_up",
        "trim_t2": "stand_down",
        "trim_t3": "balance_stand",
        "trim_t4": "recovery_stand",
    }

    def __init__(self, driver: RobotDriver, config: GatewayConfig) -> None:
        """创建默认锁定、速度为零的控制器。"""

        self.driver = driver
        self.config = config
        self.armed = False
        self._axes = {"throttle": 0.0, "roll": 0.0, "yaw": 0.0}
        self._last_motion_time = time.monotonic()
        self._velocity_revision = 0
        self._published_velocity_revision = 0
        self._closed = False
        self._driver_lock = asyncio.Lock()

    async def connect(self) -> None:
        """在线程池中初始化可能阻塞的 DDS 驱动。"""

        await self._call_driver(self.driver.connect)

    async def probe_driver(self) -> bool:
        """串行执行驱动在线检查，避免与控制命令并发调用 SportClient。"""

        return bool(await self._call_driver(self.driver.probe))

    async def handle(self, command: GatewayCommand) -> dict[str, Any]:
        """执行单条命令，并返回可直接作为 ACK 发送的状态。"""

        action = command.action
        if action == "arm":
            self._require_driver_connected("arm")
            await self._prepare_motion_control()
        elif action == "motion_stop":
            await self._stop(disarm=False)
        elif action in {"disarm", "stop", "emergency_stop"}:
            await self._stop(disarm=True)
        elif action.startswith("switch_"):
            # AX12 的摇杆帧会让多个 SRC 拨杆值成批跳变。拨杆只用于输入监视，
            # 不得直接改变 Go2 姿态、停止状态或解锁状态。
            pass
        elif action in self._TRIM_POSTURES:
            await self._invoke_posture(self._TRIM_POSTURES[action])
        elif action in self._axes:
            self._axes[action] = self._deadband(command.normalized)
            await self._send_velocity()
        elif action == "pitch":
            await self._send_pitch(command.normalized)
        elif action == "move_forward":
            self._axes["throttle"] = max(0.0, command.normalized)
            await self._send_velocity()
        elif action == "move_backward":
            self._axes["throttle"] = min(0.0, command.normalized)
            await self._send_velocity()
        elif action == "turn_left":
            self._axes["yaw"] = min(0.0, command.normalized)
            await self._send_velocity()
        elif action == "turn_right":
            self._axes["yaw"] = max(0.0, command.normalized)
            await self._send_velocity()
        elif action in {
            "stand_up",
            "stand_down",
            "balance_stand",
            "recovery_stand",
            "damp",
        }:
            await self._invoke_posture(
                action,
                disarm_after=action in {"stand_down", "damp"},
            )
        return self.status(sequence=command.sequence)

    async def _invoke_posture(
        self,
        action: str,
        *,
        disarm_after: bool = False,
    ) -> None:
        """确认已解锁、清除连续运动状态，再直接调用 Go2 姿态动作。

        Unitree SportClient 的 StandUp/StandDown 等接口是独立动作，不要求先
        调用 StopMove。部分 Go2 固件会让 StopMove 返回 3104（API 超时）；
        如果把它作为姿态动作的前置条件，真正的姿态接口将永远不会执行。
        """

        self._require_armed(action)
        self._axes = {"throttle": 0.0, "roll": 0.0, "yaw": 0.0}
        self._velocity_revision += 1
        self._last_motion_time = time.monotonic()
        await self._call_driver(self.driver.invoke, action)
        if disarm_after:
            try:
                await self._call_driver(self.driver.set_external_control, False)
            finally:
                self.armed = False

    async def watchdog(self) -> None:
        """以50Hz续发非零速度，超过deadman时间后立即归零。

        Go2官方速度示例以20毫秒周期持续调用Move。输入命令只负责更新目标值；
        后台循环负责稳定发布，避免单个no-reply数据包被固件忽略。
        """

        while not self._closed:
            await asyncio.sleep(0.02)
            if not self.armed:
                continue
            moving = any(value != 0.0 for value in self._axes.values())
            elapsed = time.monotonic() - self._last_motion_time
            if moving and elapsed > self.config.deadman_timeout_seconds:
                await self._stop(disarm=False)
                continue
            revision = self._velocity_revision
            if not moving and revision == self._published_velocity_revision:
                continue
            try:
                await self._publish_velocity()
                self._published_velocity_revision = revision
            except asyncio.CancelledError:
                raise
            except Exception:
                # Go2 驱动会把 3102/3104 等通信错误写入快照并标记离线。
                # 单次失败不能让唯一的速度发布任务永久退出。
                self._axes = {"throttle": 0.0, "roll": 0.0, "yaw": 0.0}
                self._velocity_revision += 1
                if not self.driver.snapshot().get("connected", False):
                    self.armed = False

    async def close(self) -> None:
        """停止机器人、锁定控制器并关闭驱动。"""

        self._closed = True
        try:
            await self._stop(disarm=True)
        except Exception:
            # 机器人本就可能处于断线状态，不能因此阻止网关正常退出。
            self.armed = False
        await self._call_driver(self.driver.close)

    def status(self, sequence: int | None = None) -> dict[str, Any]:
        """返回客户端 UI 所需的解锁、速度和驱动诊断状态。"""

        robot_status = self.driver.snapshot()
        if not robot_status.get("connected", False):
            # 驱动失联后不能保留先前的解锁状态，防止重连瞬间误动作。
            self.armed = False
            self._axes = {"throttle": 0.0, "roll": 0.0, "yaw": 0.0}

        return {
            "sequence": sequence,
            "armed": self.armed,
            "axes": dict(self._axes),
            "driver": self.driver.name,
            "robot": robot_status,
        }

    async def _send_velocity(self) -> None:
        """更新速度目标；实际 Move 只由固定频率发布循环调用。"""

        self._require_armed("move")
        self._velocity_revision += 1
        self._last_motion_time = time.monotonic()

    async def _prepare_motion_control(self) -> None:
        """取得外部控制权并进入与 T4 相同的可运动恢复站立姿态。"""

        await self._call_driver(self.driver.set_external_control, True)
        try:
            await self._call_driver(self.driver.invoke, "recovery_stand")
        except Exception:
            try:
                await self._call_driver(self.driver.set_external_control, False)
            finally:
                self.armed = False
            raise
        self._axes = {"throttle": 0.0, "roll": 0.0, "yaw": 0.0}
        self._velocity_revision += 1
        self._published_velocity_revision = self._velocity_revision
        self._last_motion_time = time.monotonic()
        self.armed = True

    async def _publish_velocity(self) -> None:
        """按当前三轴目标发布一次速度，不刷新失联保护计时。"""

        vx = self._axes["throttle"] * self.config.maximum_forward_speed
        vy = self._axes["roll"] * self.config.maximum_lateral_speed
        vyaw = self._axes["yaw"] * self.config.maximum_yaw_speed
        await self._call_driver(self.driver.move, vx, vy, vyaw)

    async def _send_pitch(self, value: float) -> None:
        """把右纵归一化值限幅为安全俯仰角并调用 Go2 Euler。"""

        self._require_armed("pitch")
        normalized = self._deadband(value)
        pitch = normalized * self.config.maximum_pitch_radians
        await self._call_driver(self.driver.set_pitch, pitch)
        self._last_motion_time = time.monotonic()

    async def _stop(self, *, disarm: bool) -> None:
        """清零内部轴值、调用驱动停止，并按需锁定控制器。"""

        self._axes = {"throttle": 0.0, "roll": 0.0, "yaw": 0.0}
        self._velocity_revision += 1
        try:
            if self.driver.snapshot().get("connected", False):
                await self._call_driver(self.driver.stop)
                self._published_velocity_revision = self._velocity_revision
        finally:
            self._last_motion_time = time.monotonic()
            if disarm:
                try:
                    if self.driver.snapshot().get("connected", False):
                        await self._call_driver(
                            self.driver.set_external_control,
                            False,
                        )
                finally:
                    self.armed = False

    def _require_armed(self, action: str) -> None:
        """未解锁时拒绝任何可能让机器人运动的动作。"""

        if not self.armed:
            raise PermissionError(f"控制器未解锁，已拒绝 {action}")

    def _require_driver_connected(self, action: str) -> None:
        """机器人驱动离线时拒绝解锁，避免留下虚假的 armed 状态。"""

        if not self.driver.snapshot().get("connected", False):
            self.armed = False
            raise ConnectionError(f"机器人未连接，已拒绝 {action}")

    async def _call_driver(self, function: Any, *arguments: Any) -> Any:
        """模拟驱动直接执行，真实 SDK 调用放入线程以免阻塞 WebSocket。"""

        async with self._driver_lock:
            if self.driver.name == "mock":
                return function(*arguments)
            return await asyncio.to_thread(function, *arguments)

    @staticmethod
    def _deadband(value: float, threshold: float = 0.08) -> float:
        """把摇杆中心附近的小抖动归零，其余值保持比例。"""

        return 0.0 if abs(value) < threshold else max(-1.0, min(1.0, value))


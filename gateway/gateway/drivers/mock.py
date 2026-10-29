"""不连接机器人也能验证整条 App/WebSocket 链路的模拟驱动。"""

from __future__ import annotations

from typing import Any

from .base import RobotDriver


class MockRobotDriver(RobotDriver):
    """在内存中记录最后一条速度和离散动作。"""

    def __init__(self) -> None:
        """创建尚未连接且速度为零的模拟机器人。"""

        self.connected = False
        self.last_velocity = (0.0, 0.0, 0.0)
        self.last_pitch = 0.0
        self.last_action = "idle"
        self.external_control_enabled = False
        self.move_call_count = 0

    @property
    def name(self) -> str:
        """返回模拟驱动名称。"""

        return "mock"

    def connect(self) -> None:
        """把模拟驱动标记为已连接。"""

        self.connected = True

    def probe(self) -> bool:
        """返回模拟驱动当前连接标记。"""

        return self.connected

    def set_external_control(self, enabled: bool) -> int:
        """记录外部控制权状态并返回成功码。"""

        self.external_control_enabled = enabled
        return 0

    def move(self, vx: float, vy: float, vyaw: float) -> int:
        """记录速度命令并返回与 SDK 成功码一致的零。"""

        self.last_velocity = (vx, vy, vyaw)
        self.last_action = "move"
        self.move_call_count += 1
        return 0

    def stop(self) -> int:
        """清零模拟速度并记录停止动作。"""

        self.last_velocity = (0.0, 0.0, 0.0)
        self.last_action = "stop"
        return 0

    def set_pitch(self, pitch: float) -> int:
        """记录机身俯仰角并返回成功码。"""

        self.last_pitch = pitch
        self.last_action = "pitch"
        return 0

    def invoke(self, action: str) -> int:
        """记录一条离散动作而不执行硬件操作。"""

        self.last_action = action
        return 0

    def snapshot(self) -> dict[str, Any]:
        """返回当前连接、速度和动作状态。"""

        return {
            "connected": self.connected,
            "velocity": list(self.last_velocity),
            "pitch": self.last_pitch,
            "lastAction": self.last_action,
            "externalControl": self.external_control_enabled,
        }

    def close(self) -> None:
        """停止模拟机器人并标记为断开。"""

        self.stop()
        self.external_control_enabled = False
        self.connected = False


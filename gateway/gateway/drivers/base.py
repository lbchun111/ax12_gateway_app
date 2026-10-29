"""声明所有机器人型号适配器都要遵守的最小接口。"""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Any


class RobotDriver(ABC):
    """隔离 WebSocket 业务与具体机器人 SDK。"""

    @property
    @abstractmethod
    def name(self) -> str:
        """返回日志和客户端状态中展示的驱动名称。"""

    @abstractmethod
    def connect(self) -> None:
        """初始化 DDS 与机器人高层控制客户端。"""

    @abstractmethod
    def probe(self) -> bool:
        """检查机器人是否仍在线；失联时更新驱动快照并返回 False。"""

    @abstractmethod
    def set_external_control(self, enabled: bool) -> int:
        """切换外部控制权；关闭时恢复机器人内置摇杆。"""

    @abstractmethod
    def move(self, vx: float, vy: float, vyaw: float) -> int:
        """以米每秒和弧度每秒发送一次速度命令。"""

    @abstractmethod
    def set_pitch(self, pitch: float) -> int:
        """设置机身俯仰角，单位为弧度。"""

    @abstractmethod
    def stop(self) -> int:
        """立即停止机器人运动。"""

    @abstractmethod
    def invoke(self, action: str) -> int:
        """调用站立、趴下等离散高层动作。"""

    @abstractmethod
    def snapshot(self) -> dict[str, Any]:
        """返回可序列化的驱动诊断信息。"""

    @abstractmethod
    def close(self) -> None:
        """释放驱动资源并确保运动停止。"""


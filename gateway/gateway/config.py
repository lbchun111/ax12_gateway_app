"""从环境变量读取网关配置。"""

from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class GatewayConfig:
    """保存 WebSocket、安全限制和宇树驱动参数。"""

    host: str = "0.0.0.0"
    port: int = 8765
    token: str = ""
    driver: str = "mock"
    network_interface: str = ""
    deadman_timeout_seconds: float = 0.5
    maximum_forward_speed: float = 0.8
    maximum_lateral_speed: float = 0.5
    maximum_yaw_speed: float = 1.5
    maximum_pitch_radians: float = 0.3

    @classmethod
    def from_environment(cls) -> "GatewayConfig":
        """读取环境变量，并用安全默认值补齐未配置字段。"""

        return cls(
            host=os.getenv("GATEWAY_HOST", "0.0.0.0"),
            port=int(os.getenv("GATEWAY_PORT", "8765")),
            token=os.getenv("GATEWAY_TOKEN", ""),
            driver=os.getenv("UNITREE_DRIVER", "mock").lower(),
            network_interface=os.getenv("UNITREE_INTERFACE", ""),
            deadman_timeout_seconds=float(os.getenv("DEADMAN_TIMEOUT", "0.5")),
            maximum_forward_speed=float(os.getenv("MAX_VX", "0.8")),
            maximum_lateral_speed=float(os.getenv("MAX_VY", "0.5")),
            maximum_yaw_speed=float(os.getenv("MAX_VYAW", "1.5")),
            maximum_pitch_radians=float(os.getenv("MAX_PITCH", "0.3")),
        )


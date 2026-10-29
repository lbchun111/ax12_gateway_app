"""定义 App 与网关之间稳定、可版本化的 JSON 协议。"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Mapping


class ProtocolError(ValueError):
    """表示收到缺字段、字段类型错误或不支持的协议消息。"""


@dataclass(frozen=True)
class GatewayCommand:
    """表示一条已经校验、可交给控制器执行的 AX12 命令。"""

    sequence: int
    action: str
    source: str
    raw: int
    normalized: float
    timestamp: int

    @classmethod
    def from_message(cls, message: Mapping[str, Any]) -> "GatewayCommand":
        """从 JSON 对象构造命令，并拒绝超范围归一化值。"""

        try:
            command = cls(
                sequence=int(message["sequence"]),
                action=str(message["action"]),
                source=str(message.get("source", "unknown")),
                raw=int(message.get("raw", 0)),
                normalized=float(message.get("normalized", 0.0)),
                timestamp=int(message.get("timestamp", 0)),
            )
        except (KeyError, TypeError, ValueError) as error:
            raise ProtocolError(f"无效 command 消息: {error}") from error
        if not -1.0 <= command.normalized <= 1.0:
            raise ProtocolError("normalized 必须位于 [-1, 1]")
        if not command.action:
            raise ProtocolError("action 不能为空")
        return command


def response(message_type: str, **payload: Any) -> dict[str, Any]:
    """创建统一响应对象，避免各处理分支重复拼接协议版本。"""

    return {"type": message_type, "protocol": "ax12-unitree-v1", **payload}


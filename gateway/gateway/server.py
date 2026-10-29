"""运行 AX12 App 可连接的 WebSocket 服务。"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
from typing import Any

from websockets.exceptions import ConnectionClosed
from websockets.server import WebSocketServerProtocol, serve

from .config import GatewayConfig
from .controller import RobotController
from .drivers.base import RobotDriver
from .drivers.mock import MockRobotDriver
from .protocol import GatewayCommand, ProtocolError, response


LOGGER = logging.getLogger("unitree_gateway")


async def maintain_robot_connection(controller: RobotController) -> None:
    """后台连接机器人；断线时持续重试，但不阻塞 WebSocket 端口。"""

    while True:
        if controller.driver.snapshot().get("connected"):
            try:
                if not await controller.probe_driver():
                    LOGGER.warning(
                        "机器人在线检查失败，进入自动重连: %s",
                        controller.driver.snapshot().get("connectionError"),
                    )
                    await asyncio.sleep(2.0)
                    continue
            except asyncio.CancelledError:
                raise
            except Exception as error:
                LOGGER.warning("机器人在线检查异常，进入自动重连: %s", error)
            await asyncio.sleep(2.0)
            continue
        try:
            await controller.connect()
            LOGGER.info("机器人驱动已就绪: %s", controller.driver.name)
        except asyncio.CancelledError:
            raise
        except Exception as error:
            LOGGER.warning("机器人驱动未就绪，5 秒后重试: %s", error)
            await asyncio.sleep(5.0)


def create_driver(config: GatewayConfig) -> RobotDriver:
    """根据配置创建模拟或 Go2 驱动，未知名称直接报错。"""

    if config.driver == "mock":
        return MockRobotDriver()
    if config.driver == "go2":
        from .drivers.go2 import Go2RobotDriver

        return Go2RobotDriver(config.network_interface)
    raise ValueError(f"不支持 UNITREE_DRIVER={config.driver}")


class GatewayServer:
    """管理单一机器人控制器和多个 WebSocket 客户端会话。"""

    def __init__(self, config: GatewayConfig, controller: RobotController) -> None:
        """保存不可变配置和共享机器人控制器。"""

        self.config = config
        self.controller = controller

    async def handle_client(
        self,
        websocket: WebSocketServerProtocol,
        _path: str | None = None,
    ) -> None:
        """验证 hello，然后循环解析 command、ping 和 status 消息。"""

        peer = websocket.remote_address
        LOGGER.info("客户端连接: %s", peer)
        try:
            hello = await asyncio.wait_for(websocket.recv(), timeout=5.0)
            hello_message = self._decode(hello)
            self._validate_hello(hello_message)
            await websocket.send(
                json.dumps(response("ready", **self.controller.status()), ensure_ascii=False)
            )
            async for raw_message in websocket:
                reply = await self._dispatch(self._decode(raw_message))
                await websocket.send(json.dumps(reply, ensure_ascii=False))
        except ConnectionClosed:
            LOGGER.info("客户端断开: %s", peer)
        except Exception as error:
            LOGGER.warning("客户端处理失败 %s: %s", peer, error)
            try:
                await websocket.send(
                    json.dumps(response("error", message=str(error)), ensure_ascii=False)
                )
            except ConnectionClosed:
                pass

    async def _dispatch(self, message: dict[str, Any]) -> dict[str, Any]:
        """按 type 分派消息并构造标准 ACK、pong 或 status 响应。"""

        message_type = message.get("type")
        if message_type == "command":
            command = GatewayCommand.from_message(message)
            LOGGER.info(
                "收到命令 sequence=%s action=%s source=%s normalized=%.4f",
                command.sequence,
                command.action,
                command.source,
                command.normalized,
            )
            try:
                status = await self.controller.handle(command)
            except Exception as error:
                LOGGER.warning(
                    "命令失败 sequence=%s action=%s: %s",
                    command.sequence,
                    command.action,
                    error,
                )
                error_status = self.controller.status(sequence=command.sequence)
                error_status.update(
                    action=command.action,
                    message=str(error),
                )
                return response("error", **error_status)
            LOGGER.info(
                "命令成功 sequence=%s action=%s",
                command.sequence,
                command.action,
            )
            return response("ack", **status)
        if message_type == "ping":
            return response("pong", timestamp=message.get("timestamp"))
        if message_type == "status":
            return response("status", **self.controller.status())
        raise ProtocolError(f"不支持的消息 type={message_type}")

    def _validate_hello(self, message: dict[str, Any]) -> None:
        """校验协议版本和可选共享令牌。"""

        if message.get("type") != "hello":
            raise ProtocolError("第一条消息必须是 hello")
        if message.get("protocol") != "ax12-unitree-v1":
            raise ProtocolError("协议版本不匹配")
        if self.config.token and message.get("token") != self.config.token:
            raise PermissionError("网关令牌错误")

    @staticmethod
    def _decode(raw_message: Any) -> dict[str, Any]:
        """把文本或 UTF-8 字节消息解析为 JSON 对象。"""

        try:
            if isinstance(raw_message, bytes):
                raw_message = raw_message.decode("utf-8")
            value = json.loads(raw_message)
        except (UnicodeDecodeError, json.JSONDecodeError, TypeError) as error:
            raise ProtocolError(f"消息不是有效 JSON: {error}") from error
        if not isinstance(value, dict):
            raise ProtocolError("消息根节点必须是对象")
        return value


async def run(config: GatewayConfig) -> None:
    """立即开放 WebSocket，并在后台连接/重连机器人驱动。"""

    driver = create_driver(config)
    controller = RobotController(driver, config)
    gateway = GatewayServer(config, controller)
    watchdog_task = asyncio.create_task(controller.watchdog())
    reconnect_task = asyncio.create_task(maintain_robot_connection(controller))
    LOGGER.info(
        "网关已启动 ws://%s:%s，driver=%s",
        config.host,
        config.port,
        driver.name,
    )
    try:
        async with serve(gateway.handle_client, config.host, config.port, ping_interval=10):
            await asyncio.Future()
    finally:
        reconnect_task.cancel()
        watchdog_task.cancel()
        await controller.close()


def main() -> None:
    """解析可选命令行覆盖项并启动 asyncio 事件循环。"""

    parser = argparse.ArgumentParser(description="AX12 到宇树 SDK2 WebSocket 网关")
    parser.add_argument("--driver", choices=("mock", "go2"))
    parser.add_argument("--interface", dest="network_interface")
    parser.add_argument("--port", type=int)
    args = parser.parse_args()
    environment = GatewayConfig.from_environment()
    config = GatewayConfig(
        **{
            **environment.__dict__,
            **({"driver": args.driver} if args.driver else {}),
            **(
                {"network_interface": args.network_interface}
                if args.network_interface
                else {}
            ),
            **({"port": args.port} if args.port else {}),
        }
    )
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    asyncio.run(run(config))


if __name__ == "__main__":
    main()


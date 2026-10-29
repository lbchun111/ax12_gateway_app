"""在本机回环地址验证完整 WebSocket 会话与控制流程。"""

import asyncio
import json

from websockets.client import connect
from websockets.server import serve

from gateway.config import GatewayConfig
from gateway.controller import RobotController
from gateway.drivers.mock import MockRobotDriver
from gateway.server import GatewayServer


async def receive_json(websocket):
    """接收一帧 WebSocket 文本并解析为 JSON 对象。"""

    return json.loads(await websocket.recv())


async def main() -> None:
    """启动临时网关并验证握手、解锁、运动和急停 ACK。"""

    config = GatewayConfig(host="127.0.0.1", port=0, driver="mock")
    controller = RobotController(MockRobotDriver(), config)
    await controller.connect()
    gateway = GatewayServer(config, controller)
    async with serve(gateway.handle_client, config.host, config.port) as server:
        port = server.sockets[0].getsockname()[1]
        async with connect(f"ws://127.0.0.1:{port}") as websocket:
            await websocket.send(
                json.dumps(
                    {
                        "type": "hello",
                        "protocol": "ax12-unitree-v1",
                        "clientId": "integration-test",
                        "token": "",
                    }
                )
            )
            assert (await receive_json(websocket))["type"] == "ready"

            for sequence, action, normalized in (
                (1, "arm", 1.0),
                (2, "throttle", 0.5),
                (3, "emergency_stop", 0.0),
            ):
                await websocket.send(
                    json.dumps(
                        {
                            "type": "command",
                            "protocol": "ax12-unitree-v1",
                            "sequence": sequence,
                            "action": action,
                            "source": "test",
                            "raw": 0,
                            "normalized": normalized,
                            "timestamp": 0,
                        }
                    )
                )
                reply = await receive_json(websocket)
                assert reply["type"] == "ack"
                assert reply["sequence"] == sequence

            assert not reply["armed"]
            assert reply["axes"] == {"throttle": 0.0, "roll": 0.0, "yaw": 0.0}

            await websocket.send(
                json.dumps(
                    {
                        "type": "command",
                        "protocol": "ax12-unitree-v1",
                        "sequence": 4,
                        "action": "stand_up",
                        "source": "test",
                        "raw": 0,
                        "normalized": 1.0,
                        "timestamp": 0,
                    }
                )
            )
            error_reply = await receive_json(websocket)
            assert error_reply["type"] == "error"
            assert error_reply["sequence"] == 4
            assert "未解锁" in error_reply["message"]
    await controller.close()
    print("websocket smoke test: OK")


if __name__ == "__main__":
    asyncio.run(main())

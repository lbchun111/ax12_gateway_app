"""不依赖测试框架的控制器烟雾测试入口。"""

import asyncio

from gateway.config import GatewayConfig
from gateway.controller import RobotController
from gateway.drivers.mock import MockRobotDriver
from gateway.protocol import GatewayCommand


async def main() -> None:
    """执行解锁、三轴运动、急停并用断言验证结果。"""

    driver = MockRobotDriver()
    controller = RobotController(driver, GatewayConfig())
    await controller.connect()
    await controller.handle(GatewayCommand(1, "arm", "test", 0, 1.0, 0))
    await controller.handle(GatewayCommand(2, "throttle", "test", 0, 0.5, 0))
    await controller.handle(GatewayCommand(3, "roll", "test", 0, -0.5, 0))
    await controller.handle(GatewayCommand(4, "yaw", "test", 0, 0.25, 0))
    assert driver.last_velocity == (0.4, -0.25, 0.375)
    await controller.handle(
        GatewayCommand(5, "emergency_stop", "test", 0, 0.0, 0)
    )
    assert driver.last_velocity == (0.0, 0.0, 0.0)
    assert not controller.armed
    await controller.close()
    print("controller smoke test: OK")


if __name__ == "__main__":
    asyncio.run(main())

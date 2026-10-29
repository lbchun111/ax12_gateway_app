"""验证网关的核心映射与安全约束。"""

import asyncio
import unittest

from gateway.config import GatewayConfig
from gateway.controller import RobotController
from gateway.drivers.mock import MockRobotDriver
from gateway.protocol import GatewayCommand, ProtocolError


def command(action: str, normalized: float) -> GatewayCommand:
    """创建测试所需的最小标准命令。"""

    return GatewayCommand(1, action, "test", 0, normalized, 0)


class RobotControllerTest(unittest.IsolatedAsyncioTestCase):
    """覆盖解锁、速度映射、急停和协议校验。"""

    async def asyncSetUp(self) -> None:
        """为每个测试创建独立模拟驱动和控制器。"""

        self.driver = MockRobotDriver()
        self.controller = RobotController(self.driver, GatewayConfig())
        await self.controller.connect()
        self.watchdog_task = asyncio.create_task(self.controller.watchdog())

    async def asyncTearDown(self) -> None:
        """在测试结束后停止并关闭模拟驱动。"""

        self.watchdog_task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await self.watchdog_task
        await self.controller.close()

    async def test_motion_requires_arm(self) -> None:
        """未解锁时摇杆运动必须被拒绝。"""

        with self.assertRaises(PermissionError):
            await self.controller.handle(command("throttle", 1.0))

    async def test_probe_driver_reports_connection_state(self) -> None:
        """控制器应把驱动在线探测结果返回给后台重连任务。"""

        self.assertTrue(await self.controller.probe_driver())

    async def test_axes_are_scaled_after_arm(self) -> None:
        """解锁后将三个摇杆轴按配置上限映射为速度。"""

        await self.controller.handle(command("arm", 1.0))
        self.assertTrue(self.driver.external_control_enabled)
        self.assertEqual(self.driver.last_action, "recovery_stand")
        await self.controller.handle(command("throttle", 0.5))
        await self.controller.handle(command("roll", -0.5))
        await self.controller.handle(command("yaw", 0.25))
        await asyncio.sleep(0.03)
        self.assertEqual(self.driver.last_velocity, (0.4, -0.25, 0.375))

    async def test_manual_backward_and_right_turn_are_scaled(self) -> None:
        """手动后退和右转必须映射为负前进速度与正旋转速度。"""

        await self.controller.handle(command("arm", 1.0))
        await self.controller.handle(command("move_backward", -1.0))
        await asyncio.sleep(0.03)
        self.assertEqual(self.driver.last_velocity, (-0.8, 0.0, 0.0))
        await self.controller.handle(command("turn_right", 0.5))
        await asyncio.sleep(0.03)
        self.assertEqual(self.driver.last_velocity, (-0.8, 0.0, 0.75))

    async def test_pitch_is_scaled_after_arm(self) -> None:
        """右纵 Pitch 按配置上限映射为 Go2 机身俯仰角。"""

        await self.controller.handle(command("arm", 1.0))
        await self.controller.handle(command("pitch", 0.5))
        self.assertAlmostEqual(self.driver.last_pitch, 0.15)

    async def test_center_offset_is_zeroed(self) -> None:
        """AX12 中心附近约 4.3% 的偏移不能让 Go2 缓慢爬行。"""

        await self.controller.handle(command("arm", 1.0))
        await self.controller.handle(command("throttle", 0.043))
        await asyncio.sleep(0.03)
        self.assertEqual(self.driver.last_velocity, (0.0, 0.0, 0.0))

    async def test_watchdog_republishes_motion_at_50_hz(self) -> None:
        """非零目标在deadman窗口内必须按20毫秒周期持续发布。"""

        await self.controller.handle(command("arm", 1.0))
        await self.controller.handle(command("throttle", 0.5))
        initial_count = self.driver.move_call_count
        await asyncio.sleep(0.075)
        self.assertGreaterEqual(
            self.driver.move_call_count - initial_count,
            2,
        )

    async def test_emergency_stop_disarms(self) -> None:
        """急停必须同时清零速度并重新锁定。"""

        await self.controller.handle(command("arm", 1.0))
        await self.controller.handle(command("throttle", 1.0))
        await self.controller.handle(command("emergency_stop", 0.0))
        self.assertFalse(self.controller.armed)
        self.assertFalse(self.driver.external_control_enabled)
        self.assertEqual(self.driver.last_velocity, (0.0, 0.0, 0.0))

    async def test_motion_stop_keeps_external_control_armed(self) -> None:
        """松开方向按钮只停止速度，不应迫使用户再次解锁。"""

        await self.controller.handle(command("arm", 1.0))
        await self.controller.handle(command("move_forward", 1.0))
        await self.controller.handle(command("motion_stop", 0.0))
        self.assertTrue(self.controller.armed)
        self.assertTrue(self.driver.external_control_enabled)
        self.assertEqual(self.driver.last_velocity, (0.0, 0.0, 0.0))

    async def test_switch_snapshot_does_not_change_robot_state(self) -> None:
        """拨杆快照抖动不得改变姿态、速度或解锁状态。"""

        await self.controller.handle(command("arm", 1.0))
        await self.controller.handle(command("throttle", 0.5))
        await asyncio.sleep(0.03)
        previous_action = self.driver.last_action
        previous_velocity = self.driver.last_velocity
        for action in (
            "switch_sa",
            "switch_sb",
            "switch_sc",
            "switch_sd",
            "switch_se",
            "switch_sf",
            "switch_6pos",
        ):
            await self.controller.handle(command(action, -1.0))
            await self.controller.handle(command(action, 1.0))
        self.assertEqual(self.driver.last_action, previous_action)
        self.assertEqual(self.driver.last_velocity, previous_velocity)
        self.assertTrue(self.controller.armed)

    async def test_trim_shortcuts_control_postures(self) -> None:
        """T1~T4 的通道变化分别调用四个明确的 Go2 姿态动作。"""

        expected = {
            "trim_t1": "stand_up",
            "trim_t2": "stand_down",
            "trim_t3": "balance_stand",
            "trim_t4": "recovery_stand",
        }
        for trim_action, posture in expected.items():
            await self.controller.handle(command("arm", 1.0))
            await self.controller.handle(command(trim_action, 0.01))
            self.assertEqual(self.driver.last_action, posture)

    async def test_posture_requires_arm_and_does_not_depend_on_stop(self) -> None:
        """姿态动作未解锁时拒绝；执行时不让 StopMove 超时阻断动作。"""

        with self.assertRaises(PermissionError):
            await self.controller.handle(command("stand_up", 1.0))

        await self.controller.handle(command("arm", 1.0))
        await self.controller.handle(command("throttle", 0.5))
        await self.controller.handle(command("stand_up", 1.0))
        self.assertEqual(self.driver.last_action, "stand_up")
        self.assertEqual(
            self.controller.status()["axes"],
            {"throttle": 0.0, "roll": 0.0, "yaw": 0.0},
        )

    async def test_explicit_damp_still_damps_and_disarms(self) -> None:
        """界面显式发送 damp 时仍执行阻尼模式并立即锁定。"""

        await self.controller.handle(command("arm", 1.0))
        await self.controller.handle(command("damp", 1.0))
        self.assertEqual(self.driver.last_action, "damp")
        self.assertFalse(self.controller.armed)
        self.assertFalse(self.driver.external_control_enabled)

    def test_protocol_rejects_out_of_range_value(self) -> None:
        """协议层必须拒绝超出 [-1, 1] 的归一化值。"""

        with self.assertRaises(ProtocolError):
            GatewayCommand.from_message(
                {"sequence": 1, "action": "yaw", "normalized": 2.0}
            )


if __name__ == "__main__":
    unittest.main()


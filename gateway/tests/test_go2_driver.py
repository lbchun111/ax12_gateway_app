"""验证Go2运行期健康检查使用Sport API而不是不稳定的ICMP。"""

import unittest

from gateway.drivers.go2 import Go2RobotDriver


class Go2RobotDriverTest(unittest.TestCase):
    """覆盖ICMP丢包和Sport RPC失败两种状态。"""

    def test_probe_keeps_connection_when_sport_works(self) -> None:
        """Sport RPC成功时保持在线。"""

        class Client:
            def GetServerApiVersion(self):
                return 0, "1.0.0.1"

        driver = Go2RobotDriver("eth1")
        driver._client = Client()

        self.assertTrue(driver.probe())

        snapshot = driver.snapshot()
        self.assertTrue(snapshot["connected"])
        self.assertEqual(snapshot["serverApiVersion"], "1.0.0.1")

    def test_probe_keeps_connection_when_diagnostic_rpc_times_out(self) -> None:
        """诊断版本RPC超时不拆除客户端，动作返回码仍会单独校验。"""

        class Client:
            def GetServerApiVersion(self):
                return 3102, None

        driver = Go2RobotDriver("eth1")
        driver._client = Client()
        driver._next_probe_at = 0

        self.assertTrue(driver.probe())

        snapshot = driver.snapshot()
        self.assertTrue(snapshot["connected"])
        self.assertIn("3102", snapshot["connectionError"])

    def test_external_control_switches_builtin_joystick(self) -> None:
        """取得外部控制权时关闭内置摇杆，释放时重新启用。"""

        class Client:
            def __init__(self):
                self.values = []

            def SwitchJoystick(self, value):
                self.values.append(value)
                return 0

        client = Client()
        driver = Go2RobotDriver("eth0")
        driver._client = client

        self.assertEqual(driver.set_external_control(True), 0)
        self.assertEqual(driver.set_external_control(False), 0)
        self.assertEqual(client.values, [False, True])
        self.assertFalse(driver.snapshot()["externalControl"])


if __name__ == "__main__":
    unittest.main()

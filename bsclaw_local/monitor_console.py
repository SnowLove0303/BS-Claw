from __future__ import annotations

from typing import Any

from .console_common import ConsoleIO
from .monitor import ResourceMonitor


class MonitorConsole:
    def __init__(self, application: Any) -> None:
        self.app = application
        self.io = ConsoleIO()
        self.monitor = ResourceMonitor(application.paths)

    def center(self) -> None:
        while True:
            state = self.monitor.status()
            print("\n后台资源检测")
            if state.get("status") == "stopped":
                print("状态：后台检测已停止")
            elif state.get("status") == "failed":
                print(f"状态：后台检测启动失败（{state.get('errorCode') or '未知原因'}）")
                print(f"下一步：{state.get('nextAction') or '重新选择启动或恢复'}")
            elif state.get("alive") and not state.get("stale"):
                print("状态：后台检测运行中")
            elif state.get("alive") and not state.get("heartbeatAt"):
                print("状态：后台检测启动中，正在完成首轮检查")
            elif state.get("pid"):
                print("状态：后台检测未运行或心跳已过期")
            else:
                print("状态：后台检测尚未启动")
            print(f"最近心跳：{state.get('heartbeatAt') or '暂无'}")
            resources = state.get("resources") or {}
            print(f"已记录资源：{len(resources)} 个")
            print("1. 启动或恢复后台检测")
            print("2. 刷新检测状态")
            print("3. 停止后台检测")
            print("0. 返回")
            choice = self.io.input("请选择").strip()
            if choice == "0":
                return
            if choice == "1":
                current = self.monitor.start()
                print("已发出启动请求；后台检测会先显示‘启动中’，完成首轮检查后显示真实心跳。")
            elif choice == "2":
                state = self.monitor.status()
                if state.get("status") == "failed":
                    print(f"后台检测启动失败：{state.get('nextAction') or '请重新启动'}")
                elif state.get("status") == "stopped":
                    print("后台检测已停止。")
                else:
                    print("已刷新。" if state.get("alive") and not state.get("stale") else "后台检测未运行或状态已过期。")
            elif choice == "3":
                if not self.io.confirm("确定停止后台检测吗？"):
                    print("已取消，没有改变后台检测。")
                    continue
                current = self.monitor.stop()
                print(f"后台检测已停止，当前状态：{current.get('status')}")
            else:
                print("请输入 0 到 3。")

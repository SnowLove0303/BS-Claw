from __future__ import annotations

import argparse
import os
import time

from .cli import LocalApplication
from .paths import ProjectPaths
from .models import now_iso
from .scheduler_models import STATE_FAILED
from .scheduler_store import SchedulerDataError, SchedulerStore


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--task-id", required=True)
    args = parser.parse_args()
    paths = ProjectPaths.discover()
    store = SchedulerStore(paths.data_root)
    try:
        application = LocalApplication(paths)
        for _ in range(50):
            task = application.scheduler.store.load(args.task_id)
            if int(task.get("workerPid") or 0) == os.getpid():
                break
            if task.get("state") != "执行中":
                return 0
            time.sleep(0.1)
        else:
            return 2
        application.scheduler.run_worker(args.task_id)
    except SchedulerDataError:
        return 2
    except Exception as exc:
        task = store.load(args.task_id)
        if task.get("state") not in {
            "成功",
            "失败",
            "已取消",
            "超时",
            "未验证",
            "阻断",
        }:
            store.transition(
                task,
                STATE_FAILED,
                stage="worker",
                summary="任务执行进程发生未处理异常",
                error_code=f"TASK_WORKER_{type(exc).__name__.upper()}",
                next_action="保留 taskId 并检查服务适配器契约后重试",
                retryable=True,
                source="worker",
                extra={"finishedAt": now_iso()},
            )
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

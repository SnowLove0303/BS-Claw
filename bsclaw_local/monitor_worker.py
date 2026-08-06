import json
import traceback
import sys
from pathlib import Path

from .monitor import run_worker
from .paths import ProjectPaths
from .models import now_iso

if __name__ == "__main__":
    try:
        exit_code = run_worker(sys.argv[1] if len(sys.argv) > 1 else "")
    except BaseException as exc:
        # Keep failure evidence on F: so the parent can explain a dead worker.
        try:
            paths = ProjectPaths.discover()
            root = paths.data_root / "monitor"
            root.mkdir(parents=True, exist_ok=True)
            state_path = root / "state.json"
            try:
                state = json.loads(state_path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                state = {}
            state.update({
                "status": "failed",
                "alive": False,
                "failedAt": now_iso(),
                "errorCode": "MONITOR_WORKER_EXCEPTION",
                "errorType": type(exc).__name__,
                "errorMessage": str(exc)[:300],
                "tracebackPath": str(root / "diagnostics" / "last-worker-traceback.log"),
                "nextAction": "查看 F 盘监控诊断后重新启动后台检测",
            })
            state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")
            trace_path = root / "diagnostics" / "last-worker-traceback.log"
            trace_path.parent.mkdir(parents=True, exist_ok=True)
            trace_path.write_text(traceback.format_exc(), encoding="utf-8")
        except Exception:
            pass
        raise
    raise SystemExit(exit_code)

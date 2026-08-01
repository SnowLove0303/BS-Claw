from __future__ import annotations

import sys

from .app_context import LocalApplication
from .cli_handlers import handle_service, handle_task
from .cli_output import print_human, print_json, print_task
from .cli_parser import build_parser
from .paths import PathConfigurationError, ProjectPaths


def main(argv: list[str] | None = None) -> int:
    _configure_console()
    args = build_parser().parse_args(argv)
    try:
        app = LocalApplication(ProjectPaths.discover())
    except PathConfigurationError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    command = args.command or "menu"
    if command == "menu":
        return app.menu()
    if command == "port-manager":
        return app.port_manager.open_menu()
    if command in {"task", "service"}:
        result = handle_task(app, args) if command == "task" else handle_service(app, args)
        (print_json if getattr(args, "as_json", False) else print_task)(result)
        return 0 if result["success"] else 1

    result = app.execute(
        command,
        no_record=bool(getattr(args, "no_record", False)),
        target=getattr(args, "target", "本地服务整体"),
        audit_type=getattr(args, "audit_type", "状态审计"),
        task_limit=getattr(args, "limit", 20),
    )
    (print_json if getattr(args, "as_json", False) else lambda value: print_human(command, value))(result)
    return 0 if result["success"] else 1


def _configure_console() -> None:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    if hasattr(sys.stderr, "reconfigure"):
        sys.stderr.reconfigure(encoding="utf-8")


__all__ = ["LocalApplication", "main"]

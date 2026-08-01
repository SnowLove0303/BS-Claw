from __future__ import annotations

import argparse


TARGETS = ("本地服务整体", "端口管理", "慧策资源", "统一调度")
AUDIT_TYPES = ("状态审计", "真实路径审计", "接口只读审计", "模块可用性审计")


def _output_options(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--json", action="store_true", dest="as_json")
    parser.add_argument("--no-record", action="store_true")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="bsclaw", description="BS Claw 统一调度与端口管理入口", allow_abbrev=False
    )
    commands = parser.add_subparsers(dest="command")
    for name in ("status", "resources", "huice", "modules", "diagnose"):
        _output_options(commands.add_parser(name))
    audit = commands.add_parser("audit")
    audit.add_argument("--target", choices=TARGETS, default="本地服务整体")
    audit.add_argument("--audit-type", choices=AUDIT_TYPES, default="状态审计")
    _output_options(audit)
    tasks = commands.add_parser("tasks")
    tasks.add_argument("--json", action="store_true", dest="as_json")
    tasks.add_argument("--limit", type=int, default=20)
    _add_task_parser(commands)
    _add_service_parser(commands)
    commands.add_parser("port-manager")
    commands.add_parser("menu")
    return parser


def _add_task_parser(commands: argparse._SubParsersAction) -> None:
    task = commands.add_parser("task")
    operations = task.add_subparsers(dest="task_command", required=True)
    submit = operations.add_parser("submit")
    submit.add_argument("--module", required=True, dest="module_id")
    submit.add_argument("--action", required=True)
    parameters = submit.add_mutually_exclusive_group()
    parameters.add_argument("--params", dest="params_path")
    parameters.add_argument("--param-json")
    submit.add_argument("--resource-id", "--resource", default="", dest="resource_id")
    submit.add_argument("--timeout-seconds", type=int, default=300)
    submit.add_argument("--json", action="store_true", dest="as_json")
    for name in ("status", "result", "cancel", "retry"):
        operation = operations.add_parser(name)
        operation.add_argument("--task-id", required=True)
        operation.add_argument("--json", action="store_true", dest="as_json")
    listing = operations.add_parser("list")
    listing.add_argument("--limit", type=int, default=50)
    listing.add_argument("--json", action="store_true", dest="as_json")
    operations.add_parser("recover").add_argument("--json", action="store_true", dest="as_json")


def _add_service_parser(commands: argparse._SubParsersAction) -> None:
    service = commands.add_parser("service")
    operations = service.add_subparsers(dest="service_command", required=True)
    operations.add_parser("list").add_argument("--json", action="store_true", dest="as_json")
    check = operations.add_parser("check")
    check.add_argument("--service", required=True, dest="service_id")
    check.add_argument("--timeout-seconds", type=int, default=90)
    check.add_argument("--json", action="store_true", dest="as_json")

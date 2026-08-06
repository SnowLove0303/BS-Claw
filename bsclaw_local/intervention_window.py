from __future__ import annotations

import argparse
import json
import socket
import tkinter as tk
from tkinter import messagebox, ttk


def _send(args: argparse.Namespace, action: str, values: dict[str, str] | None = None) -> None:
    payload = {"nonce": args.nonce, "action": action, "values": values or {}}
    with socket.create_connection(("127.0.0.1", args.port), timeout=10) as conn:
        conn.sendall((json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8"))


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--nonce", required=True)
    parser.add_argument("--taskName", default="登录任务")
    parser.add_argument("--resource", default="未指定资源")
    parser.add_argument("--reason", default="需要人工输入或确认")
    parser.add_argument("--mode", choices=("login", "verification"), default="login")
    parser.add_argument("--localRoot", required=True)
    args = parser.parse_args()

    root = tk.Tk()
    root.title("BS Claw - 人工处理")
    root.geometry("520x380")
    root.resizable(False, False)
    root.attributes("-topmost", True)
    root.protocol("WM_DELETE_WINDOW", lambda: (_send(args, "cancel"), root.destroy()))

    frame = ttk.Frame(root, padding=18)
    frame.pack(fill="both", expand=True)
    ttk.Label(frame, text=args.taskName, font=("Microsoft YaHei UI", 14, "bold")).pack(anchor="w")
    ttk.Label(frame, text=f"资源：{args.resource}").pack(anchor="w", pady=(8, 0))
    ttk.Label(frame, text=f"等待原因：{args.reason}", wraplength=470).pack(anchor="w", pady=(4, 12))

    fields: dict[str, ttk.Entry] = {}
    if args.mode == "login":
        for key, label, secret in (("tenant", "企业/卖家账号", False), ("account", "操作员/用户账号", False), ("password", "密码（不回显）", True)):
            ttk.Label(frame, text=label).pack(anchor="w")
            entry = ttk.Entry(frame, show="*" if secret else "")
            entry.pack(fill="x", pady=(2, 7))
            fields[key] = entry
        agreement = tk.BooleanVar(value=False)
        ttk.Checkbutton(frame, text="我已阅读并同意慧策服务协议", variable=agreement).pack(anchor="w", pady=(0, 12))
    else:
        agreement = tk.BooleanVar(value=True)
        ttk.Label(frame, text="请在同一资源页面完成验证，完成后点击“继续”。", wraplength=470).pack(anchor="w", pady=(0, 12))

    buttons = ttk.Frame(frame)
    buttons.pack(fill="x", side="bottom")

    def submit() -> None:
        if args.mode == "login":
            values = {key: entry.get() for key, entry in fields.items()}
            if not all(values.values()) or not agreement.get():
                messagebox.showwarning("需要完成输入", "请填写三项账号信息并确认服务协议。", parent=root)
                return
            _send(args, "submit", values)
            for entry in fields.values():
                entry.delete(0, tk.END)
        else:
            _send(args, "continue")
        root.destroy()

    def cancel() -> None:
        _send(args, "cancel")
        root.destroy()

    ttk.Button(buttons, text="继续/提交", command=submit).pack(side="left")
    ttk.Button(buttons, text="取消", command=cancel).pack(side="right")
    root.lift()
    root.focus_force()
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


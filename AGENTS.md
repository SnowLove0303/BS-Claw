# BS-Claw repository rules

## Scope

- `PortManager-Phase1` is the resource, lease, audit, and current-state authority.
- `HuiceLoginAgent` is the controlled Huice login and API-evidence adapter.
- The two modules are delivered as sibling directories. Plugins, schedulers, MCP clients, and UI code pass `ResourceId`; they never receive plaintext credentials.

## Safety

- Runtime data, browser profiles, databases, logs, caches, test runs, and credentials are not versioned.
- Never commit passwords, tokens, cookies, authorization headers, credential values, real resource/session records, or browser storage.
- `PortManager-Phase1/data/ports.json` is an empty bootstrap list only. Runtime SQLite is created on first use.
- All generated data must remain on drive `F:` unless the user explicitly authorizes another drive.

## Verification

- Use `PortManager-Phase1/port-manager.ps1` as the public PortManager entry.
- Run `PortManager-Phase1/tests/run-static-validation.ps1` before delivery.
- The final interactive Huice login acceptance path is PowerShell `Read-Host`, explicit service-agreement confirmation, same-origin HTTP login, ERP/API probe, persisted Detail/Occupancy state, and non-interactive reuse.
- External captcha, SMS, slider, QR, or secondary verification must be reported as an external blocker, never as a successful automated login.

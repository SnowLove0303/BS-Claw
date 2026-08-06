# BS-Claw PortManager Phase 1 rules

## Scope

- PortManager owns resource definitions, runtime status, leases, audit records, and SQLite persistence.
- `HuiceLoginAgent` is the sibling controlled login adapter; PortManager must not duplicate its login implementation.
- Product, order, inventory, distribution, pricing, and after-sales workflows belong to later plugins.

## Safety

- Runtime data, profiles, logs, backups, caches, IPC, and temporary files stay on drive F and are not committed.
- Never persist or print passwords, cookies, tokens, full authorization headers, or browser storage.
- A listening port, reachable browser, or matching page is not proof of login. Only the live auth refresh and required read-only API probe can produce `logged-in-api-ready`.
- Editing, deleting, cleaning, or resetting a resource must honor leases, process identity, explicit confirmation, audit, and rollback rules.

## Verification

- `port-manager.ps1` is the only public PortManager entry.
- JSON mode emits exactly one JSON envelope.
- Static and zero-data checks may be automated. Real login requires the documented PowerShell Read-Host path on an isolated resource; external security challenges remain explicit blockers.

# BS Claw Unified Scheduler Rules

## Scope

- This module is a Python unified scheduler/CLI layer. It coordinates existing public commands and must not reimplement PortManager or Huice login logic.
- `PortManager-Phase1` remains the resource and runtime-status source of truth.
- `HuiceLoginAgent` remains the controlled login adapter.
- Execution modules are registered only through a real manifest and an existing entry. No planning directory is treated as executable.
- The final same-port/cross-port multi-task resource policy is pending user decision. Any action requesting such a policy must stop with `RESOURCE_POLICY_PENDING`.
- This phase must not run selection, distribution, order, inventory, or other business writes.

## Safety

- Never read, print, or persist passwords, cookies, tokens, full authorization headers, CredentialRef values, Profile internals, or raw adapter payloads.
- Use only public JSON commands. Pure display actions do not write service state; a declared `service-state-write` check may update runtime status, timestamps, leases and audit records. Neither class may change schema, resource definitions, credentials, Profiles, caches or external business data.
- Runtime records stay under `data/`, on drive F, and are ignored by Git.
- Python must be resolved from drive F. Do not download dependencies or write caches to drive C.

## Architecture

- Keep entry, path discovery, process execution, PortManager adaptation, Huice adaptation, module registry, scheduler state/store, plugin protocol, diagnostics, and audit summaries separate.
- Prefer relative sibling discovery. Environment overrides must resolve to drive F.
- JSON mode emits exactly one JSON document.
- User-facing output is Chinese and exposes only decisions, safe state, and the next action.

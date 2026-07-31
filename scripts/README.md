# scripts

Developer and release tooling. Each script is self-documenting (a header comment
explains what it does, its inputs, and its outputs). Nothing here uploads to a
store on its own.

- **[release/](release/)** — build/sign/version/preflight scripts for cutting
  Android and iOS store builds. See [release/README.md](release/README.md).
- **[emulator/](emulator/)** — the headless Android permission smoke-test. See
  [emulator/README.md](emulator/README.md).
- **[e2e/local-supabase-auth.mjs](e2e/local-supabase-auth.mjs)** — starts the
  sibling interfaces repository's local Supabase stack when needed, retrieves
  three fresh passwordless codes from local Mailpit without printing them, and
  runs the rendered sign-in plus two-account RLS integration test.

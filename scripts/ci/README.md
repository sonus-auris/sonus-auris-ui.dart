# Desktop CI contracts

`resolve-desktop-build-config.sh` separates **compilation evidence** from
**distributable artifacts**.

Desktop Flutter builds need three compile-time values:

- `SONUS_BACKEND_BASE_URL`
- `SONUS_SUPABASE_URL`
- `SONUS_SUPABASE_ANON_KEY`

A pull request, push, or non-publishing manual run may compile without live
services. If any value is absent, the resolver replaces **all three** with inert
localhost/sentinel values, reports `mode=compile-only`, and reports
`distributable=false`. The workflow still proves that Linux, macOS, or Windows
compiles, but it does not package or upload a binary that could be mistaken for
a configured release.

A manual run with `publish_r2=true` sets `SONUS_REQUIRE_REAL_CONFIG=true`. In
that mode every value is mandatory, URLs must be absolute credential-free
HTTP(S) URLs without query strings or fragments, and the compile-only key is
rejected. Failure messages name missing variables but never print values.

When all repository values are present during an ordinary non-publishing run,
the resolver reports `mode=configured` and allows the build archive to be
retained as a workflow artifact. Only the protected `publish` mode can reach the
R2 publication job.

Run the dependency-free policy suite with:

```sh
bash tests/ci/desktop-build-config.test.sh
```

The test covers empty, partially configured, fully configured, protected
publish, missing publish configuration, credential-bearing URL, invalid boolean,
secret-redaction, and no-partial-output behavior.

The Linux desktop workflow also probes `ayatana-appindicator3-0.1` or
`appindicator3-0.1` with `pkg-config` before Flutter invokes CMake. Keep
`libayatana-appindicator3-dev` in the runner package list while `tray_manager`
requires that native library.

# Flutter pagelet renderer

The Flutter app renders Sonus Auris pagelet v1 documents with Material widgets
compiled into the submitted application binary.

It does **not**:

- evaluate downloaded code or scripts
- add a WebView dependency for interactive pagelets
- expose a JavaScript-to-native bridge
- allow the server to invent actions, components, permissions, or routes
- pass microphone buffers, credentials, encryption keys, unrestricted paths, or
  arbitrary HTTP/database access to pagelet content

Unknown fields, versions, components, and actions fail closed in
`PageletDocument.fromJson`. `PageletSurfaceView` provides a bounded loading state
and a bundled fallback when remote content is unavailable or invalid.

## Transport envelope

`PageletEnvelope.decode` applies the transport boundary before a document reaches
the renderer:

- maximum UTF-8 payload size: 64 KiB
- exact protocol version match
- validated request ID, non-reusable session nonce, host app version, platform,
  and renderer identity
- RFC3339 UTC issuance and expiry checks with a five-minute clock-skew allowance
- per-surface pagelet policy validation
- independent bounded replay detection for request IDs and session nonces

A malformed, oversized, expired, future-dated, replayed, unsupported, or
policy-invalid envelope is rejected and the host shows its bundled fallback.

## Native action dispatch

`PageletActionDispatcher` contains the reviewed action inventory. For each action
it compiles in the required authorization state, native platforms, exact parameter
shape, maximum payload size, timeout, read/mutation classification, and
confirmation requirement.

The `native.confirm-device-rename` example requires AAL2 and a native
confirmation result. Cancelling cannot reach the mutation callback. Confirming
can invoke only the typed rename callback with `deviceId` and `proposedName`; it
cannot gain arbitrary network, database, filesystem, permission, or credential
access.

Interactive mobile and desktop pagelets use the native schema renderer. Any
future content-only HTML surface must first satisfy DEN-1401, remain explicitly
inventoried, disable JavaScript/native bridging on mobile, and preserve a bundled
or cached fallback. Recording, permissions, consent, retention, authentication,
MFA, purchases, account deletion, background capture, playback authorization,
and application shutdown remain native.

## Immutable interface contract

`test/fixtures/pagelets/interface-contract.lock.json` names one full lowercase
commit in `sonus-auris/sonus-auris-interfaces`. It is not a branch, tag, release
alias, or abbreviated SHA. The conformance workflow validates the lock before
network or Flutter work, checks out that exact commit with persisted Git
credentials disabled, and verifies the checkout HEAD did not move.

The interfaces repository is private. The current repository's default
`GITHUB_TOKEN` is intentionally not a cross-repository credential and cannot be
used for this checkout. CI creates a short-lived GitHub App installation token
with GitHub's SHA-pinned `actions/create-github-app-token` action. The token is
scoped to repository `sonus-auris-interfaces` and `contents: read`, is passed only
to the second checkout, is never persisted in Git configuration, and is revoked
by the action's post step.

Provisioning uses:

- organization/repository variable `SONUS_CROSS_REPO_APP_ID`; and
- Actions secret `SONUS_CROSS_REPO_APP_PRIVATE_KEY`.

The App should be organization-owned and installed only where read access is
needed. Do not substitute a personal access token, a pasted chat token, the
workflow's default token, or a reusable user credential. Rotate the App private
key through the organization secret without modifying the lock or report
contract. Pull requests without access to protected secrets can run the
repository's other jobs but cannot claim cross-repository conformance
certification.

The locked interface repository is then treated as executable contract source:

1. install its lockfile;
2. reject stale generated adapters;
3. run its pagelet and release suites;
4. seal its deterministic interface bundle under the locked repository and
   commit identity; and
5. retain the resulting `INTERFACE-BUNDLE.json`, payload manifest, and aggregate
   evidence.

The copied Flutter fixtures remain useful for native unit and widget tests, but
they are not accepted as canonical merely because they exist in this repository.
CI compares the copied scenario inventory and three canonical examples
byte-for-byte with the locked interface checkout before generating a report.
Fixture drift therefore fails before parity evidence is uploaded.

## Provenance-bound conformance report

Flutter emits conformance report version `1.1.0`. The canonical interface
producer derives the report provenance from:

- the sealed interface repository, full commit, payload digest, and bundle
  schema version;
- the exact canonical scenario and report-schema bytes;
- Flutter repository `sonus-auris/sonus-auris-ui.dart`;
- the exact Flutter workflow `GITHUB_SHA`; and
- the current Actions run URL.

`scripts/pagelet_conformance_report.py` will not construct those identities
itself. It requires the canonical provenance document, re-hashes the supplied
scenario and report-schema files, enforces the Flutter host/repository mapping,
validates full lowercase commit/digest shapes and exact keys, and then combines
that identity with the committed coverage inventory.

After generation, the canonical interface certifier validates the complete
report against the same sealed bundle and the expected Flutter repository and
commit. It also checks coverage semantics such as unique scenario IDs, exact
summary counts, evidence for automated scenarios, and notes for inventory-only
or not-applicable scenarios.

The retained 30-day artifact contains:

- immutable interface lock;
- Flutter report version 1.1;
- producer provenance;
- certification evidence;
- sealed interface metadata;
- interface payload manifest; and
- aggregate bundle evidence.

No PAT, checkout token, cookie, request header, environment dump, microphone
data, encryption material, or raw response body belongs in these files.

A report is not parity evidence for another Flutter commit, another interface
payload digest, or a locally modified scenario/schema file. Rust desktop must
produce the same report version against the same locked interface commit and
payload/scenario/schema identities before DEN-1402 can compare host behavior.

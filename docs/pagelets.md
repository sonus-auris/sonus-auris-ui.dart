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

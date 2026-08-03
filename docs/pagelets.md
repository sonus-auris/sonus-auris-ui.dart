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

Interactive mobile and desktop pagelets use the native schema renderer. Any
future content-only HTML surface must first satisfy DEN-1401, remain explicitly
inventoried, disable JavaScript/native bridging on mobile, and preserve a bundled
or cached fallback. Recording, permissions, consent, retention, authentication,
MFA, purchases, account deletion, background capture, playback authorization,
and application shutdown remain native.

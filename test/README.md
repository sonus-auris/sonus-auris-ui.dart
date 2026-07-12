# test

`flutter test` unit tests. Coverage skews toward the pure logic that would be
painful to verify by hand on a device: crypto envelopes, the acoustic detectors,
schedule/transfer gating, sleep-cycle estimation, the Supabase clients, and the
voice pipeline. Each `*_test.dart` targets the like-named source file (e.g.
`segment_cipher_test.dart` ↔ `lib/src/services/crypto/segment_cipher.dart`).

Services keep their platform plugins behind seams (`SecureKeyStore`,
`SchedulePlatform`, injected `http.Client`s, fakes) precisely so these tests run
with no device, network, or microphone.

- **[support/](support/)** — shared test doubles. See [support/README.md](support/README.md).

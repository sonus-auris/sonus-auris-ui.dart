# test/support

Shared test doubles reused across suites (kept out of individual test files so
they don't drift).

- **[in_memory_key_store.dart](in_memory_key_store.dart)** — an in-memory
  `SecureKeyStore` so `KeyManager` / crypto tests run without the platform
  Keychain/Keystore plugin.

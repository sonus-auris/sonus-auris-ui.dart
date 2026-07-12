# lib/src/services/crypto

Zero-knowledge, on-device encryption for recorded audio. Every segment is sealed
on the phone *before* it leaves for the cloud, so our backend and the user's
cloud storage only ever hold ciphertext they cannot read. This is what makes the
"privacy-first" claim structural rather than a policy.

Envelope encryption: a fresh random per-segment **data encryption key (DEK)**
encrypts the audio with AES-256-GCM; the DEK is then wrapped both by the device
**master key** (Keychain/Keystore) and, for multi-device accounts, sealed to the
**account** public key so only the desktop "master" (behind the PIN) can read
every device's audio.

- **[segment_cipher.dart](segment_cipher.dart)** — the envelope format: DEK
  generation, AES-256-GCM seal/open, and the `SegmentEnvelope` container.
- **[key_manager.dart](key_manager.dart)** — device master-key lifecycle and the
  `SecureKeyStore` abstraction (so it's testable without the platform plugin).
- **[flutter_secure_key_store.dart](flutter_secure_key_store.dart)** — the real
  `SecureKeyStore`: iOS Keychain (device-only, non-synced) + Android
  Keystore-backed EncryptedSharedPreferences.
- **[account_recipient.dart](account_recipient.dart)** — X25519 sealed-box
  wrapping of a DEK to the account public key (the desktop-master read path).
- **[segment_encryptor.dart](segment_encryptor.dart)** — the facade the
  upload/download paths use so they never touch key material directly.

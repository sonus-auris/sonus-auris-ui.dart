# iOS encryption export compliance

> Not legal advice. This documents the determination behind
> `ITSAppUsesNonExemptEncryption = false` in `ios/Runner/Info.plist`. Confirm for
> your jurisdictions, especially if you distribute outside the United States.

## What encryption the app uses
- **Transport:** TLS/HTTPS (standard, provided by the OS/networking stack).
- **Data at rest:** **AES-256-GCM** for clip encryption; **HKDF** and **Argon2id**
  for key derivation. All are **standard, published** cryptographic algorithms.
- **No proprietary or non-standard cryptography**, and encryption is **not** the
  app's primary purpose — it protects the user's own recordings.

## Determination
Because the app uses only standard published algorithms for (a) HTTPS and (b)
protecting the user's own data, it qualifies for the encryption exemption
(generally **5D992 / mass-market**, EAR §740.17). We therefore answer "**No**" to
"Does your app use non-exempt encryption?" and set
`ITSAppUsesNonExemptEncryption = false`, which lets uploads skip the per-build
export-compliance questionnaire.

## When this must change to `true`
Set `ITSAppUsesNonExemptEncryption = true` (and complete the export-compliance
flow in App Store Connect) if you later:
- add **proprietary or non-standard** encryption, or
- make encryption a **primary feature** beyond protecting the user's own data
  (e.g. a general-purpose encryption product), or
- exceed the conditions of the mass-market exemption.

## Documentation you may still need
- Even when self-classifying as exempt, US exporters using encryption may need a
  one-time **self-classification report / ERN** to BIS, and a copy to NSA, on an
  annual basis. Standard-algorithm, mass-market apps commonly fall here.
- Some countries have local import/use rules. If you distribute broadly, have
  counsel confirm. France's historical declaration requirement has been relaxed.

## Where it's set
`ios/Runner/Info.plist` → `ITSAppUsesNonExemptEncryption` (`false`). Keep this doc
and that key in sync.

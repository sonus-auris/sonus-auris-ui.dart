# iCloud backup setup (iOS)

Apple exposes no server-side iCloud write API, so iCloud backup is **device-driven**:
the backend marks each segment as a client-managed copy job, and the app downloads
it (short-lived S3 URL) and writes it into the user's iCloud Drive container.

Pieces already in the repo:

- Dart: [`IcloudSyncService`](../lib/src/services/icloud_sync_service.dart) drains
  jobs via the `audio_dashcam/icloud` MethodChannel; `AppController.syncIcloudBackups()`
  runs it after each upload drain when iCloud is the selected provider.
- Native: [`Runner/IcloudBridge.swift`](Runner/IcloudBridge.swift) implements
  `isAvailable` + `importSegment`, registered in `Runner/AppDelegate.swift`.
- [`Runner/Runner.entitlements`](Runner/Runner.entitlements) — capability template.

Until the manual Xcode steps below are done, `isAvailable` returns `false` and the
app simply skips iCloud mirroring (no crash, no error surfaced to the user).

## Manual Xcode steps (once, per Apple account)

1. **Add the Swift file to the target.** In Xcode, ensure `IcloudBridge.swift` is a
   member of the **Runner** target (File Inspector → Target Membership).
2. **Enable the capability.** Runner target → *Signing & Capabilities* → **+ Capability**
   → **iCloud** → check **iCloud Documents**, and add/select an
   `iCloud.<your.bundle.id>` container.
3. **Wire the entitlements.** Xcode normally creates `Runner.entitlements` for you when
   you add the capability. Either let it, or set **Build Settings → Code Signing
   Entitlements** to `Runner/Runner.entitlements` and replace `YOUR.BUNDLE.ID` in that
   file with the real bundle id.
4. **(Optional) Make files visible in the Files app.** Add to `Runner/Info.plist`:

   ```xml
   <key>NSUbiquitousContainers</key>
   <dict>
     <key>iCloud.YOUR.BUNDLE.ID</key>
     <dict>
       <key>NSUbiquitousContainerIsDocumentScopePublic</key><true/>
       <key>NSUbiquitousContainerName</key><string>Sonus Auris</string>
       <key>NSUbiquitousContainerSupportedFolderLevels</key><string>Any</string>
     </dict>
   </dict>
   ```

5. Build to a real device signed into iCloud, link iCloud in the app's Connections tab,
   record + upload, and confirm segments appear under iCloud Drive → Sonus Auris.

The checked-in iOS and macOS release metadata already declare
`iCloud.com.ores.audioDashcam` as a public Documents container. The Apple
Developer App IDs and distribution profiles must authorize that exact container;
otherwise the native bridge deliberately reports iCloud as unavailable.

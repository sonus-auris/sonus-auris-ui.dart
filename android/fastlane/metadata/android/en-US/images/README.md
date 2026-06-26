# Play Store graphic assets

Drop the required images here; `fastlane supply` picks them up by filename.

| File / folder | Spec | Required |
|---|---|---|
| `icon.png` | 512×512 PNG, 32-bit | Yes (or set in console) |
| `featureGraphic.png` | 1024×500 PNG/JPG | Yes |
| `phoneScreenshots/1.png` … | 1080×1920-ish, 2–8 images | Yes (≥2) |
| `sevenInchScreenshots/`, `tenInchScreenshots/` | tablet shots | If you list tablet support |

Notes:
- Screenshots must reflect the actual app (no device frames with fake content).
- Avoid implying covert/secret recording of others in any promo image — it
  triggers Play "deceptive behavior" / sensitive-permission rejections.

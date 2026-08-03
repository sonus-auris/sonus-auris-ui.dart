#!/usr/bin/env python3
"""Cross-platform contracts for Sonus Auris microphone identity and capability."""

from __future__ import annotations

import plistlib
import re
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
IOS_INFO = ROOT / "ios/Runner/Info.plist"
MACOS_INFO = ROOT / "macos/Runner/Info.plist"
MACOS_CONFIG = ROOT / "macos/Runner/Configs/AppInfo.xcconfig"
MACOS_DEBUG_ENTITLEMENTS = ROOT / "macos/Runner/DebugProfile.entitlements"
MACOS_RELEASE_ENTITLEMENTS = ROOT / "macos/Runner/Release.entitlements"
ANDROID_MANIFEST = ROOT / "android/app/src/main/AndroidManifest.xml"
ANDROID_NS = "http://schemas.android.com/apk/res/android"
ANDROID = f"{{{ANDROID_NS}}}"
EXPECTED_NAME = "Sonus Auris"
EXPECTED_MACOS_BUNDLE_ID = "app.sonusauris.audioDashcam"
ANDROID_FOREGROUND_SERVICE = (
    "com.pravera.flutter_foreground_task.service.ForegroundService"
)


def load_plist(content: bytes) -> dict[str, Any]:
    payload = plistlib.loads(content)
    assert isinstance(payload, dict)
    return payload


def parse_xcconfig(content: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in content.splitlines():
        line = raw.strip()
        if not line or line.startswith("//") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def assert_usage_description(value: object, platform: str) -> None:
    assert isinstance(value, str), f"{platform} microphone disclosure is missing"
    normalized = value.lower()
    assert EXPECTED_NAME.lower() in normalized
    assert "record" in normalized
    assert "audio" in normalized or "microphone" in normalized


def validate(
    *,
    ios_info: bytes,
    macos_info: bytes,
    macos_config: str,
    macos_debug_entitlements: bytes,
    macos_release_entitlements: bytes,
    android_manifest: str,
) -> None:
    ios = load_plist(ios_info)
    assert ios.get("CFBundleDisplayName") == EXPECTED_NAME
    assert ios.get("CFBundleName") == EXPECTED_NAME
    assert ios.get("CFBundlePackageType") == "APPL"
    assert_usage_description(ios.get("NSMicrophoneUsageDescription"), "iOS")
    background_modes = ios.get("UIBackgroundModes")
    assert isinstance(background_modes, list)
    assert "audio" in background_modes
    assert ios.get("BGTaskSchedulerPermittedIdentifiers") == [
        "com.pravera.flutter_foreground_task.refresh"
    ]

    macos = load_plist(macos_info)
    assert macos.get("CFBundleDisplayName") == EXPECTED_NAME
    assert macos.get("CFBundleName") == "$(PRODUCT_NAME)"
    assert macos.get("CFBundlePackageType") == "APPL"
    assert_usage_description(macos.get("NSMicrophoneUsageDescription"), "macOS")

    config = parse_xcconfig(macos_config)
    assert config.get("PRODUCT_NAME") == EXPECTED_NAME
    assert config.get("PRODUCT_BUNDLE_IDENTIFIER") == EXPECTED_MACOS_BUNDLE_ID

    for label, content in (
        ("DebugProfile", macos_debug_entitlements),
        ("Release", macos_release_entitlements),
    ):
        entitlements = load_plist(content)
        assert entitlements.get("com.apple.security.app-sandbox") is True, label
        assert entitlements.get("com.apple.security.device.audio-input") is True, label
        assert entitlements.get("com.apple.security.network.client") is True, label

    root = ET.fromstring(android_manifest)
    assert root.tag == "manifest"
    permissions = {
        node.get(ANDROID + "name")
        for node in root.findall("uses-permission")
        if node.get(ANDROID + "name")
    }
    required_permissions = {
        "android.permission.RECORD_AUDIO",
        "android.permission.POST_NOTIFICATIONS",
        "android.permission.FOREGROUND_SERVICE",
        "android.permission.FOREGROUND_SERVICE_MICROPHONE",
    }
    assert required_permissions <= permissions

    application = root.find("application")
    assert application is not None
    assert application.get(ANDROID + "label") == EXPECTED_NAME
    assert application.get(ANDROID + "allowBackup") == "false"
    assert application.get(ANDROID + "usesCleartextTraffic") == "false"

    namespace = {"android": ANDROID_NS}
    service = application.find(
        f"service[@android:name='{ANDROID_FOREGROUND_SERVICE}']",
        namespace,
    )
    assert service is not None
    assert service.get(ANDROID + "exported") == "false"
    service_types = {
        item.strip()
        for item in (service.get(ANDROID + "foregroundServiceType") or "").split("|")
        if item.strip()
    }
    assert "microphone" in service_types
    assert service.get(ANDROID + "stopWithTask") == "false"


def read_sources() -> dict[str, object]:
    return {
        "ios_info": IOS_INFO.read_bytes(),
        "macos_info": MACOS_INFO.read_bytes(),
        "macos_config": MACOS_CONFIG.read_text(encoding="utf-8"),
        "macos_debug_entitlements": MACOS_DEBUG_ENTITLEMENTS.read_bytes(),
        "macos_release_entitlements": MACOS_RELEASE_ENTITLEMENTS.read_bytes(),
        "android_manifest": ANDROID_MANIFEST.read_text(encoding="utf-8"),
    }


def replace_bytes(content: bytes, old: bytes, new: bytes) -> bytes:
    assert old in content
    return content.replace(old, new, 1)


def expect_mutation_failure(sources: dict[str, object], description: str) -> None:
    try:
        validate(**sources)
    except AssertionError:
        return
    raise AssertionError(f"unsafe platform mutation passed: {description}")


def main() -> None:
    sources = read_sources()
    validate(**sources)

    mutated = dict(sources)
    mutated["android_manifest"] = str(sources["android_manifest"]).replace(
        'android:label="Sonus Auris"',
        'android:label="sonus_auris_flutter"',
        1,
    )
    expect_mutation_failure(mutated, "internal Android label")

    mutated = dict(sources)
    mutated["android_manifest"] = re.sub(
        r"\s*<uses-permission android:name=\"android\.permission\.FOREGROUND_SERVICE_MICROPHONE\" />",
        "",
        str(sources["android_manifest"]),
        count=1,
    )
    expect_mutation_failure(mutated, "missing Android foreground-microphone permission")

    mutated = dict(sources)
    mutated["android_manifest"] = str(sources["android_manifest"]).replace(
        'android:name="com.pravera.flutter_foreground_task.service.ForegroundService"\n'
        '            android:exported="false"',
        'android:name="com.pravera.flutter_foreground_task.service.ForegroundService"\n'
        '            android:exported="true"',
        1,
    )
    expect_mutation_failure(mutated, "exported Android recording service")

    mutated = dict(sources)
    mutated["ios_info"] = replace_bytes(
        bytes(sources["ios_info"]),
        b"<key>CFBundleDisplayName</key>\n\t<string>Sonus Auris</string>",
        b"<key>CFBundleDisplayName</key>\n\t<string>Runner</string>",
    )
    expect_mutation_failure(mutated, "generic iOS display name")

    mutated = dict(sources)
    mutated["ios_info"] = replace_bytes(
        bytes(sources["ios_info"]),
        b"<key>UIBackgroundModes</key>\n\t<array>\n\t\t<string>audio</string>\n\t</array>",
        b"<key>UIBackgroundModes</key>\n\t<array/>"
    )
    expect_mutation_failure(mutated, "missing iOS audio background mode")

    mutated = dict(sources)
    mutated["macos_config"] = str(sources["macos_config"]).replace(
        "PRODUCT_NAME = Sonus Auris",
        "PRODUCT_NAME = Runner",
        1,
    )
    expect_mutation_failure(mutated, "generic macOS product name")

    mutated = dict(sources)
    mutated["macos_release_entitlements"] = replace_bytes(
        bytes(sources["macos_release_entitlements"]),
        b"<key>com.apple.security.device.audio-input</key>\n\t<true/>",
        b"<key>com.apple.security.device.audio-input</key>\n\t<false/>",
    )
    expect_mutation_failure(mutated, "disabled macOS Release audio-input entitlement")

    mutated = dict(sources)
    mutated["macos_debug_entitlements"] = replace_bytes(
        bytes(sources["macos_debug_entitlements"]),
        b"<key>com.apple.security.device.audio-input</key>\n\t<true/>",
        b"<key>com.apple.security.device.audio-input</key>\n\t<false/>",
    )
    expect_mutation_failure(mutated, "disabled macOS Debug/Profile audio-input entitlement")

    print(
        "platform microphone identity contract passed: iOS identity/disclosure/background + "
        "macOS identity/disclosure/debug+release entitlements + Android label/permissions/"
        "non-exported foreground microphone service + 8 mutation refusals"
    )


if __name__ == "__main__":
    main()

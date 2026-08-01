# Headless Android emulator for Sonus Auris permission testing.
#
# Runs an x86_64 Android emulator with no window and drives the permission smoke
# test against the exact debug APK built from the same source commit. The image
# is intended for a KVM-capable Linux host locally or in the cluster. The
# release workflow records the resulting OCI digest and renders the Kubernetes
# Job with that immutable identity.
FROM ubuntu:22.04

ARG ANDROID_API=34
ARG ANDROID_TARGET=google_apis
ARG ANDROID_ARCH=x86_64
ARG ANDROID_COMMANDLINE_TOOLS_BUILD=15859902
ARG ANDROID_COMMANDLINE_TOOLS_SHA256=23b14d11016f2155158c5bc7a20449a07c8ec8c17e9b0b0fd8a9eb1fd7acb2f5
ARG VCS_REF=unknown
ARG APK_SHA256=unknown

# TARGETARCH is provided by BuildKit (amd64 / arm64). JAVA_HOME is
# architecture-suffixed on Ubuntu.
ARG TARGETARCH=amd64
ENV DEBIAN_FRONTEND=noninteractive \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_HOME=/opt/android-sdk \
    ANDROID_AVD_HOME=/root/.android/avd \
    JAVA_HOME=/usr/lib/jvm/java-17-openjdk-${TARGETARCH}
ENV PATH="$PATH:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/emulator"

LABEL org.opencontainers.image.title="Sonus Auris Android emulator permission runner" \
      org.opencontainers.image.description="Headless Android emulator and exact-commit APK used by the Sonus Auris permission smoke gate" \
      org.opencontainers.image.source="https://github.com/sonus-auris/sonus-auris-ui.dart" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.licenses="MIT" \
      app.sonusauris.apk.sha256="${APK_SHA256}"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      libgl1 \
      libglu1-mesa \
      libnss3 \
      libpulse0 \
      libxcomposite1 \
      libxcursor1 \
      libxdamage1 \
      libxi6 \
      libxrandr2 \
      libxtst6 \
      openjdk-17-jdk-headless \
      python3 \
      socat \
      unzip \
    && rm -rf /var/lib/apt/lists/*

# Pin and verify the exact command-line tools archive advertised by Android.
# The numeric build makes the otherwise `_latest.zip` path immutable; the
# official SHA-256 prevents a substituted or truncated download from entering
# the image.
RUN set -eu; \
    archive="/tmp/commandlinetools-linux-${ANDROID_COMMANDLINE_TOOLS_BUILD}.zip"; \
    curl \
      --fail \
      --location \
      --retry 5 \
      --retry-all-errors \
      --connect-timeout 10 \
      --max-time 300 \
      --output "$archive" \
      "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_COMMANDLINE_TOOLS_BUILD}_latest.zip"; \
    printf '%s  %s\n' "$ANDROID_COMMANDLINE_TOOLS_SHA256" "$archive" | sha256sum --check --strict; \
    mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools"; \
    unzip -q "$archive" -d /tmp/android-commandline-tools; \
    mv /tmp/android-commandline-tools/cmdline-tools "$ANDROID_SDK_ROOT/cmdline-tools/latest"; \
    rm -rf "$archive" /tmp/android-commandline-tools

# Android does not currently publish one repository snapshot identifier that
# locks every sdkmanager package path below. Preserve an installed-package and
# source.properties inventory inside the OCI image so later drift is visible in
# retained CI evidence even when the repository resolves a newer emulator or
# platform-tools revision.
RUN yes | sdkmanager --licenses >/dev/null \
    && sdkmanager --install \
       "platform-tools" \
       "emulator" \
       "platforms;android-${ANDROID_API}" \
       "system-images;android-${ANDROID_API};${ANDROID_TARGET};${ANDROID_ARCH}" >/dev/null \
    && echo "no" | avdmanager create avd \
       -n sonus_ci \
       -k "system-images;android-${ANDROID_API};${ANDROID_TARGET};${ANDROID_ARCH}" \
       -d pixel_6 \
       --force \
    && sdkmanager --list_installed > "$ANDROID_SDK_ROOT/installed-packages.txt" \
    && find "$ANDROID_SDK_ROOT" -type f -name source.properties -print0 \
       | sort -z \
       | xargs -0 -r sha256sum \
       > "$ANDROID_SDK_ROOT/source-properties.sha256"

COPY ci/android-emulator/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/emulator/permission-smoke.sh /usr/local/bin/permission-smoke.sh
COPY build/app/outputs/flutter-apk/app-debug.apk /work/app-under-test.apk
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/permission-smoke.sh \
    && test "$APK_SHA256" != unknown \
    && printf '%s  %s\n' "$APK_SHA256" /work/app-under-test.apk | sha256sum --check --strict

ENV APK_PATH=/work/app-under-test.apk
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

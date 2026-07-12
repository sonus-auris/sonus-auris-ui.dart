# Headless Android emulator for Sonus Auris permission testing.
#
# Runs an x86_64 Android emulator with no window, drives the permission
# smoke-test (scripts/emulator/permission-smoke.sh) against a prebuilt APK.
# Designed to run on a KVM-capable Linux host — locally (docker run --device
# /dev/kvm) or on the cluster (see k8s/emulator-permission-test.job.yaml). The
# emulator needs hardware virtualization; without /dev/kvm it falls back to a
# software renderer that is too slow to boot reliably.
FROM ubuntu:22.04

ARG ANDROID_API=34
ARG ANDROID_TARGET=google_apis
ARG ANDROID_ARCH=x86_64
ARG CMDLINE_TOOLS_VERSION=11076708   # Android cmdline-tools (stable)

ENV DEBIAN_FRONTEND=noninteractive \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_HOME=/opt/android-sdk \
    ANDROID_AVD_HOME=/root/.android/avd \
    JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
ENV PATH="$PATH:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/emulator"

RUN apt-get update && apt-get install -y --no-install-recommends \
      openjdk-17-jdk-headless curl unzip ca-certificates \
      libpulse0 libgl1 libglu1-mesa libnss3 libxcursor1 libxdamage1 \
      libxrandr2 libxcomposite1 libxi6 libxtst6 socat \
    && rm -rf /var/lib/apt/lists/*

# Android command-line tools -> cmdline-tools/latest
RUN mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools" && cd /tmp \
    && curl -fsSL -o tools.zip \
       "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_VERSION}_latest.zip" \
    && unzip -q tools.zip && rm tools.zip \
    && mv cmdline-tools "$ANDROID_SDK_ROOT/cmdline-tools/latest"

# SDK packages + system image, and create the AVD.
RUN yes | sdkmanager --licenses >/dev/null \
    && sdkmanager --install \
       "platform-tools" "emulator" \
       "platforms;android-${ANDROID_API}" \
       "system-images;android-${ANDROID_API};${ANDROID_TARGET};${ANDROID_ARCH}" >/dev/null \
    && echo "no" | avdmanager create avd -n sonus_ci \
       -k "system-images;android-${ANDROID_API};${ANDROID_TARGET};${ANDROID_ARCH}" \
       -d pixel_6 --force

COPY ci/android-emulator/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/emulator/permission-smoke.sh /usr/local/bin/permission-smoke.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/permission-smoke.sh

# The APK to test is provided at run time (bind-mount or baked into a derived
# image) and its path passed via APK_PATH (default below).
ENV APK_PATH=/work/app-release.apk
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

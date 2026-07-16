package dev.flutter.plugins.integration_test;

import androidx.annotation.NonNull;

import io.flutter.embedding.engine.plugins.FlutterPlugin;

/**
 * Release-only no-op for a Flutter 3.44 generated-registrant mismatch.
 *
 * Flutter's generated Android registrant references native plugins from dev
 * dependencies, while its Gradle plugin correctly removes those dependencies
 * from the release classpath. Keeping this tiny implementation in the release
 * source set lets the generated registrant resolve without bundling AndroidX
 * Test, Espresso, or the integration_test plugin in the production app.
 * Debug and profile builds continue to use Flutter's real IntegrationTestPlugin.
 */
public final class IntegrationTestPlugin implements FlutterPlugin {
    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        // Integration testing is intentionally unavailable in production.
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        // Nothing to release.
    }
}

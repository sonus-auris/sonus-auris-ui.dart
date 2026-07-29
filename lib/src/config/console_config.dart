// Build-time configuration for the Sonus Auris console.

/// Console app version reported in the `devices` heartbeat row.
const String kConsoleVersion = '1.0.0';

/// Compile-time configuration, injected with `--dart-define` (see
/// `scripts/with-flags` and `.cli-flags.toml`):
///
/// ```sh
/// flutter run -d chrome \
///   --dart-define=SONUS_SUPABASE_URL=https://<project>.supabase.co \
///   --dart-define=SONUS_SUPABASE_ANON_KEY=sb_publishable_... \
///   --dart-define=SONUS_STRIPE_PAYMENT_LINK=https://buy.stripe.com/...
/// ```
class ConsoleConfig {
  const ConsoleConfig({
    required this.supabaseUrl,
    required this.supabaseAnonKey,
    this.stripePaymentLink = '',
    this.authRedirectUrl = 'sonusauris-console://auth/callback',
  });

  /// Reads the compile-time environment.
  const ConsoleConfig.fromEnvironment()
    : supabaseUrl = const String.fromEnvironment('SONUS_SUPABASE_URL'),
      supabaseAnonKey = const String.fromEnvironment('SONUS_SUPABASE_ANON_KEY'),
      stripePaymentLink = const String.fromEnvironment(
        'SONUS_STRIPE_PAYMENT_LINK',
      ),
      authRedirectUrl = const String.fromEnvironment(
        'SONUS_AUTH_REDIRECT_URL',
        defaultValue: 'sonusauris-console://auth/callback',
      );

  /// Supabase project URL, e.g. `https://abc.supabase.co`.
  final String supabaseUrl;

  /// Supabase anon/publishable key. Never a secret or service-role key —
  /// every client enforces this at request time via the shared key policy.
  final String supabaseAnonKey;

  /// Stripe Checkout payment-link URL used by the Billing screen on web and
  /// desktop only. Empty disables the upgrade button ("Payments not
  /// configured").
  final String stripePaymentLink;

  /// Exact application URI registered with Supabase and the operating system
  /// for passwordless magic-link callbacks.
  final String authRedirectUrl;

  bool get isConfigured =>
      supabaseUrl.trim().isNotEmpty && supabaseAnonKey.trim().isNotEmpty;

  Uri get authRedirectUri {
    final uri = Uri.parse(authRedirectUrl.trim());
    if (!uri.hasScheme || uri.host.isEmpty) {
      throw const FormatException(
        'The auth redirect URL must include a scheme and host.',
      );
    }
    return uri;
  }
}

// Store-compliant subscription billing for the mobile app (Sonus Auris Plus).
//
// COMPLIANCE NOTES — read before changing:
// * Apple (App Review 3.1.1) and Google (Play Payments policy) REQUIRE that
//   digital subscriptions sold inside the mobile app go through App Store /
//   Play Billing in-app purchase. No Stripe, no external checkout links on
//   iOS. Stripe exists only in the separate web/desktop console app.
// * The client NEVER grants itself entitlements. The store purchase produces
//   verification data (App Store receipt / Play purchase token) which is sent
//   to the backend; only the backend — after verifying with Apple/Google —
//   writes the `entitlements` row with its service-role key. The client then
//   re-reads entitlements from Supabase (RLS: select-only).
// * BACKEND TODO: POST /api/mobile/v1/billing/app-store-receipt and
//   POST /api/mobile/v1/billing/play-purchase do not exist server-side yet.
//   Until they land, this client treats a 404 as "verification pending server
//   support" and logs it instead of failing the purchase flow.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:in_app_purchase/in_app_purchase.dart';

import '../models/app_config.dart';
import '../models/cloud_secrets.dart';

/// Store product id for the Sonus Auris Plus auto-renewing subscription. Must
/// exist (with this exact id) in both App Store Connect and Play Console.
const String kSonusPlusMonthlyProductId = 'sonus_plus_monthly';

/// Backend verification endpoints (do not exist yet — see BACKEND TODO above).
const String kAppStoreReceiptPath = '/api/mobile/v1/billing/app-store-receipt';
const String kPlayPurchasePath = '/api/mobile/v1/billing/play-purchase';

/// Pure route selection so tests can pin the platform → endpoint mapping.
/// Returns null for platforms that must never talk to store billing.
String? billingVerificationPath(String platformName) {
  switch (platformName.trim().toLowerCase()) {
    case 'ios':
      return kAppStoreReceiptPath;
    case 'android':
      return kPlayPurchasePath;
    default:
      return null;
  }
}

/// Outcome of posting store verification data to the backend.
enum BillingVerificationStatus {
  /// Backend accepted the receipt/token; entitlements should be re-fetched.
  accepted,

  /// Backend endpoint is not implemented yet (404) — expected until the
  /// billing endpoints land server-side.
  pendingServerSupport,

  /// The call failed (network/server error or unsupported platform).
  failed,
}

typedef BillingVerificationResult = ({
  BillingVerificationStatus status,
  String? error,
});

/// Minimal seam over the `in_app_purchase` plugin so the service (and its
/// tests) never touch the platform singleton directly.
abstract class StorePurchaseGateway {
  Stream<List<PurchaseDetails>> get purchaseStream;
  Future<bool> isAvailable();
  Future<ProductDetailsResponse> queryProductDetails(Set<String> ids);
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam});
  Future<void> restorePurchases();
  Future<void> completePurchase(PurchaseDetails purchase);
}

/// Production gateway backed by [InAppPurchase.instance]. Only constructed on
/// Android/iOS — the plugin has no implementation elsewhere.
class _PluginStorePurchaseGateway implements StorePurchaseGateway {
  _PluginStorePurchaseGateway() : _plugin = InAppPurchase.instance;

  final InAppPurchase _plugin;

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => _plugin.purchaseStream;

  @override
  Future<bool> isAvailable() => _plugin.isAvailable();

  @override
  Future<ProductDetailsResponse> queryProductDetails(Set<String> ids) =>
      _plugin.queryProductDetails(ids);

  @override
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam}) =>
      _plugin.buyNonConsumable(purchaseParam: purchaseParam);

  @override
  Future<void> restorePurchases() => _plugin.restorePurchases();

  @override
  Future<void> completePurchase(PurchaseDetails purchase) =>
      _plugin.completePurchase(purchase);
}

/// Drives the Sonus Auris Plus subscription purchase and hands every store
/// purchase update to the backend for verification.
class BillingService {
  BillingService({
    StorePurchaseGateway? gateway,
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 20),
    bool? platformSupportsStoreBilling,
    String? platformName,
  }) : _injectedGateway = gateway,
       _httpClient = httpClient ?? http.Client(),
       platformName = platformName ?? _detectPlatformName(),
       platformSupportsStoreBilling =
           platformSupportsStoreBilling ??
           (Platform.isAndroid || Platform.isIOS);

  final StorePurchaseGateway? _injectedGateway;
  final http.Client _httpClient;
  final Duration requestTimeout;

  /// `android` / `ios` / other `Platform.operatingSystem` values.
  final String platformName;

  /// Store billing exists only on Android/iOS; every entry point no-ops
  /// elsewhere (desktop upgrades happen in the web console via Stripe).
  final bool platformSupportsStoreBilling;

  StorePurchaseGateway? _gateway;
  StreamSubscription<List<PurchaseDetails>>? _purchaseSubscription;

  /// Called (best effort) after the backend accepts a purchase so the app can
  /// re-fetch entitlements. Wired by the controller.
  Future<void> Function()? onEntitlementsShouldRefresh;

  /// Diagnostic sink (message, {isError}) wired by the controller.
  void Function(String message, {bool isError})? onLog;

  /// Providers for the current config/secrets, wired by the controller so the
  /// async purchase stream always verifies against fresh state.
  AppConfig Function()? configProvider;
  CloudSecrets Function()? secretsProvider;

  StorePurchaseGateway? get _store {
    if (!platformSupportsStoreBilling) {
      return null;
    }
    return _gateway ??= _injectedGateway ?? _PluginStorePurchaseGateway();
  }

  static String _detectPlatformName() {
    if (Platform.isIOS) {
      return 'ios';
    }
    if (Platform.isAndroid) {
      return 'android';
    }
    return Platform.operatingSystem;
  }

  /// Starts listening to store purchase updates. Safe to call once at app
  /// init; a no-op off Android/iOS.
  void start() {
    final store = _store;
    if (store == null || _purchaseSubscription != null) {
      return;
    }
    _purchaseSubscription = store.purchaseStream.listen(
      (purchases) => unawaited(_onPurchaseUpdates(purchases)),
      onError: (Object error) =>
          _log('Store purchase stream error: $error', isError: true),
    );
  }

  /// Whether the device's store is reachable and billing-capable.
  Future<bool> available() async {
    final store = _store;
    if (store == null) {
      return false;
    }
    try {
      return await store.isAvailable();
    } catch (error) {
      _log('Store availability check failed: $error', isError: true);
      return false;
    }
  }

  /// Store metadata (localized price included) for the Plus subscription.
  Future<List<ProductDetails>> products() async {
    final store = _store;
    if (store == null) {
      return const [];
    }
    try {
      final response = await store.queryProductDetails(const {
        kSonusPlusMonthlyProductId,
      });
      if (response.notFoundIDs.isNotEmpty) {
        _log(
          'Store products not found: ${response.notFoundIDs.join(', ')}.',
          isError: true,
        );
      }
      return response.productDetails;
    } catch (error) {
      _log('Store product query failed: $error', isError: true);
      return const [];
    }
  }

  /// Launches the store purchase sheet for the Plus subscription. Returns
  /// false when the flow could not even start (no store, unknown product).
  /// The eventual outcome arrives on the purchase stream.
  Future<bool> buyPlus() async {
    final store = _store;
    if (store == null) {
      _log('Store billing is only available on Android and iOS.');
      return false;
    }
    final details = await products();
    final product = details
        .where((product) => product.id == kSonusPlusMonthlyProductId)
        .firstOrNull;
    if (product == null) {
      _log(
        'The Plus subscription is not available in this store right now.',
        isError: true,
      );
      return false;
    }
    try {
      return await store.buyNonConsumable(
        purchaseParam: PurchaseParam(productDetails: product),
      );
    } catch (error) {
      _log('Store purchase could not start: $error', isError: true);
      return false;
    }
  }

  /// Replays completed purchases (required "Restore purchases" affordance).
  Future<void> restorePurchases() async {
    final store = _store;
    if (store == null) {
      return;
    }
    try {
      await store.restorePurchases();
    } catch (error) {
      _log('Restoring purchases failed: $error', isError: true);
    }
  }

  Future<void> _onPurchaseUpdates(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      await handlePurchaseUpdate(purchase);
    }
  }

  /// Processes one purchase update from the store. Public for tests.
  Future<void> handlePurchaseUpdate(PurchaseDetails purchase) async {
    switch (purchase.status) {
      case PurchaseStatus.pending:
        _log('Store purchase pending for ${purchase.productID}.');
        return;
      case PurchaseStatus.canceled:
        _log('Store purchase canceled for ${purchase.productID}.');
        await _completeIfNeeded(purchase);
        return;
      case PurchaseStatus.error:
        _log(
          'Store purchase failed: ${purchase.error?.message ?? 'unknown error'}.',
          isError: true,
        );
        await _completeIfNeeded(purchase);
        return;
      case PurchaseStatus.purchased:
      case PurchaseStatus.restored:
        break;
    }
    // Never self-grant: hand the store's proof to the backend and let it write
    // the entitlements row after verifying with Apple/Google.
    final config = configProvider?.call();
    final secrets = secretsProvider?.call();
    if (config != null && secrets != null) {
      final result = await submitPurchaseVerification(
        config: config,
        secrets: secrets,
        productId: purchase.productID,
        verificationData: purchase.verificationData.serverVerificationData,
        transactionId: purchase.purchaseID,
      );
      switch (result.status) {
        case BillingVerificationStatus.accepted:
          _log('Purchase verified for ${purchase.productID}.');
          await onEntitlementsShouldRefresh?.call();
        case BillingVerificationStatus.pendingServerSupport:
          _log(
            'Purchase recorded by the store; server-side verification is not '
            'deployed yet (404). Entitlements will sync once it ships.',
          );
        case BillingVerificationStatus.failed:
          _log(
            'Purchase verification failed: ${result.error ?? 'unknown error'}',
            isError: true,
          );
      }
    } else {
      _log(
        'Purchase received but app config/secrets are unavailable; '
        'verification deferred to restore.',
        isError: true,
      );
    }
    // Always acknowledge with the store; unacknowledged purchases are refunded
    // by Play and re-delivered forever by StoreKit.
    await _completeIfNeeded(purchase);
  }

  Future<void> _completeIfNeeded(PurchaseDetails purchase) async {
    if (!purchase.pendingCompletePurchase) {
      return;
    }
    final store = _store;
    if (store == null) {
      return;
    }
    try {
      await store.completePurchase(purchase);
    } catch (error) {
      _log('Completing the store purchase failed: $error', isError: true);
    }
  }

  /// Sends store verification data to the backend billing endpoint for this
  /// platform. Kept side-effect free besides the HTTP call so tests can cover
  /// every branch with a mock HTTP client.
  Future<BillingVerificationResult> submitPurchaseVerification({
    required AppConfig config,
    required CloudSecrets secrets,
    required String productId,
    required String verificationData,
    String? transactionId,
    String? platformOverride,
  }) async {
    final path = billingVerificationPath(platformOverride ?? platformName);
    if (path == null) {
      return (
        status: BillingVerificationStatus.failed,
        error: 'Store billing is not supported on this platform.',
      );
    }
    if (config.backendBaseUrl.trim().isEmpty) {
      return (
        status: BillingVerificationStatus.failed,
        error: 'Backend URL is not configured.',
      );
    }
    if (!secrets.hasSupabaseToken) {
      return (
        status: BillingVerificationStatus.failed,
        error: 'Sign in before purchasing.',
      );
    }
    final Uri uri;
    try {
      uri = _backendUri(config, path);
    } on FormatException catch (error) {
      return (status: BillingVerificationStatus.failed, error: error.message);
    }
    try {
      final response = await _httpClient
          .post(
            uri,
            headers: {
              'content-type': 'application/json',
              'accept': 'application/json',
              'x-supabase-auth': 'Bearer ${secrets.supabaseAccessToken.trim()}',
              if (secrets.hasBackendDeviceToken)
                'authorization': 'Bearer ${secrets.backendDeviceToken.trim()}',
            },
            body: jsonEncode({
              'productId': productId,
              'verificationData': verificationData,
              'transactionId': ?transactionId,
            }),
          )
          .timeout(requestTimeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return (status: BillingVerificationStatus.accepted, error: null);
      }
      if (response.statusCode == 404) {
        return (
          status: BillingVerificationStatus.pendingServerSupport,
          error: null,
        );
      }
      return (
        status: BillingVerificationStatus.failed,
        error:
            'Billing verification failed (${response.statusCode}): '
            '${_shortBody(response.body)}',
      );
    } catch (error) {
      return (
        status: BillingVerificationStatus.failed,
        error: 'Billing verification error: $error',
      );
    }
  }

  Uri _backendUri(AppConfig config, String path) {
    final base = Uri.parse(config.backendBaseUrl.trim());
    if (base.host.trim().isEmpty) {
      throw const FormatException('Backend URL must include a host.');
    }
    if (base.scheme != 'https' &&
        base.host != 'localhost' &&
        base.host != '127.0.0.1') {
      throw const FormatException(
        'Backend URL must use HTTPS except localhost development.',
      );
    }
    final baseSegments = base.pathSegments.where((part) => part.isNotEmpty);
    return base.replace(
      pathSegments: [
        ...baseSegments,
        ...path.split('/').where((part) => part.isNotEmpty),
      ],
      query: '',
      fragment: '',
    );
  }

  void _log(String message, {bool isError = false}) {
    onLog?.call(message, isError: isError);
  }

  String _shortBody(String body) {
    final trimmed = body.trim();
    return trimmed.length > 200 ? trimmed.substring(0, 200) : trimmed;
  }

  Future<void> dispose() async {
    await _purchaseSubscription?.cancel();
    _purchaseSubscription = null;
    _httpClient.close();
  }
}

// Stripe Checkout link construction (web/desktop upgrade flow only).

/// Builds the Stripe Checkout URI for a payment link, attributing the
/// purchase to the signed-in Supabase user: the backend Stripe webhook reads
/// `client_reference_id` (the Supabase user id) off the completed Checkout
/// session and writes the `entitlements` row for that user, and
/// `prefilled_email` pre-populates the Checkout email field.
///
/// Query parameters already present on the payment link are preserved.
Uri buildCheckoutUri({
  required String paymentLink,
  required String userId,
  required String email,
}) {
  final base = Uri.parse(paymentLink.trim());
  return base.replace(
    queryParameters: {
      ...base.queryParameters,
      'client_reference_id': userId,
      if (email.trim().isNotEmpty) 'prefilled_email': email.trim(),
    },
  );
}

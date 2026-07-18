import 'package:audio_dashcam/src/services/billing_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('billingVerificationPath', () {
    test('iOS receipts go to the App Store verification endpoint', () {
      expect(billingVerificationPath('ios'), kAppStoreReceiptPath);
    });

    test('Android purchases go to the Play verification endpoint', () {
      expect(billingVerificationPath('android'), kPlayPurchasePath);
    });

    test('non-store platforms have no billing endpoint (Stripe lives in the console)', () {
      expect(billingVerificationPath('macos'), isNull);
      expect(billingVerificationPath('windows'), isNull);
      expect(billingVerificationPath('linux'), isNull);
      expect(billingVerificationPath('web'), isNull);
      expect(billingVerificationPath(''), isNull);
    });

    test('is case/whitespace tolerant', () {
      expect(billingVerificationPath(' iOS '), kAppStoreReceiptPath);
      expect(billingVerificationPath('ANDROID'), kPlayPurchasePath);
    });
  });

  test('the Plus product id is stable (must match the store listings)', () {
    expect(kSonusPlusMonthlyProductId, 'sonus_plus_monthly');
  });
}

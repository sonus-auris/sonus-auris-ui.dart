import 'package:audio_dashcam/src/app/authenticated_capture_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AuthenticatedCapturePolicy', () {
    test('sign-out pauses active capture and sign-in requests resume', () {
      final policy = AuthenticatedCapturePolicy(
        accountRequired: true,
        signedIn: true,
      );
      expect(policy.signedOut(isRecording: true, isStarting: false), isTrue);
      expect(policy.mayRecord, isFalse);
      expect(policy.resumePending, isTrue);
      expect(policy.signedIn(), isTrue);
      policy.resumedSuccessfully();
      expect(policy.resumePending, isFalse);
    });

    test('sign-out while stopped does not invent recording intent', () {
      final policy = AuthenticatedCapturePolicy(
        accountRequired: true,
        signedIn: true,
      );
      expect(policy.signedOut(isRecording: false, isStarting: false), isFalse);
      expect(policy.signedIn(), isFalse);
    });

    test('explicit keep-recording choice leaves active capture authorized', () {
      final policy = AuthenticatedCapturePolicy(
        accountRequired: true,
        signedIn: true,
      );
      expect(
        policy.signedOut(
          isRecording: true,
          isStarting: false,
          keepRecording: true,
        ),
        isFalse,
      );
      expect(policy.mayRecord, isTrue);
      expect(policy.allowsSignedOutRecording, isTrue);
      expect(policy.signedIn(), isFalse);
      expect(policy.allowsSignedOutRecording, isFalse);
    });

    test('in-flight start is active and first factor cannot consume it', () {
      final policy = AuthenticatedCapturePolicy(
        accountRequired: true,
        signedIn: true,
      );
      expect(policy.signedOut(isRecording: false, isStarting: true), isTrue);
      policy.updateAccountState(accountRequired: true, signedIn: false);
      expect(policy.mayRecord, isFalse);
      expect(policy.resumePending, isTrue);
    });

    test('explicit stop cancels persisted intent', () {
      final policy = AuthenticatedCapturePolicy(
        accountRequired: true,
        signedIn: false,
        resumePending: true,
        allowSignedOutRecording: true,
      );
      policy.stoppedExplicitly();
      expect(policy.resumePending, isFalse);
      expect(policy.allowsSignedOutRecording, isFalse);
    });

    test('local-only configuration does not require an account', () {
      final policy = AuthenticatedCapturePolicy(
        accountRequired: false,
        signedIn: false,
      );
      expect(policy.mayRecord, isTrue);
    });
  });
}

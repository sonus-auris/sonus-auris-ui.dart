import 'package:audio_dashcam/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only a fresh signed-in transition forces Home', () {
    expect(
      didCompleteSignIn(previousSignedIn: false, isSignedIn: true),
      isTrue,
    );
    expect(
      didCompleteSignIn(previousSignedIn: null, isSignedIn: true),
      isFalse,
      reason: 'restoring a session may restore the previously selected tab',
    );
    expect(
      didCompleteSignIn(previousSignedIn: true, isSignedIn: true),
      isFalse,
    );
    expect(
      didCompleteSignIn(previousSignedIn: true, isSignedIn: false),
      isFalse,
    );
  });

  test('Home reset survives onboarding until the app shell handles it', () {
    final policy = FreshSignInHomePolicy();

    policy.observe(false);
    policy.observe(true);
    expect(policy.pending, isTrue);

    policy.observe(true);
    policy.observe(true);
    expect(
      policy.pending,
      isTrue,
      reason: 'authenticated emissions during onboarding cannot consume it',
    );

    policy.markHandled();
    expect(policy.pending, isFalse);
    policy.observe(true);
    expect(policy.pending, isFalse);
  });

  test('session restoration and sign-out never leave a pending Home reset', () {
    final restored = FreshSignInHomePolicy()..observe(true);
    expect(restored.pending, isFalse);

    final signedOut = FreshSignInHomePolicy()
      ..observe(false)
      ..observe(true)
      ..observe(false);
    expect(signedOut.pending, isFalse);
  });
}

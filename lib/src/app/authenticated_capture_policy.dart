/// Pure state machine for the recording/authentication boundary.
///
/// Production capture requires a completed passwordless AAL2 session whenever
/// Supabase account configuration is present. Losing that session pauses an
/// active (or currently-starting) recorder and remembers the user's intent;
/// completing AAL2 later consumes that intent only after capture is live again.
class AuthenticatedCapturePolicy {
  factory AuthenticatedCapturePolicy({
    required bool accountRequired,
    required bool signedIn,
    bool resumePending = false,
    bool allowSignedOutRecording = false,
  }) => AuthenticatedCapturePolicy._(
    accountRequired,
    signedIn,
    resumePending,
    allowSignedOutRecording,
  );

  AuthenticatedCapturePolicy._(
    this._accountRequired,
    this._signedIn,
    this._resumePending,
    this._allowSignedOutRecording,
  );

  bool _accountRequired;
  bool _signedIn;
  bool _resumePending;
  bool _allowSignedOutRecording;

  bool get mayRecord =>
      !_accountRequired || _signedIn || _allowSignedOutRecording;
  bool get resumePending => _resumePending;
  bool get allowsSignedOutRecording => _allowSignedOutRecording;

  void updateAccountState({
    required bool accountRequired,
    required bool signedIn,
  }) {
    _accountRequired = accountRequired;
    _signedIn = signedIn;
  }

  bool signedOut({
    required bool isRecording,
    required bool isStarting,
    bool keepRecording = false,
  }) {
    _signedIn = false;
    final wasActive = isRecording || isStarting;
    _allowSignedOutRecording = wasActive && keepRecording;
    if (wasActive && !keepRecording) {
      _resumePending = true;
    } else if (keepRecording) {
      _resumePending = false;
    }
    return wasActive && !keepRecording;
  }

  bool signedIn() {
    _signedIn = true;
    _allowSignedOutRecording = false;
    return mayRecord && _resumePending;
  }

  void stoppedExplicitly() {
    _resumePending = false;
    _allowSignedOutRecording = false;
  }

  void resumedSuccessfully() {
    _resumePending = false;
  }
}

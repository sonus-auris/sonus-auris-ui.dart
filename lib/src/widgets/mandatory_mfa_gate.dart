import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app/app_controller.dart';
import '../models/account_status.dart';
import '../models/supabase_mfa.dart';

/// Full-screen security gate shown after the passwordless first factor.
///
/// A Supabase AAL1 session is intentionally insufficient: a new account must
/// enroll TOTP or phone MFA, and returning accounts must verify an existing
/// factor. Only [AppController.verifyMfaFactor] can clear this gate with the
/// fresh AAL2 session returned by GoTrue.
class MandatoryMfaGate extends StatefulWidget {
  const MandatoryMfaGate({super.key, required this.controller});

  final AppController controller;

  @override
  State<MandatoryMfaGate> createState() => _MandatoryMfaGateState();
}

class _MandatoryMfaGateState extends State<MandatoryMfaGate> {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  TotpEnrollment? _totpEnrollment;
  PhoneEnrollment? _phoneEnrollment;
  String? _factorId;
  String? _challengeId;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AccountStatus>(
      stream: widget.controller.accountStatus,
      initialData: widget.controller.accountStatusValue,
      builder: (context, snapshot) {
        final status = snapshot.data ?? const AccountStatus();
        return Scaffold(
          body: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: status.mfaEnrollmentRequired
                        ? _enrollmentBody()
                        : _challengeBody(status),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _header(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.hearing, size: 30),
            SizedBox(width: 10),
            Text(
              'Sonus Auris',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text(title, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(subtitle),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _enrollmentBody() {
    final enrollment = _totpEnrollment ?? _phoneEnrollment;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(
          'Protect your account',
          'Your email code verified your email. Two-factor authentication is '
              'required before account-backed features are unlocked.',
        ),
        if (enrollment == null) ...[
          FilledButton.icon(
            key: const ValueKey('mandatory-mfa-totp-button'),
            onPressed: _busy ? null : _startTotpEnrollment,
            icon: const Icon(Icons.qr_code_2),
            label: const Text('Use authenticator app'),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('mandatory-mfa-phone-field'),
            controller: _phone,
            enabled: !_busy,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Phone number',
              hintText: '+15551234567',
              prefixIcon: Icon(Icons.phone_outlined),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const ValueKey('mandatory-mfa-phone-button'),
            onPressed: _busy ? null : _startPhoneEnrollment,
            icon: const Icon(Icons.sms_outlined),
            label: const Text('Send verification text'),
          ),
        ] else ...[
          if (_totpEnrollment case final totp?) ...[
            const Text(
              'Scan this code with your authenticator app, then enter its '
              '6-digit code.',
            ),
            const SizedBox(height: 12),
            if (totp.uri.isNotEmpty)
              Center(
                child: ColoredBox(
                  color: Colors.white,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: QrImageView(data: totp.uri, size: 180),
                  ),
                ),
              ),
            if (totp.secret.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(
                key: const ValueKey('mandatory-mfa-totp-secret'),
                totp.secret,
                textAlign: TextAlign.center,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ],
          ] else
            Text('Enter the 6-digit code sent to ${_phoneEnrollment!.phone}.'),
          const SizedBox(height: 14),
          _verificationCodeField(),
          const SizedBox(height: 12),
          FilledButton(
            key: const ValueKey('mandatory-mfa-enrollment-verify-button'),
            onPressed: _canVerify ? _verify : null,
            child: _busy ? const _Spinner() : const Text('Verify and continue'),
          ),
          TextButton(
            onPressed: _busy ? null : _resetEnrollment,
            child: const Text('Choose another method'),
          ),
        ],
        _errorMessage(),
        TextButton(
          onPressed: _busy ? null : widget.controller.signOutSupabase,
          child: const Text('Sign out'),
        ),
      ],
    );
  }

  Widget _challengeBody(AccountStatus status) {
    final factors = status.verifiedMfaFactors;
    final selected = factors
        .where((factor) => factor.id == _factorId)
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(
          'Two-factor authentication',
          'Your email code verified your email. Verify one enrolled method to '
              'finish signing in.',
        ),
        if (_challengeId == null) ...[
          for (final factor in factors)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: OutlinedButton.icon(
                onPressed: _busy ? null : () => _startChallenge(factor),
                icon: Icon(
                  factor.isPhone ? Icons.sms_outlined : Icons.qr_code_2,
                ),
                label: Text(
                  factor.friendlyName.isEmpty
                      ? factor.isPhone
                            ? 'Text message'
                            : 'Authenticator app'
                      : factor.friendlyName,
                ),
              ),
            ),
        ] else ...[
          Text(
            selected?.isPhone == true
                ? 'Enter the code sent to your verified phone.'
                : 'Enter the code from your authenticator app.',
          ),
          const SizedBox(height: 12),
          _verificationCodeField(),
          const SizedBox(height: 12),
          FilledButton(
            key: const ValueKey('mandatory-mfa-challenge-verify-button'),
            onPressed: _canVerify ? _verify : null,
            child: _busy ? const _Spinner() : const Text('Verify and sign in'),
          ),
          TextButton(
            onPressed: _busy ? null : _chooseAnotherFactor,
            child: const Text('Use another method'),
          ),
        ],
        if (factors.isEmpty)
          const Text(
            'No verified factor was returned. Sign out and request a fresh '
            'email code, or contact support.',
          ),
        _errorMessage(),
        TextButton(
          onPressed: _busy ? null : widget.controller.signOutSupabase,
          child: const Text('Sign out'),
        ),
      ],
    );
  }

  Widget _verificationCodeField() {
    return TextField(
      key: const ValueKey('mandatory-mfa-code-field'),
      controller: _code,
      autofocus: true,
      enabled: !_busy,
      keyboardType: TextInputType.number,
      maxLength: 6,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: const InputDecoration(
        labelText: '6-digit verification code',
        counterText: '',
        prefixIcon: Icon(Icons.verified_user_outlined),
      ),
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) {
        if (_canVerify) _verify();
      },
    );
  }

  Widget _errorMessage() {
    if (_error == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(
        _error!,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    );
  }

  bool get _canVerify =>
      !_busy &&
      _factorId != null &&
      _challengeId != null &&
      RegExp(r'^[0-9]{6}$').hasMatch(_code.text.trim());

  Future<void> _startTotpEnrollment() async {
    _setBusy();
    final enrollment = await widget.controller.enrollTotpFactor(
      friendlyName: 'Authenticator',
    );
    final challenge = enrollment == null
        ? null
        : await widget.controller.challengeMfaFactor(enrollment.factorId);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (enrollment == null || challenge == null) {
        _error = 'Could not start authenticator enrollment. Try again.';
        return;
      }
      _totpEnrollment = enrollment;
      _factorId = enrollment.factorId;
      _challengeId = challenge;
    });
  }

  Future<void> _startPhoneEnrollment() async {
    final phone = _phone.text.trim();
    if (!RegExp(r'^\+[1-9][0-9]{7,14}$').hasMatch(phone)) {
      setState(() {
        _error = 'Enter a phone number with country code, like +15551234567.';
      });
      return;
    }
    _setBusy();
    final enrollment = await widget.controller.enrollPhoneFactor(
      phone: phone,
      friendlyName: 'Phone',
    );
    final challenge = enrollment == null
        ? null
        : await widget.controller.challengeMfaFactor(enrollment.factorId);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (enrollment == null || challenge == null) {
        _error = 'Could not send the phone verification code. Try again.';
        return;
      }
      _phoneEnrollment = enrollment;
      _factorId = enrollment.factorId;
      _challengeId = challenge;
    });
  }

  Future<void> _startChallenge(MfaFactor factor) async {
    _setBusy();
    final challenge = await widget.controller.challengeMfaFactor(factor.id);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (challenge == null) {
        _error = 'Could not start the verification challenge. Try again.';
        return;
      }
      _factorId = factor.id;
      _challengeId = challenge;
    });
  }

  Future<void> _verify() async {
    final factor = _factorId;
    final challenge = _challengeId;
    if (factor == null || challenge == null || !_canVerify) return;
    _setBusy();
    final ok = await widget.controller.verifyMfaFactor(
      factorId: factor,
      challengeId: challenge,
      code: _code.text.trim(),
      completesSignIn: true,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!ok) {
        _error = 'That code was not accepted. Request a new challenge.';
        _challengeId = null;
        _code.clear();
      }
    });
  }

  void _setBusy() {
    setState(() {
      _busy = true;
      _error = null;
    });
  }

  void _resetEnrollment() {
    setState(() {
      _totpEnrollment = null;
      _phoneEnrollment = null;
      _factorId = null;
      _challengeId = null;
      _code.clear();
      _error = null;
    });
  }

  void _chooseAnotherFactor() {
    setState(() {
      _factorId = null;
      _challengeId = null;
      _code.clear();
      _error = null;
    });
  }
}

class _Spinner extends StatelessWidget {
  const _Spinner();

  @override
  Widget build(BuildContext context) {
    return const SizedBox.square(
      dimension: 20,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }
}

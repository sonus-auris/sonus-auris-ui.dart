import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app/app_controller.dart';
import '../models/account_status.dart';
import '../models/supabase_mfa.dart';

/// Mandatory second-factor gate shared by mobile and desktop entrypoints.
///
/// An email magic link or code establishes only AAL1. This widget keeps account
/// data closed until the user enrolls or challenges a verified factor and
/// Supabase returns an AAL2 session.
class SupabaseMfaGate extends StatefulWidget {
  const SupabaseMfaGate({
    super.key,
    required this.controller,
    this.onAuthorized,
  });

  final AppController controller;
  final VoidCallback? onAuthorized;

  @override
  State<SupabaseMfaGate> createState() => _SupabaseMfaGateState();
}

class _SupabaseMfaGateState extends State<SupabaseMfaGate> {
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _errorKey = GlobalKey();
  TotpEnrollment? _totp;
  PhoneEnrollment? _phoneEnrollment;
  String? _selectedFactorId;
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
        if (status.mfaCheckFailed) {
          return _failureStep();
        }
        if (status.mfaEnrollmentRequired) {
          return _enrollmentStep();
        }
        if (status.mfaRequired) {
          return _challengeStep(status);
        }
        return const SizedBox.shrink();
      },
    );
  }

  Widget _failureStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'We could not verify your two-factor security. Account access remains '
          'locked.',
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : _retry,
          icon: const Icon(Icons.refresh),
          label: const Text('Retry security check'),
        ),
        _errorText(),
      ],
    );
  }

  Widget _enrollmentStep() {
    final totp = _totp;
    final phoneEnrollment = _phoneEnrollment;
    if (totp != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Set up an authenticator app',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'Scan the QR code, then enter the 6-digit code from your app.',
          ),
          if (totp.uri.isNotEmpty) ...[
            const SizedBox(height: 16),
            Center(
              child: ColoredBox(
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: QrImageView(data: totp.uri, size: 180),
                ),
              ),
            ),
          ],
          if (totp.secret.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    totp.secret,
                    key: const ValueKey('mandatory-mfa-totp-secret'),
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
                IconButton(
                  tooltip: 'Copy secret',
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: totp.secret)),
                  icon: const Icon(Icons.copy),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          _verificationField(),
          _verifyButton(totp.factorId),
          _errorText(),
        ],
      );
    }
    if (phoneEnrollment != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Verify your phone',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text('Enter the code sent to ${phoneEnrollment.phone}.'),
          const SizedBox(height: 12),
          _verificationField(),
          _verifyButton(phoneEnrollment.factorId),
          _errorText(),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Secure your account',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        const Text(
          'Email codes replace passwords, so a verified second factor is '
          'required before account data or cloud sync can be opened.',
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const ValueKey('mandatory-mfa-totp-button'),
          onPressed: _busy ? null : _startTotpEnrollment,
          icon: const Icon(Icons.qr_code_2),
          label: const Text('Use an authenticator app'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _phone,
          enabled: !_busy,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
            labelText: 'Phone in E.164 format',
            hintText: '+15551234567',
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _busy ? null : _startPhoneEnrollment,
          icon: const Icon(Icons.sms_outlined),
          label: const Text('Use this verified phone'),
        ),
        _errorText(),
      ],
    );
  }

  Widget _challengeStep(AccountStatus status) {
    final verified = status.verifiedMfaFactors;
    final selected = verified.any((factor) => factor.id == _selectedFactorId)
        ? _selectedFactorId
        : verified.firstOrNull?.id;
    _selectedFactorId = selected;
    if (selected == null) {
      return _failureStep();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Two-factor verification',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        const Text(
          'Complete your verified second factor to finish signing in.',
        ),
        if (verified.length > 1) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: selected,
            decoration: const InputDecoration(labelText: 'Verify with'),
            items: [
              for (final factor in verified)
                DropdownMenuItem(
                  value: factor.id,
                  child: Text(_factorLabel(factor)),
                ),
            ],
            onChanged: _busy
                ? null
                : (factorId) {
                    setState(() {
                      _selectedFactorId = factorId;
                      _challengeId = null;
                      _code.clear();
                    });
                  },
          ),
        ],
        const SizedBox(height: 12),
        _verificationField(),
        _verifyButton(selected),
        _errorText(),
      ],
    );
  }

  Widget _verificationField() {
    return TextField(
      key: const ValueKey('mandatory-mfa-code-field'),
      controller: _code,
      enabled: !_busy,
      keyboardType: TextInputType.number,
      autofillHints: const [AutofillHints.oneTimeCode],
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(8),
      ],
      decoration: const InputDecoration(labelText: 'Verification code'),
    );
  }

  Widget _verifyButton(String factorId) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: FilledButton.icon(
        key: const ValueKey('mandatory-mfa-enrollment-verify-button'),
        onPressed: _busy ? null : () => _verify(factorId),
        icon: _busy
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.verified_user_outlined),
        label: Text(_busy ? 'Verifying…' : 'Verify and continue'),
      ),
    );
  }

  Widget _errorText() {
    final error = _error;
    if (error == null || error.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      key: _errorKey,
      padding: const EdgeInsets.only(top: 10),
      child: Semantics(
        liveRegion: true,
        child: Text(
          error,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
    );
  }

  Future<void> _retry() async {
    await _run(() async {
      await widget.controller.refreshMfaFactors();
    });
  }

  Future<void> _startTotpEnrollment() async {
    await _run(() async {
      final enrollment = await widget.controller.enrollTotpFactor(
        friendlyName: _newFactorName('authenticator'),
      );
      if (enrollment == null) {
        throw StateError(
          widget.controller.accountStatusValue.mfaCheckFailed
              ? 'Could not verify account security.'
              : _controllerErrorOr('Could not start authenticator enrollment.'),
        );
      }
      setState(() => _totp = enrollment);
    });
  }

  Future<void> _startPhoneEnrollment() async {
    await _run(() async {
      final enrollment = await widget.controller.enrollPhoneFactor(
        phone: _phone.text,
        friendlyName: _newFactorName('phone'),
      );
      if (enrollment == null) {
        throw StateError(
          _controllerErrorOr('Could not start phone enrollment.'),
        );
      }
      final challengeId = await widget.controller.challengeMfaFactor(
        enrollment.factorId,
      );
      if (challengeId == null) {
        throw StateError(
          _controllerErrorOr('Could not send the phone verification code.'),
        );
      }
      setState(() {
        _phoneEnrollment = enrollment;
        _challengeId = challengeId;
      });
    });
  }

  Future<void> _verify(String factorId) async {
    await _run(() async {
      final challengeId =
          _challengeId ?? await widget.controller.challengeMfaFactor(factorId);
      if (challengeId == null) {
        throw StateError(
          _controllerErrorOr('Could not start two-factor verification.'),
        );
      }
      _challengeId = challengeId;
      final verified = await widget.controller.verifyMfaFactor(
        factorId: factorId,
        challengeId: challengeId,
        code: _code.text,
        completesSignIn: true,
      );
      if (!verified) {
        throw StateError(
          _controllerErrorOr('That verification code was not accepted.'),
        );
      }
      widget.onAuthorized?.call();
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      final message = _errorTextFor(error);
      if (mounted) {
        setState(() => _error = message);
        _showErrorToast(message);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final errorContext = _errorKey.currentContext;
          if (errorContext != null) {
            Scrollable.ensureVisible(
              errorContext,
              alignment: 0.5,
              duration: const Duration(milliseconds: 250),
            );
          }
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  String _factorLabel(MfaFactor factor) {
    final name = factor.friendlyName.trim();
    return name.isEmpty ? factor.factorType : '$name (${factor.factorType})';
  }

  String _controllerErrorOr(String fallback) {
    final message = widget.controller.latestMessage?.trim() ?? '';
    return message.isEmpty ? fallback : message;
  }

  String _newFactorName(String factor) {
    final attempt = DateTime.now().toUtc().millisecondsSinceEpoch.toRadixString(
      36,
    );
    return 'Sonus Auris $factor $attempt';
  }

  void _showErrorToast(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 8),
        content: Semantics(liveRegion: true, child: Text(message)),
        action: SnackBarAction(label: 'Dismiss', onPressed: () {}),
      ),
    );
  }

  String _errorTextFor(Object error) {
    if (error is FormatException) {
      return error.message;
    }
    if (error is StateError) {
      return error.message;
    }
    return 'Two-factor verification failed. Try again.';
  }
}

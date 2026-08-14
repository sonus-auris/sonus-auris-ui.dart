import 'package:flutter/material.dart';

import '../app/mfa_gate_controller.dart';
import '../models/supabase_mfa.dart';

/// Fail-closed destructive-account control.
///
/// The user must name the exact signed-in email and complete a fresh challenge
/// against one verified phone or authenticator factor before the irreversible
/// confirmation button is offered. The backend separately enforces the recent
/// second-factor timestamp carried by the resulting access token.
class AccountDeletionSection extends StatefulWidget {
  const AccountDeletionSection({
    super.key,
    required this.controller,
    required this.signedInEmail,
    required this.onDeleteAccount,
  });

  final MfaGateController controller;
  final String signedInEmail;
  final Future<void> Function(String confirmedEmail) onDeleteAccount;

  @override
  State<AccountDeletionSection> createState() => _AccountDeletionSectionState();
}

class _AccountDeletionSectionState extends State<AccountDeletionSection> {
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  List<MfaFactor> _factors = const [];
  String? _selectedFactorId;
  String? _challengeId;
  String? _error;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadFactors();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _loadFactors() async {
    try {
      final factors = await widget.controller.refreshMfaFactors();
      if (!mounted) {
        return;
      }
      final verified = factors
          .where(
            (factor) => factor.isVerified && (factor.isPhone || factor.isTotp),
          )
          .toList(growable: false);
      setState(() {
        _factors = verified;
        _selectedFactorId = verified.firstOrNull?.id;
        _loading = false;
        if (verified.isEmpty) {
          _error =
              'Add and verify a phone or authenticator method before deleting '
              'your account.';
        }
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = _errorText(error);
      });
    }
  }

  MfaFactor? get _selectedFactor =>
      _factors.where((factor) => factor.id == _selectedFactorId).firstOrNull;

  bool get _emailMatches =>
      _emailController.text.trim().toLowerCase() ==
          widget.signedInEmail.trim().toLowerCase() &&
      widget.signedInEmail.trim().isNotEmpty;

  Future<void> _beginChallenge() async {
    if (_busy) {
      return;
    }
    if (!_emailMatches) {
      _showError('Enter the exact signed-in email address to continue.');
      return;
    }
    final factor = _selectedFactor;
    if (factor == null) {
      _showError(
        'Choose a verified phone or authenticator method to continue.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _challengeId = null;
      _codeController.clear();
    });
    try {
      final challenge = await widget.controller.challengeMfaFactor(factor.id);
      if (challenge == null || challenge.trim().isEmpty) {
        throw StateError(
          _controllerErrorOr('Could not start account deletion verification.'),
        );
      }
      if (mounted) {
        setState(() => _challengeId = challenge.trim());
      }
    } catch (error) {
      if (mounted) {
        _showError(_errorText(error));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _verifyAndReviewDeletion() async {
    if (_busy) {
      return;
    }
    if (!_emailMatches) {
      _showError('Enter the exact signed-in email address to continue.');
      return;
    }
    final factor = _selectedFactor;
    final challenge = _challengeId;
    if (factor == null || challenge == null) {
      _showError('Start a fresh phone or authenticator verification first.');
      return;
    }
    final code = _codeController.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      _showError('Enter the 6-digit code from your verified second factor.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final verified = await widget.controller.verifyMfaFactor(
        factorId: factor.id,
        challengeId: challenge,
        code: code,
        completesSignIn: false,
      );
      if (!verified) {
        throw StateError(
          _controllerErrorOr('That two-factor code was not accepted.'),
        );
      }
      _codeController.clear();
      if (!mounted) {
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Permanently delete this account?'),
          content: Text(
            'You confirmed ${widget.signedInEmail} and a fresh '
            '${factor.isPhone ? 'phone' : 'authenticator'} code. This deletes '
            'the account, backend metadata, local recordings, and saved tokens '
            'on this device. Copies in storage you control must be removed there.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const ValueKey('account-deletion-confirm-button'),
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              child: const Text('Delete permanently'),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        await widget.onDeleteAccount(widget.signedInEmail.trim());
      }
    } catch (error) {
      if (mounted) {
        _showError(_errorText(error));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _showError(String message) {
    if (!mounted) {
      return;
    }
    setState(() => _error = message);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 8),
        showCloseIcon: true,
        content: Semantics(liveRegion: true, child: Text(message)),
      ),
    );
  }

  String _controllerErrorOr(String fallback) {
    final message = widget.controller.latestMessage?.trim() ?? '';
    return message.isEmpty ? fallback : message;
  }

  String _errorText(Object error) {
    if (error is FormatException) {
      return error.message;
    }
    if (error is StateError) {
      return error.message;
    }
    return 'Account deletion verification failed. Try again.';
  }

  String _factorLabel(MfaFactor factor) {
    final name = factor.friendlyName.trim();
    if (name.isNotEmpty) {
      return '$name (${factor.isPhone ? 'phone' : 'authenticator'})';
    }
    if (factor.isPhone && factor.phone.trim().isNotEmpty) {
      return 'Phone ${factor.phone.trim()}';
    }
    return factor.isPhone ? 'Verified phone' : 'Authenticator app';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final factor = _selectedFactor;
    return Card(
      key: const ValueKey('account-deletion-section'),
      margin: EdgeInsets.zero,
      color: theme.colorScheme.errorContainer.withValues(alpha: 0.32),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.delete_forever, color: theme.colorScheme.error),
                const SizedBox(width: 10),
                Text('Delete account', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'This irreversible action requires the exact signed-in email and '
              'a fresh code from a verified phone or authenticator app.',
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('account-deletion-email-field'),
              controller: _emailController,
              enabled: !_busy,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Confirm signed-in email',
                hintText: widget.signedInEmail,
              ),
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (_factors.isNotEmpty)
              DropdownButtonFormField<String>(
                key: const ValueKey('account-deletion-factor-field'),
                initialValue: _selectedFactorId,
                decoration: const InputDecoration(
                  labelText: 'Verified second factor',
                ),
                items: [
                  for (final item in _factors)
                    DropdownMenuItem(
                      value: item.id,
                      child: Text(_factorLabel(item)),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (value) => setState(() {
                        _selectedFactorId = value;
                        _challengeId = null;
                        _codeController.clear();
                      }),
              ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const ValueKey('account-deletion-challenge-button'),
              onPressed: _busy || _loading || _factors.isEmpty
                  ? null
                  : _beginChallenge,
              icon: const Icon(Icons.verified_user_outlined),
              label: Text(
                factor?.isPhone == true
                    ? 'Send phone verification code'
                    : 'Start authenticator verification',
              ),
            ),
            if (_challengeId != null) ...[
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('account-deletion-code-field'),
                controller: _codeController,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: '6-digit second-factor code',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const ValueKey('account-deletion-review-button'),
                onPressed: _busy ? null : _verifyAndReviewDeletion,
                style: FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                ),
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.delete_forever),
                label: const Text('Verify and review deletion'),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  key: const ValueKey('account-deletion-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

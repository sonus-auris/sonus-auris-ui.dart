// Account: identity, two-factor management (TOTP + SMS), and sign-out.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/mfa.dart';
import '../services/console_controller.dart';
import 'console_home.dart';

class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key, required this.controller});

  final ConsoleController controller;

  @override
  Widget build(BuildContext context) {
    return ConsolePage(
      title: 'Account',
      onRefresh: controller.refreshFactors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(controller.email.isEmpty ? 'Signed in' : controller.email),
              subtitle: const Text('Signed in with a one-time email code'),
            ),
          ),
          const SizedBox(height: 16),
          Text('Two-factor authentication',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text(
            'Add a second factor so a stolen inbox is not enough to sign in.',
          ),
          const SizedBox(height: 12),
          if (controller.factors.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('No two-factor methods yet.'),
              ),
            )
          else
            for (final factor in controller.factors)
              _FactorTile(controller: controller, factor: factor),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: () => _enrollTotp(context),
                icon: const Icon(Icons.qr_code_2),
                label: const Text('Add authenticator app'),
              ),
              OutlinedButton.icon(
                onPressed: () => _enrollPhone(context),
                icon: const Icon(Icons.sms_outlined),
                label: const Text('Add text message'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: controller.signOut,
              icon: const Icon(Icons.logout),
              label: const Text('Sign out'),
            ),
          ),
          if (controller.message != null && controller.message!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(controller.message!),
            ),
        ],
      ),
    );
  }

  Future<void> _enrollTotp(BuildContext context) async {
    final enrollment = await controller.enrollTotp(name: 'Authenticator');
    if (enrollment == null || !context.mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => _TotpEnrollDialog(
        controller: controller,
        enrollment: enrollment,
      ),
    );
    await controller.refreshFactors();
  }

  Future<void> _enrollPhone(BuildContext context) async {
    final phone = await _promptPhone(context);
    if (phone == null || phone.trim().isEmpty) {
      return;
    }
    final enrollment = await controller.enrollPhone(phone.trim(), name: 'Phone');
    if (enrollment == null || !context.mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => _PhoneVerifyDialog(
        controller: controller,
        enrollment: enrollment,
      ),
    );
    await controller.refreshFactors();
  }

  Future<String?> _promptPhone(BuildContext context) {
    final field = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add a phone number'),
        content: TextField(
          controller: field,
          autofocus: true,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
            labelText: 'Phone (E.164, e.g. +15551234567)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, field.text),
            child: const Text('Send code'),
          ),
        ],
      ),
    );
  }
}

class _FactorTile extends StatelessWidget {
  const _FactorTile({required this.controller, required this.factor});
  final ConsoleController controller;
  final MfaFactor factor;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(factor.isPhone ? Icons.sms_outlined : Icons.qr_code_2),
        title: Text(factor.friendlyName.isNotEmpty ? factor.friendlyName : factor.typeLabel),
        subtitle: Text(
          '${factor.typeLabel}'
          '${factor.isPhone && factor.phone.isNotEmpty ? ' · ${factor.phone}' : ''}'
          ' · ${factor.isVerified ? 'active' : 'pending'}',
        ),
        trailing: IconButton(
          tooltip: 'Remove',
          icon: const Icon(Icons.delete_outline),
          onPressed: () => _remove(context),
        ),
      ),
    );
  }

  Future<void> _remove(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this factor?'),
        content: const Text('You will no longer be asked for this code.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok ?? false) {
      await controller.removeFactor(factor.id);
    }
  }
}

class _TotpEnrollDialog extends StatefulWidget {
  const _TotpEnrollDialog({required this.controller, required this.enrollment});
  final ConsoleController controller;
  final TotpEnrollment enrollment;

  @override
  State<_TotpEnrollDialog> createState() => _TotpEnrollDialogState();
}

class _TotpEnrollDialogState extends State<_TotpEnrollDialog> {
  final _code = TextEditingController();
  String? _challengeId;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.enrollment;
    return AlertDialog(
      title: const Text('Add authenticator app'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Scan this with your authenticator app, then enter the '
                '6-digit code it shows.'),
            const SizedBox(height: 16),
            if (e.uri.isNotEmpty)
              Center(
                child: Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(12),
                  child: QrImageView(data: e.uri, size: 180),
                ),
              ),
            const SizedBox(height: 12),
            if (e.secret.isNotEmpty)
              Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      e.secret,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy secret',
                    icon: const Icon(Icons.copy, size: 18),
                    onPressed: () => Clipboard.setData(ClipboardData(text: e.secret)),
                  ),
                ],
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: '6-digit code'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _verify,
          child: _busy
              ? const SizedBox(
                  height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Verify'),
        ),
      ],
    );
  }

  Future<void> _verify() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    _challengeId ??= await widget.controller.startFactorChallenge(widget.enrollment.factorId);
    final challengeId = _challengeId;
    if (challengeId == null) {
      setState(() {
        _busy = false;
        _error = widget.controller.message ?? 'Could not start verification.';
      });
      return;
    }
    final ok = await widget.controller.confirmFactorEnrollment(
      factorId: widget.enrollment.factorId,
      challengeId: challengeId,
      code: _code.text,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      setState(() {
        _busy = false;
        _error = widget.controller.message ?? 'That code was not accepted.';
      });
    }
  }
}

class _PhoneVerifyDialog extends StatefulWidget {
  const _PhoneVerifyDialog({required this.controller, required this.enrollment});
  final ConsoleController controller;
  final PhoneEnrollment enrollment;

  @override
  State<_PhoneVerifyDialog> createState() => _PhoneVerifyDialogState();
}

class _PhoneVerifyDialogState extends State<_PhoneVerifyDialog> {
  final _code = TextEditingController();
  String? _challengeId;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _sendCode());
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    _challengeId = await widget.controller.startFactorChallenge(widget.enrollment.factorId);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Verify your phone'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('We texted a code to ${widget.enrollment.phone}.'),
          const SizedBox(height: 12),
          TextField(
            controller: _code,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: '6-digit code'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _verify,
          child: _busy
              ? const SizedBox(
                  height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Verify'),
        ),
      ],
    );
  }

  Future<void> _verify() async {
    final challengeId = _challengeId;
    if (challengeId == null) {
      setState(() => _error = 'Still sending the code — try again in a moment.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await widget.controller.confirmFactorEnrollment(
      factorId: widget.enrollment.factorId,
      challengeId: challengeId,
      code: _code.text,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
    } else {
      setState(() {
        _busy = false;
        _error = widget.controller.message ?? 'That code was not accepted.';
      });
    }
  }
}

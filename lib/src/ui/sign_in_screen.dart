// Passwordless sign-in: email → one-time code → (optional) MFA challenge.
// There is no password field anywhere in this flow.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/mfa.dart';
import '../services/console_controller.dart';
import '../theme/console_theme.dart';
import 'account_screen.dart';

class SignInScreen extends StatelessWidget {
  const SignInScreen({super.key, required this.controller});

  final ConsoleController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: _body(context),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    switch (controller.phase) {
      case AuthPhase.codeSent:
        return _CodeStep(controller: controller);
      case AuthPhase.mfaEnrollmentRequired:
        return MfaEnrollmentStep(controller: controller);
      case AuthPhase.mfaRequired:
        return _MfaStep(controller: controller);
      case AuthPhase.loading:
      case AuthPhase.signedOut:
      case AuthPhase.signedIn:
        return _EmailStep(controller: controller);
    }
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.graphic_eq, color: sonusTeal, size: 28),
            const SizedBox(width: 8),
            Text(
              'Sonus Auris',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text(title, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 6),
        Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 20),
      ],
    );
  }
}

Widget _message(BuildContext context, ConsoleController controller) {
  final message = controller.message;
  if (message == null || message.isEmpty) {
    return const SizedBox.shrink();
  }
  return Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Text(
      message,
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    ),
  );
}

class _EmailStep extends StatefulWidget {
  const _EmailStep({required this.controller});
  final ConsoleController controller;

  @override
  State<_EmailStep> createState() => _EmailStepState();
}

class _EmailStepState extends State<_EmailStep> {
  final _email = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final canSubmit = _email.text.trim().contains('@') && !controller.busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Header(
          title: 'Sign in',
          subtitle:
              'Enter your email and we\'ll send a one-time code. No '
              'password needed — new accounts are created automatically.',
        ),
        TextField(
          controller: _email,
          autofocus: true,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          decoration: const InputDecoration(
            labelText: 'Email',
            prefixIcon: Icon(Icons.mail_outline),
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => canSubmit ? _submit() : null,
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: canSubmit ? _submit : null,
          child: controller.busy
              ? const _ButtonSpinner()
              : const Text('Email me a code'),
        ),
        _message(context, controller),
      ],
    );
  }

  void _submit() => widget.controller.sendEmailCode(_email.text);
}

class _CodeStep extends StatefulWidget {
  const _CodeStep({required this.controller});
  final ConsoleController controller;

  @override
  State<_CodeStep> createState() => _CodeStepState();
}

class _CodeStepState extends State<_CodeStep> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final canSubmit = _code.text.trim().length >= 6 && !controller.busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          title: 'Check your email',
          subtitle:
              'Enter the 6-digit code we sent to ${controller.pendingEmail}, '
              'or tap the magic link in the email.',
        ),
        TextField(
          controller: _code,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 8,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: 'Sign-in code',
            prefixIcon: Icon(Icons.pin_outlined),
            counterText: '',
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => canSubmit ? _submit() : null,
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: canSubmit ? _submit : null,
          child: controller.busy
              ? const _ButtonSpinner()
              : const Text('Verify and sign in'),
        ),
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          children: [
            TextButton(
              onPressed: controller.busy ? null : controller.backToEmail,
              child: const Text('Use a different email'),
            ),
            TextButton(
              onPressed: controller.busy ? null : controller.resendEmailCode,
              child: const Text('Resend code'),
            ),
          ],
        ),
        _message(context, controller),
      ],
    );
  }

  void _submit() => widget.controller.verifyEmailCode(_code.text);
}

class _MfaStep extends StatefulWidget {
  const _MfaStep({required this.controller});
  final ConsoleController controller;

  @override
  State<_MfaStep> createState() => _MfaStepState();
}

class _MfaStepState extends State<_MfaStep> {
  final _code = TextEditingController();
  bool _challengeStarted = false;

  @override
  void initState() {
    super.initState();
    // Kick off the challenge for the default factor (sends SMS for phone).
    final factor = widget.controller.pendingChallengeFactor;
    if (factor != null) {
      _challengeStarted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.controller.beginMfaChallenge(factor.id);
      });
    }
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final factor = controller.pendingChallengeFactor;
    final verified = controller.factors.where((f) => f.isVerified).toList();
    final canSubmit = _code.text.trim().length >= 6 && !controller.busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          title: 'Two-factor authentication',
          subtitle: factor?.isPhone == true
              ? 'Enter the code we texted to your phone.'
              : 'Enter the code from your authenticator app.',
        ),
        if (verified.length > 1) ...[
          DropdownButtonFormField<String>(
            initialValue: factor?.id,
            decoration: const InputDecoration(labelText: 'Verify with'),
            items: [
              for (final f in verified)
                DropdownMenuItem(value: f.id, child: Text(_factorLabel(f))),
            ],
            onChanged: controller.busy
                ? null
                : (id) {
                    if (id != null) {
                      _code.clear();
                      controller.beginMfaChallenge(id);
                    }
                  },
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: _code,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 8,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(
            labelText: 'Verification code',
            prefixIcon: Icon(Icons.verified_user_outlined),
            counterText: '',
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => canSubmit ? _submit() : null,
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: canSubmit ? _submit : null,
          child: controller.busy
              ? const _ButtonSpinner()
              : const Text('Verify'),
        ),
        TextButton(
          onPressed: controller.busy ? null : controller.signOut,
          child: const Text('Cancel'),
        ),
        _message(context, controller),
        if (!_challengeStarted && factor == null)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text('No verified factor found for this account.'),
          ),
      ],
    );
  }

  String _factorLabel(MfaFactor f) => f.friendlyName.isNotEmpty
      ? '${f.friendlyName} (${f.typeLabel})'
      : f.typeLabel;

  void _submit() => widget.controller.submitMfaChallenge(_code.text);
}

class _ButtonSpinner extends StatelessWidget {
  const _ButtonSpinner();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 20,
      width: 20,
      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
    );
  }
}

// Reusable, validated passwordless Supabase sign-in surface. A single email +
// one-time-code flow covers both sign-in and sign-up (an unknown address is
// created the moment its first code is verified), so there is no separate
// sign-up mode and nothing to memorize.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/sonus_brand.dart';
import '../theme/sonus_theme.dart';

class SupabaseAuthPanel extends StatefulWidget {
  const SupabaseAuthPanel({
    super.key,
    required this.onRequestCode,
    required this.onSubmitCode,
    this.onBusyChanged,
    this.enabled = true,
    this.title = 'Sign in or create your account',
    this.description =
        'Use one private account across your phone, desktop, and web dashboard. '
        'We email a one-time code to sign you in.',
  });

  /// Emails the sign-in link + one-time code. Returns true when the code was
  /// sent, which reveals the code field.
  final Future<bool> Function(String email) onRequestCode;

  /// Redeems the emailed code, signing the user in (or creating the account on
  /// first use).
  final Future<void> Function(String email, String code) onSubmitCode;
  final ValueChanged<bool>? onBusyChanged;
  final bool enabled;
  final String title;
  final String description;

  @override
  State<SupabaseAuthPanel> createState() => _SupabaseAuthPanelState();
}

enum _PanelBusy { none, request, verify }

class _SupabaseAuthPanelState extends State<SupabaseAuthPanel> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  bool _codeSent = false;
  _PanelBusy _busy = _PanelBusy.none;

  bool get _isBusy => _busy != _PanelBusy.none;

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _run(_PanelBusy phase, Future<void> Function() action) async {
    if (_isBusy) {
      return;
    }
    setState(() => _busy = phase);
    widget.onBusyChanged?.call(true);
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      await action();
    } finally {
      widget.onBusyChanged?.call(false);
      if (mounted) {
        setState(() => _busy = _PanelBusy.none);
      }
    }
  }

  Future<void> _requestCode() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    await _run(_PanelBusy.request, () async {
      final sent = await widget.onRequestCode(_emailController.text.trim());
      if (mounted && sent) {
        setState(() => _codeSent = true);
      }
    });
  }

  Future<void> _resendCode() async {
    await _run(
      _PanelBusy.request,
      () => widget.onRequestCode(_emailController.text.trim()),
    );
  }

  Future<void> _submitCode() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    await _run(
      _PanelBusy.verify,
      () => widget.onSubmitCode(
        _emailController.text.trim(),
        _codeController.text.trim(),
      ),
    );
  }

  void _useDifferentEmail() {
    if (_isBusy) {
      return;
    }
    _codeController.clear();
    setState(() => _codeSent = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!widget.enabled) {
      return const _AuthConfigurationNotice();
    }
    return Semantics(
      container: true,
      label: 'Sonus Auris passwordless account authentication',
      child: AutofillGroup(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: SonusEyebrow('Secure account', icon: Icons.lock_outline),
              ),
              const SizedBox(height: 16),
              Text(widget.title, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 6),
              Text(widget.description, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 20),
              ...(_codeSent ? _codeFields(theme) : _emailFields(theme)),
              const SizedBox(height: 12),
              const _SecurityNote(),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _emailFields(ThemeData theme) => [
    TextFormField(
      key: const ValueKey('supabase-email'),
      controller: _emailController,
      enabled: !_isBusy,
      keyboardType: TextInputType.emailAddress,
      textInputAction: TextInputAction.done,
      autofillHints: const [AutofillHints.username, AutofillHints.email],
      autocorrect: false,
      enableSuggestions: false,
      validator: _validateEmail,
      onFieldSubmitted: (_) => _requestCode(),
      decoration: const InputDecoration(
        labelText: 'Email address',
        hintText: 'you@example.com',
        prefixIcon: Icon(Icons.alternate_email),
      ),
    ),
    const SizedBox(height: 8),
    Text(
      'New here? Signing in creates your account automatically.',
      style: theme.textTheme.bodySmall,
    ),
    const SizedBox(height: 16),
    SonusGradientButton(
      key: const ValueKey('supabase-request-code'),
      label: _busy == _PanelBusy.request
          ? 'Sending…'
          : 'Email me a 6-digit code',
      icon: _busy == _PanelBusy.request
          ? Icons.hourglass_top_rounded
          : Icons.mark_email_read_outlined,
      expand: true,
      onPressed: _isBusy ? null : _requestCode,
    ),
  ];

  List<Widget> _codeFields(ThemeData theme) {
    final email = _emailController.text.trim();
    return [
      Text(
        email.isEmpty
            ? 'Enter the 6-digit code we emailed you.'
            : 'Enter the 6-digit code we emailed to $email.',
        style: theme.textTheme.bodySmall,
      ),
      const SizedBox(height: 12),
      TextFormField(
        key: const ValueKey('supabase-code'),
        controller: _codeController,
        enabled: !_isBusy,
        autofocus: true,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.done,
        autofillHints: const [AutofillHints.oneTimeCode],
        autocorrect: false,
        enableSuggestions: false,
        maxLength: 6,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(6),
        ],
        validator: _validateCode,
        onFieldSubmitted: (_) => _submitCode(),
        decoration: const InputDecoration(
          labelText: '6-digit code',
          hintText: '123456',
          prefixIcon: Icon(Icons.pin_outlined),
          counterText: '',
        ),
      ),
      const SizedBox(height: 16),
      SonusGradientButton(
        key: const ValueKey('supabase-verify-code'),
        label: _busy == _PanelBusy.verify ? 'Signing in…' : 'Sign in securely',
        icon: _busy == _PanelBusy.verify
            ? Icons.hourglass_top_rounded
            : Icons.login,
        expand: true,
        onPressed: _isBusy ? null : _submitCode,
      ),
      const SizedBox(height: 4),
      Row(
        children: [
          TextButton.icon(
            key: const ValueKey('supabase-change-email'),
            onPressed: _isBusy ? null : _useDifferentEmail,
            icon: const Icon(Icons.arrow_back, size: 18),
            label: const Text('Use a different email'),
          ),
          const Spacer(),
          TextButton.icon(
            key: const ValueKey('supabase-resend-code'),
            onPressed: _isBusy ? null : _resendCode,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(_busy == _PanelBusy.request ? 'Sending…' : 'Resend'),
          ),
        ],
      ),
    ];
  }

  String? _validateEmail(String? value) {
    final email = value?.trim() ?? '';
    final at = email.indexOf('@');
    if (email.isEmpty ||
        email.length > 320 ||
        at <= 0 ||
        at == email.length - 1 ||
        !email.substring(at + 1).contains('.')) {
      return 'Enter a valid email address.';
    }
    return null;
  }

  String? _validateCode(String? value) {
    final code = value?.trim() ?? '';
    if (code.length != 6 || int.tryParse(code) == null) {
      return 'Enter the 6-digit code from the email.';
    }
    return null;
  }
}

class _SecurityNote extends StatelessWidget {
  const _SecurityNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: SonusColors.green50,
        border: Border.all(color: SonusColors.green200),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.shield_outlined, size: 19, color: SonusColors.green700),
          SizedBox(width: 9),
          Expanded(
            child: Text(
              'Protected by a one-time Supabase email code and mandatory '
              'two-factor authentication. Sonus Auris does not ask for or '
              'store an account password.',
              style: TextStyle(color: SonusColors.inkSoft, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}

class _AuthConfigurationNotice extends StatelessWidget {
  const _AuthConfigurationNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: SonusColors.green50,
        border: Border.all(color: SonusColors.green200),
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.admin_panel_settings_outlined,
            color: SonusColors.green700,
          ),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Account access is not configured in this build. Continue with '
              'private local recording, or connect a Supabase project later in Settings.',
              style: TextStyle(color: SonusColors.inkSoft, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

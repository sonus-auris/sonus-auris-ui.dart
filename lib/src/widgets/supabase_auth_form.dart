import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/supabase_key_policy.dart';

/// Shared, validated passwordless Supabase sign-in form used during onboarding
/// and from Configure. A single email-code flow covers both sign-in and
/// sign-up (an unknown address gets an account the moment its first code is
/// verified), so keeping both entry points on one widget prevents the first-run
/// and returning-user flows from drifting apart.
class SupabaseAuthForm extends StatefulWidget {
  const SupabaseAuthForm({
    super.key,
    required this.emailController,
    required this.codeController,
    required this.onRequestCode,
    required this.onSubmitCode,
    this.supabaseUrlController,
    this.supabaseAnonKeyController,
    this.showProjectConfiguration = false,
    this.enabled = true,
  });

  final TextEditingController emailController;
  final TextEditingController codeController;
  final TextEditingController? supabaseUrlController;
  final TextEditingController? supabaseAnonKeyController;

  /// Emails the sign-in link + one-time code. Returns true when the code was
  /// sent, which reveals the code field; false leaves the form on the email
  /// step (the caller surfaces why).
  final Future<bool> Function(String email) onRequestCode;

  /// Redeems the emailed code, signing the user in (or creating the account on
  /// first use).
  final Future<void> Function(String email, String code) onSubmitCode;

  final bool showProjectConfiguration;
  final bool enabled;

  @override
  State<SupabaseAuthForm> createState() => _SupabaseAuthFormState();
}

enum _Busy { none, request, verify }

class _SupabaseAuthFormState extends State<SupabaseAuthForm> {
  final _formKey = GlobalKey<FormState>();
  bool _attempted = false;
  bool _codeSent = false;
  _Busy _busy = _Busy.none;
  String? _inlineError;

  bool get _isBusy => _busy != _Busy.none;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled && !_isBusy;
    return Form(
      key: _formKey,
      autovalidateMode: _attempted
          ? AutovalidateMode.onUserInteraction
          : AutovalidateMode.disabled,
      child: AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _codeSent
              ? _codeStep(context, enabled)
              : _emailStep(context, enabled),
        ),
      ),
    );
  }

  List<Widget> _emailStep(BuildContext context, bool enabled) {
    final theme = Theme.of(context);
    return [
      if (widget.showProjectConfiguration) ...[
        _ProjectConfigurationFields(
          urlController: widget.supabaseUrlController,
          anonKeyController: widget.supabaseAnonKeyController,
          enabled: enabled,
        ),
        const SizedBox(height: 16),
      ],
      TextFormField(
        key: const ValueKey('supabase-email-field'),
        controller: widget.emailController,
        enabled: enabled,
        autofillHints: const [AutofillHints.username, AutofillHints.email],
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.emailAddress,
        textInputAction: TextInputAction.done,
        validator: validateAccountEmail,
        onFieldSubmitted: enabled ? (_) => _requestCode() : null,
        decoration: const InputDecoration(
          labelText: 'Email',
          hintText: 'you@example.com',
          prefixIcon: Icon(Icons.alternate_email),
        ),
      ),
      const SizedBox(height: 8),
      Text(
        'New here? Signing in creates your account automatically.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      if (_inlineError != null) _errorBox(context),
      const SizedBox(height: 16),
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          key: const ValueKey('supabase-request-button'),
          onPressed: enabled ? _requestCode : null,
          icon: _busy == _Busy.request
              ? _spinner
              : const Icon(Icons.mark_email_read_outlined),
          label: Text(
            _busy == _Busy.request ? 'Sending…' : 'Email me a 6-digit code',
          ),
        ),
      ),
    ];
  }

  List<Widget> _codeStep(BuildContext context, bool enabled) {
    final theme = Theme.of(context);
    final email = widget.emailController.text.trim();
    return [
      Text('Enter your sign-in code', style: theme.textTheme.titleSmall),
      const SizedBox(height: 4),
      Text(
        email.isEmpty
            ? 'We emailed you a 6-digit sign-in code. Enter it to continue; '
                  'the link is available as a fallback.'
            : 'We emailed a 6-digit sign-in code to $email. Enter it to '
                  'continue; the link is available as a fallback.',
        style: theme.textTheme.bodySmall,
      ),
      const SizedBox(height: 16),
      TextFormField(
        key: const ValueKey('supabase-code-field'),
        controller: widget.codeController,
        enabled: enabled,
        autofocus: true,
        autofillHints: const [AutofillHints.oneTimeCode],
        autocorrect: false,
        enableSuggestions: false,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.done,
        maxLength: 6,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(6),
        ],
        validator: validateEmailOtpCode,
        onFieldSubmitted: enabled ? (_) => _submitCode() : null,
        decoration: const InputDecoration(
          labelText: '6-digit code',
          hintText: '123456',
          prefixIcon: Icon(Icons.pin_outlined),
          counterText: '',
        ),
      ),
      if (_inlineError != null) _errorBox(context),
      const SizedBox(height: 16),
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          key: const ValueKey('supabase-verify-button'),
          onPressed: enabled ? _submitCode : null,
          icon: _busy == _Busy.verify ? _spinner : const Icon(Icons.login),
          label: Text(_busy == _Busy.verify ? 'Signing in…' : 'Sign in'),
        ),
      ),
      const SizedBox(height: 4),
      Row(
        children: [
          TextButton.icon(
            key: const ValueKey('supabase-change-email-button'),
            onPressed: enabled ? _useDifferentEmail : null,
            icon: const Icon(Icons.arrow_back, size: 18),
            label: const Text('Use a different email'),
          ),
          const Spacer(),
          TextButton.icon(
            key: const ValueKey('supabase-resend-button'),
            onPressed: enabled ? _resendCode : null,
            icon: _busy == _Busy.request
                ? _spinner
                : const Icon(Icons.refresh, size: 18),
            label: Text(_busy == _Busy.request ? 'Sending…' : 'Resend'),
          ),
        ],
      ),
    ];
  }

  Widget get _spinner => const SizedBox.square(
    dimension: 18,
    child: CircularProgressIndicator(strokeWidth: 2),
  );

  Widget _errorBox(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Semantics(
        liveRegion: true,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            _inlineError!,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _requestCode() async {
    if (_isBusy || !widget.enabled) {
      return;
    }
    setState(() {
      _attempted = true;
      _inlineError = null;
    });
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    await _sendCode();
  }

  Future<void> _resendCode() async {
    if (_isBusy || !widget.enabled) {
      return;
    }
    setState(() => _inlineError = null);
    await _sendCode();
  }

  Future<void> _sendCode() async {
    setState(() => _busy = _Busy.request);
    final email = widget.emailController.text.trim();
    try {
      final sent = await widget.onRequestCode(email);
      if (mounted && sent) {
        setState(() {
          _codeSent = true;
          // Don't flag the freshly revealed, still-empty code field as invalid.
          _attempted = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _inlineError = describeAuthError(error));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = _Busy.none);
      }
    }
  }

  Future<void> _submitCode() async {
    if (_isBusy || !widget.enabled) {
      return;
    }
    setState(() {
      _attempted = true;
      _inlineError = null;
    });
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    setState(() => _busy = _Busy.verify);
    final email = widget.emailController.text.trim();
    final code = widget.codeController.text.trim();
    try {
      await widget.onSubmitCode(email, code);
    } catch (error) {
      if (mounted) {
        setState(() => _inlineError = describeAuthError(error));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = _Busy.none);
      }
    }
  }

  void _useDifferentEmail() {
    if (_isBusy) {
      return;
    }
    widget.codeController.clear();
    setState(() {
      _codeSent = false;
      _attempted = false;
      _inlineError = null;
    });
  }
}

class _ProjectConfigurationFields extends StatelessWidget {
  const _ProjectConfigurationFields({
    required this.urlController,
    required this.anonKeyController,
    required this.enabled,
  });

  final TextEditingController? urlController;
  final TextEditingController? anonKeyController;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Supabase project connection',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            'This development build has no bundled project. Enter the public '
            'project URL and publishable or anon key; never use a service-role key.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const ValueKey('supabase-url-field'),
            controller: urlController,
            enabled: enabled,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
            validator: validateSupabaseProjectUrl,
            decoration: const InputDecoration(
              labelText: 'Project URL',
              hintText: 'https://your-project.supabase.co',
              prefixIcon: Icon(Icons.link),
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            key: const ValueKey('supabase-anon-key-field'),
            controller: anonKeyController,
            enabled: enabled,
            autocorrect: false,
            enableSuggestions: false,
            obscureText: true,
            keyboardType: TextInputType.visiblePassword,
            textInputAction: TextInputAction.next,
            validator: validateSupabaseAnonKey,
            decoration: const InputDecoration(
              labelText: 'Publishable or anon key',
              prefixIcon: Icon(Icons.key_outlined),
            ),
          ),
        ],
      ),
    );
  }
}

String? validateAccountEmail(String? value) {
  final email = value?.trim() ?? '';
  if (email.isEmpty) {
    return 'Enter your email address.';
  }
  final at = email.indexOf('@');
  final lastAt = email.lastIndexOf('@');
  if (at <= 0 ||
      at != lastAt ||
      at == email.length - 1 ||
      email.contains(' ')) {
    return 'Enter a valid email address.';
  }
  return null;
}

String? validateEmailOtpCode(String? value) {
  final code = value?.trim() ?? '';
  if (code.isEmpty) {
    return 'Enter the 6-digit code from the email.';
  }
  if (code.length != 6 || int.tryParse(code) == null) {
    return 'Enter the 6-digit code from the email.';
  }
  return null;
}

String? validateSupabaseProjectUrl(String? value) {
  final raw = value?.trim() ?? '';
  if (raw.isEmpty) {
    return 'Enter the Supabase project URL.';
  }
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      uri.host.isEmpty ||
      !uri.hasScheme ||
      uri.userInfo.isNotEmpty) {
    return 'Enter a complete project URL.';
  }
  final local = uri.host == 'localhost' || uri.host == '127.0.0.1';
  if (uri.scheme != 'https' && !(local && uri.scheme == 'http')) {
    return 'Use HTTPS (HTTP is allowed only for localhost).';
  }
  return null;
}

String? validateSupabaseAnonKey(String? value) {
  return validateSupabaseClientKey(value);
}

String describeAuthError(Object error) {
  if (error is StateError) {
    return error.message;
  }
  if (error is FormatException) {
    return error.message;
  }
  return 'Authentication failed. Check your connection and try again.';
}

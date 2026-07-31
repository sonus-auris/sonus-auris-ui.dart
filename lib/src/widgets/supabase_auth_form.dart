import 'package:flutter/material.dart';

import '../services/supabase_key_policy.dart';

/// Shared passwordless Supabase magic-link form used by every app surface.
///
/// The same request signs in an existing address or creates a new account.
/// A code field is retained as an optional fallback for projects whose Supabase
/// email template includes `{{ .Token }}` as well as the confirmation link.
class SupabaseAuthForm extends StatefulWidget {
  const SupabaseAuthForm({
    super.key,
    required this.emailController,
    required this.onSendMagicLink,
    required this.onVerifyCode,
    this.supabaseUrlController,
    this.supabaseAnonKeyController,
    this.showProjectConfiguration = false,
    this.enabled = true,
  });

  final TextEditingController emailController;
  final TextEditingController? supabaseUrlController;
  final TextEditingController? supabaseAnonKeyController;
  final Future<bool> Function(String email) onSendMagicLink;
  final Future<bool> Function(String email, String code) onVerifyCode;
  final bool showProjectConfiguration;
  final bool enabled;

  @override
  State<SupabaseAuthForm> createState() => _SupabaseAuthFormState();
}

enum _AuthAction { sendLink, verifyCode }

class _SupabaseAuthFormState extends State<SupabaseAuthForm> {
  final _formKey = GlobalKey<FormState>();
  final _codeController = TextEditingController();
  _AuthAction? _busyAction;
  String? _inlineError;
  bool _linkSent = false;

  bool get _busy => _busyAction != null;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled && !_busy;
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
            autofillHints: const [AutofillHints.email],
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.done,
            validator: validateAccountEmail,
            onFieldSubmitted: enabled ? (_) => _submitLink() : null,
            decoration: const InputDecoration(
              labelText: 'Email',
              hintText: 'you@example.com',
              prefixIcon: Icon(Icons.alternate_email),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'We’ll email a 6-digit Supabase sign-in code. The same code creates '
            'your account on first use—there is no password.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_linkSent) ...[
            const SizedBox(height: 14),
            TextFormField(
              key: const ValueKey('supabase-code-field'),
              controller: _codeController,
              enabled: enabled,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.oneTimeCode],
              validator: (value) => _linkSent ? validateEmailCode(value) : null,
              onFieldSubmitted: enabled ? (_) => _verifyCode() : null,
              decoration: const InputDecoration(
                labelText: '6-digit email code',
                helperText: 'Enter the code from your Sonus Auris email.',
                prefixIcon: Icon(Icons.pin_outlined),
              ),
            ),
          ],
          if (_inlineError != null) ...[
            const SizedBox(height: 12),
            Semantics(
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
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            key: const ValueKey('supabase-send-link-button'),
            onPressed: enabled ? _submitLink : null,
            icon: _actionIcon(_AuthAction.sendLink, Icons.mark_email_read),
            label: Text(
              _busyAction == _AuthAction.sendLink
                  ? 'Sending…'
                  : _linkSent
                  ? 'Send a fresh code'
                  : 'Email me a 6-digit code',
            ),
          ),
          if (_linkSent) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('supabase-verify-code-button'),
              onPressed: enabled ? _verifyCode : null,
              icon: _actionIcon(_AuthAction.verifyCode, Icons.login),
              label: Text(
                _busyAction == _AuthAction.verifyCode
                    ? 'Verifying…'
                    : 'Verify email code',
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Check your inbox and enter the 6-digit code. The one-time link '
              'in the same email is a fallback. You can close '
              'this screen while the email opens Sonus Auris.',
            ),
          ],
        ],
      ),
    );
  }

  Widget _actionIcon(_AuthAction action, IconData fallback) {
    if (_busyAction != action) {
      return Icon(fallback);
    }
    return const SizedBox.square(
      dimension: 18,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }

  bool _validateBaseFields() {
    return _formKey.currentState?.validate() ?? false;
  }

  Future<void> _submitLink() async {
    if (_busy || !widget.enabled) {
      return;
    }
    _codeController.clear();
    setState(() {
      _linkSent = false;
      _inlineError = null;
    });
    if (!_validateBaseFields()) {
      return;
    }
    setState(() => _busyAction = _AuthAction.sendLink);
    try {
      final sent = await widget.onSendMagicLink(
        widget.emailController.text.trim(),
      );
      if (mounted && sent) {
        setState(() => _linkSent = true);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _inlineError = describeAuthError(error));
      }
    } finally {
      if (mounted) {
        setState(() => _busyAction = null);
      }
    }
  }

  Future<void> _verifyCode() async {
    if (_busy || !widget.enabled) {
      return;
    }
    setState(() => _inlineError = null);
    final emailError = validateAccountEmail(widget.emailController.text);
    final codeError = validateEmailCode(_codeController.text);
    if (emailError != null || codeError != null) {
      _formKey.currentState?.validate();
      return;
    }
    setState(() => _busyAction = _AuthAction.verifyCode);
    try {
      await widget.onVerifyCode(
        widget.emailController.text.trim(),
        _codeController.text.trim(),
      );
    } catch (error) {
      if (mounted) {
        setState(() => _inlineError = describeAuthError(error));
      }
    } finally {
      if (mounted) {
        setState(() => _busyAction = null);
      }
    }
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
      email.length > 320 ||
      email.runes.any((rune) => rune <= 0x20 || rune == 0x7f)) {
    return 'Enter a valid email address.';
  }
  return null;
}

String? validateEmailCode(String? value) {
  final code = value?.trim() ?? '';
  if (code.isEmpty) {
    return 'Enter the one-time code from your email.';
  }
  if (code.length != 6 ||
      !code.runes.every((rune) => rune >= 0x30 && rune <= 0x39)) {
    return 'Enter the 6-digit code from your email.';
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

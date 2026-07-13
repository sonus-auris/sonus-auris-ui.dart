import 'package:flutter/material.dart';

import '../services/supabase_key_policy.dart';

/// Shared, validated Supabase email/password form used during onboarding and
/// from Configure. Keeping both entry points on one widget prevents the first
/// run and returning-user flows from drifting apart.
class SupabaseAuthForm extends StatefulWidget {
  const SupabaseAuthForm({
    super.key,
    required this.emailController,
    required this.passwordController,
    required this.onSignIn,
    required this.onSignUp,
    required this.onPasswordReset,
    this.supabaseUrlController,
    this.supabaseAnonKeyController,
    this.showProjectConfiguration = false,
    this.enabled = true,
  });

  final TextEditingController emailController;
  final TextEditingController passwordController;
  final TextEditingController? supabaseUrlController;
  final TextEditingController? supabaseAnonKeyController;
  final Future<void> Function(String email, String password) onSignIn;
  final Future<void> Function(String email, String password) onSignUp;
  final Future<void> Function(String email) onPasswordReset;
  final bool showProjectConfiguration;
  final bool enabled;

  @override
  State<SupabaseAuthForm> createState() => _SupabaseAuthFormState();
}

enum _AuthAction { signIn, signUp, passwordReset }

class _SupabaseAuthFormState extends State<SupabaseAuthForm> {
  final _formKey = GlobalKey<FormState>();
  _AuthAction? _attemptedAction;
  _AuthAction? _busyAction;
  String? _inlineError;
  bool _passwordVisible = false;

  bool get _busy => _busyAction != null;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled && !_busy;
    return Form(
      key: _formKey,
      autovalidateMode: _attemptedAction == null
          ? AutovalidateMode.disabled
          : AutovalidateMode.onUserInteraction,
      child: AutofillGroup(
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
              autofillHints: const [
                AutofillHints.username,
                AutofillHints.email,
              ],
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              validator: validateAccountEmail,
              decoration: const InputDecoration(
                labelText: 'Email',
                hintText: 'you@example.com',
                prefixIcon: Icon(Icons.alternate_email),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const ValueKey('supabase-password-field'),
              controller: widget.passwordController,
              enabled: enabled,
              autofillHints: const [AutofillHints.password],
              autocorrect: false,
              enableSuggestions: false,
              obscureText: !_passwordVisible,
              keyboardType: TextInputType.visiblePassword,
              textInputAction: TextInputAction.done,
              validator: (value) => validateAccountPassword(
                value,
                creatingAccount: _attemptedAction == _AuthAction.signUp,
                passwordRequired: _attemptedAction != _AuthAction.passwordReset,
              ),
              onFieldSubmitted: enabled
                  ? (_) => _submit(_AuthAction.signIn)
                  : null,
              decoration: InputDecoration(
                labelText: 'Password',
                helperText:
                    'Use at least 6 characters when creating an account.',
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  tooltip: _passwordVisible ? 'Hide password' : 'Show password',
                  onPressed: enabled
                      ? () =>
                            setState(() => _passwordVisible = !_passwordVisible)
                      : null,
                  icon: Icon(
                    _passwordVisible
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                ),
              ),
            ),
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
            LayoutBuilder(
              builder: (context, constraints) {
                final stacked = constraints.maxWidth < 390;
                final signIn = FilledButton.icon(
                  key: const ValueKey('supabase-sign-in-button'),
                  onPressed: enabled ? () => _submit(_AuthAction.signIn) : null,
                  icon: _actionIcon(_AuthAction.signIn, Icons.login),
                  label: Text(
                    _busyAction == _AuthAction.signIn
                        ? 'Signing in…'
                        : 'Sign in',
                  ),
                );
                final signUp = OutlinedButton.icon(
                  key: const ValueKey('supabase-sign-up-button'),
                  onPressed: enabled ? () => _submit(_AuthAction.signUp) : null,
                  icon: _actionIcon(
                    _AuthAction.signUp,
                    Icons.person_add_alt_1_outlined,
                  ),
                  label: Text(
                    _busyAction == _AuthAction.signUp
                        ? 'Creating…'
                        : 'Create account',
                  ),
                );
                if (stacked) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [signIn, const SizedBox(height: 10), signUp],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: signIn),
                    const SizedBox(width: 12),
                    Expanded(child: signUp),
                  ],
                );
              },
            ),
            const SizedBox(height: 6),
            TextButton.icon(
              key: const ValueKey('supabase-reset-password-button'),
              onPressed: enabled
                  ? () => _submit(_AuthAction.passwordReset)
                  : null,
              icon: _actionIcon(
                _AuthAction.passwordReset,
                Icons.lock_reset_outlined,
              ),
              label: Text(
                _busyAction == _AuthAction.passwordReset
                    ? 'Sending reset email…'
                    : 'Forgot password?',
              ),
            ),
          ],
        ),
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

  Future<void> _submit(_AuthAction action) async {
    if (_busy || !widget.enabled) {
      return;
    }
    setState(() {
      _attemptedAction = action;
      _inlineError = null;
    });
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    setState(() => _busyAction = action);
    final email = widget.emailController.text.trim();
    try {
      switch (action) {
        case _AuthAction.signIn:
          await widget.onSignIn(email, widget.passwordController.text);
          break;
        case _AuthAction.signUp:
          await widget.onSignUp(email, widget.passwordController.text);
          break;
        case _AuthAction.passwordReset:
          await widget.onPasswordReset(email);
          break;
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

String? validateAccountPassword(
  String? value, {
  required bool creatingAccount,
  bool passwordRequired = true,
}) {
  final password = value ?? '';
  if (!passwordRequired) {
    return null;
  }
  if (password.isEmpty) {
    return 'Enter your password.';
  }
  if (creatingAccount && password.length < 6) {
    return 'Use at least 6 characters.';
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

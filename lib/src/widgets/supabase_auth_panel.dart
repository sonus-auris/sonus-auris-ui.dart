// Reusable, validated Supabase email/password sign-in and sign-up surface.
import 'package:flutter/material.dart';

import '../theme/sonus_brand.dart';
import '../theme/sonus_theme.dart';

enum SupabaseAuthMode { signIn, signUp }

class SupabaseAuthPanel extends StatefulWidget {
  const SupabaseAuthPanel({
    super.key,
    required this.onSignIn,
    required this.onSignUp,
    this.onPasswordReset,
    this.onBusyChanged,
    this.enabled = true,
    this.initialMode = SupabaseAuthMode.signIn,
    this.title = 'Welcome back',
    this.description =
        'Use one private account across your phone, desktop, and web dashboard.',
  });

  final Future<void> Function(String email, String password) onSignIn;
  final Future<void> Function(String email, String password) onSignUp;
  final Future<void> Function(String email)? onPasswordReset;
  final ValueChanged<bool>? onBusyChanged;
  final bool enabled;
  final SupabaseAuthMode initialMode;
  final String title;
  final String description;

  @override
  State<SupabaseAuthPanel> createState() => _SupabaseAuthPanelState();
}

class _SupabaseAuthPanelState extends State<SupabaseAuthPanel> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  late SupabaseAuthMode _mode = widget.initialMode;
  bool _busy = false;
  bool _showPassword = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _selectMode(SupabaseAuthMode mode) {
    if (_busy || mode == _mode) {
      return;
    }
    setState(() {
      _mode = mode;
      _showPassword = false;
    });
    _formKey.currentState?.reset();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    widget.onBusyChanged?.call(true);
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      await action();
    } finally {
      widget.onBusyChanged?.call(false);
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    await _run(
      () => _mode == SupabaseAuthMode.signIn
          ? widget.onSignIn(email, password)
          : widget.onSignUp(email, password),
    );
  }

  Future<void> _resetPassword() async {
    final emailError = _validateEmail(_emailController.text);
    if (emailError != null) {
      _formKey.currentState?.validate();
      return;
    }
    await _run(() => widget.onPasswordReset!(_emailController.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!widget.enabled) {
      return const _AuthConfigurationNotice();
    }
    final signingIn = _mode == SupabaseAuthMode.signIn;
    return Semantics(
      container: true,
      label: 'Sonus Auris account authentication',
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
              SegmentedButton<SupabaseAuthMode>(
                key: const ValueKey('supabase-auth-mode'),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: SupabaseAuthMode.signIn,
                    icon: Icon(Icons.login),
                    label: Text('Sign in'),
                  ),
                  ButtonSegment(
                    value: SupabaseAuthMode.signUp,
                    icon: Icon(Icons.person_add_alt_1),
                    label: Text('Create account'),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: _busy
                    ? null
                    : (selection) => _selectMode(selection.single),
              ),
              const SizedBox(height: 18),
              TextFormField(
                key: const ValueKey('supabase-email'),
                controller: _emailController,
                enabled: !_busy,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.email],
                autocorrect: false,
                enableSuggestions: false,
                validator: _validateEmail,
                decoration: const InputDecoration(
                  labelText: 'Email address',
                  hintText: 'you@example.com',
                  prefixIcon: Icon(Icons.alternate_email),
                ),
              ),
              const SizedBox(height: 14),
              TextFormField(
                key: const ValueKey('supabase-password'),
                controller: _passwordController,
                enabled: !_busy,
                obscureText: !_showPassword,
                keyboardType: TextInputType.visiblePassword,
                textInputAction: TextInputAction.done,
                autofillHints: [
                  signingIn
                      ? AutofillHints.password
                      : AutofillHints.newPassword,
                ],
                autocorrect: false,
                enableSuggestions: false,
                validator: _validatePassword,
                onFieldSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: 'Password',
                  helperText: signingIn
                      ? null
                      : 'Use at least 8 characters; a passphrase is strongest.',
                  prefixIcon: const Icon(Icons.key_outlined),
                  suffixIcon: IconButton(
                    key: const ValueKey('supabase-password-visibility'),
                    tooltip: _showPassword ? 'Hide password' : 'Show password',
                    onPressed: _busy
                        ? null
                        : () => setState(() => _showPassword = !_showPassword),
                    icon: Icon(
                      _showPassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SonusGradientButton(
                label: _busy
                    ? 'Please wait…'
                    : signingIn
                    ? 'Sign in securely'
                    : 'Create my account',
                icon: _busy
                    ? Icons.hourglass_top_rounded
                    : signingIn
                    ? Icons.login
                    : Icons.arrow_forward,
                expand: true,
                onPressed: _busy ? null : _submit,
              ),
              if (signingIn && widget.onPasswordReset != null) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.center,
                  child: TextButton.icon(
                    key: const ValueKey('supabase-password-reset'),
                    onPressed: _busy ? null : _resetPassword,
                    icon: const Icon(Icons.lock_reset, size: 18),
                    label: const Text('Reset password'),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              const _SecurityNote(),
            ],
          ),
        ),
      ),
    );
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

  String? _validatePassword(String? value) {
    final password = value ?? '';
    if (password.length < 8) {
      return 'Use at least 8 characters.';
    }
    if (password.length > 1024) {
      return 'Password is too long.';
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
              'Protected by Supabase Auth. Sonus Auris never stores your password.',
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

// Branded passwordless Supabase magic-link surface.
import 'package:flutter/material.dart';

import '../theme/sonus_brand.dart';
import '../theme/sonus_theme.dart';
import 'supabase_auth_form.dart';

class SupabaseAuthPanel extends StatefulWidget {
  const SupabaseAuthPanel({
    super.key,
    required this.onSendMagicLink,
    required this.onVerifyCode,
    this.onBusyChanged,
    this.enabled = true,
    this.title = 'Welcome',
    this.description =
        'Use one private account across your phone, desktop, and web dashboard.',
  });

  final Future<bool> Function(String email) onSendMagicLink;
  final Future<bool> Function(String email, String code) onVerifyCode;
  final ValueChanged<bool>? onBusyChanged;
  final bool enabled;
  final String title;
  final String description;

  @override
  State<SupabaseAuthPanel> createState() => _SupabaseAuthPanelState();
}

class _SupabaseAuthPanelState extends State<SupabaseAuthPanel> {
  final _emailController = TextEditingController();

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<bool> _runBool(Future<bool> Function() action) async {
    widget.onBusyChanged?.call(true);
    try {
      return await action();
    } finally {
      widget.onBusyChanged?.call(false);
    }
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
          SupabaseAuthForm(
            emailController: _emailController,
            onSendMagicLink: (email) =>
                _runBool(() => widget.onSendMagicLink(email)),
            onVerifyCode: (email, code) =>
                _runBool(() => widget.onVerifyCode(email, code)),
          ),
          const SizedBox(height: 12),
          const _SecurityNote(),
        ],
      ),
    );
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

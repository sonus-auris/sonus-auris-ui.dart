import 'package:audio_dashcam/src/widgets/supabase_auth_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class H extends StatefulWidget {
  const H({super.key, required this.req});
  final List<String> req;
  @override
  State<H> createState() => HS();
}

class HS extends State<H> {
  final email = TextEditingController();
  final code = TextEditingController();
  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: SupabaseAuthForm(
          emailController: email,
          codeController: code,
          onRequestCode: (v) async {
            widget.req.add(v);
            return true;
          },
          onSubmitCode: (v, c) async {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('repro', (tester) async {
    final req = <String>[];
    await tester.pumpWidget(H(req: req));
    await tester.pump();
    final overlong = '${'a' * 310}@example.com';
    for (final c in [
      'not-an-email',
      'no-domain@',
      'two@at@example.com',
      'has space@example.com',
      'tab\there@example.com',
      overlong,
    ]) {
      await tester.enterText(find.byKey(const ValueKey('supabase-email-field')), c);
      await tester.tap(find.byKey(const ValueKey('supabase-request-button')));
      await tester.pump(const Duration(milliseconds: 300));
      // ignore: avoid_print
      print('after "$c": req=$req codeField=${find.byKey(const ValueKey('supabase-code-field')).evaluate().length} err=${find.text('Enter a valid email address.').evaluate().length}');
    }
    await tester.enterText(find.byKey(const ValueKey('supabase-email-field')), 'person@example.com');
    await tester.tap(find.byKey(const ValueKey('supabase-request-button')));
    await tester.pump(const Duration(milliseconds: 300));
    // ignore: avoid_print
    print('FINAL: req=$req codeField=${find.byKey(const ValueKey('supabase-code-field')).evaluate().length}');
  });
}

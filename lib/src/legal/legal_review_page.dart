import 'package:flutter/material.dart';

import 'legal_review_bundle.dart';

/// Review UI only: no acceptance button, telemetry, network request or consent write.
class LegalReviewPage extends StatefulWidget {
  const LegalReviewPage({super.key});

  @override
  State<LegalReviewPage> createState() => _LegalReviewPageState();
}

class _LegalReviewPageState extends State<LegalReviewPage> {
  late final Future<LegalReviewBundle> _bundle = LegalReviewBundle.load();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Legal draft review')),
      body: FutureBuilder<LegalReviewBundle>(
        future: _bundle,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('Legal documents unavailable. No terms accepted.'));
          }
          final bundle = snapshot.data;
          if (bundle == null) return const Center(child: CircularProgressIndicator());
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text('DRAFTS ONLY — NOT APPROVED OR ACCEPTED', style: TextStyle(fontWeight: FontWeight.bold)),
              const Text('These offline review copies do not replace live privacy notices, store terms or recording consent.'),
              SelectableText('Source: ${bundle.sourceCommit}'),
              for (final document in bundle.documents)
                ExpansionTile(
                  title: Text(document.id),
                  children: [Padding(padding: const EdgeInsets.all(12), child: SelectableText(document.text))],
                ),
            ],
          );
        },
      ),
    );
  }
}

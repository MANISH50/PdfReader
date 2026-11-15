import 'package:material_ui/material_ui.dart';

import '../../core/models/document_ref.dart';

/// Placeholder — owned by the feature agent.
class ViewerScreen extends StatelessWidget {
  const ViewerScreen({super.key, required this.document});
  final DocumentRef document;

  @override
  Widget build(BuildContext context) =>
      Scaffold(appBar: AppBar(title: Text(document.displayName)), body: const SizedBox.shrink());
}

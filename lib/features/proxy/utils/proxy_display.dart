import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';

String normalizeProxyDisplayChain(String value) {
  final parts = <String>[];
  for (final rawPart in value.split('→')) {
    final part = rawPart.trim();
    if (part.isEmpty || parts.contains(part)) continue;
    parts.add(part);
  }
  return parts.join(' → ');
}

String proxyDisplayTag(OutboundInfo proxy) {
  return normalizeProxyDisplayChain(proxy.tagDisplay);
}

String proxyDisplayTagWithSelected(OutboundInfo proxy) {
  final selected = proxy.groupSelectedTagDisplay.trim();
  final base = proxyDisplayTag(proxy);
  if (selected.isEmpty) return base;
  return normalizeProxyDisplayChain('$base → $selected');
}

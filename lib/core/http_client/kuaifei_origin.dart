class KuaifeiOrigin {
  const KuaifeiOrigin._();

  static const productionIp = '34.92.219.162';
  static const testIp = '35.252.153.151';

  static String? ipForHost(String host) {
    final normalized = host.toLowerCase();
    if (normalized == 'test.kuaifei.top') return testIp;
    if (normalized == 'kuaifei.top' || normalized.endsWith('.kuaifei.top')) return productionIp;
    return null;
  }
}

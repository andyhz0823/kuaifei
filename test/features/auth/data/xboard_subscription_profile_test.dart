import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/auth/data/xboard_api_client.dart';

void main() {
  group('XboardSubscriptionProfile.isUsable', () {
    test('accepts a subscription with remaining time and traffic', () {
      final profile = XboardSubscriptionProfile(
        subscribeUrl: 'https://example.com/sub',
        upload: 10,
        download: 20,
        total: 100,
        expireAt: DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000,
      );

      expect(profile.isUsable, isTrue);
    });

    test('rejects an expired subscription', () {
      final profile = XboardSubscriptionProfile(
        subscribeUrl: 'https://example.com/sub',
        upload: 0,
        download: 0,
        total: 100,
        expireAt: DateTime.now().subtract(const Duration(minutes: 1)).millisecondsSinceEpoch ~/ 1000,
      );

      expect(profile.isUsable, isFalse);
    });

    test('rejects a subscription whose traffic is exhausted', () {
      final profile = XboardSubscriptionProfile(
        subscribeUrl: 'https://example.com/sub',
        upload: 40,
        download: 60,
        total: 100,
        expireAt: DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000,
      );

      expect(profile.isUsable, isFalse);
    });

    test('accepts a perpetual subscription with remaining traffic', () {
      final profile = XboardSubscriptionProfile(
        subscribeUrl: 'https://example.com/sub',
        upload: 1,
        download: 1,
        total: 100,
      );

      expect(profile.isUsable, isTrue);
    });
  });
}

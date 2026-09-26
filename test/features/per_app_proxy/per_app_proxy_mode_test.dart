import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/per_app_proxy/model/per_app_proxy_mode.dart';
import 'package:hiddify/gen/translations.g.dart';

void main() {
  group('PerAppProxyMode', () {
    test('enabled getter returns false for off, true for include and exclude', () {
      expect(PerAppProxyMode.off.enabled, isFalse);
      expect(PerAppProxyMode.include.enabled, isTrue);
      expect(PerAppProxyMode.exclude.enabled, isTrue);
    });

    test('toAppProxy maps correctly', () {
      expect(PerAppProxyMode.off.toAppProxy(), isNull);
      expect(PerAppProxyMode.include.toAppProxy(), equals(AppProxyMode.include));
      expect(PerAppProxyMode.exclude.toAppProxy(), equals(AppProxyMode.exclude));
    });

    test('present provides title and message for all modes', () {
      final t = TranslationsEn();
      for (final mode in PerAppProxyMode.values) {
        final presentation = mode.present(t);
        expect(presentation.title, isNotEmpty);
        expect(presentation.message, isNotEmpty);
      }
    });
  });

  group('AppProxyMode', () {
    test('toPerAppProxy maps correctly', () {
      expect(AppProxyMode.include.toPerAppProxy(), equals(PerAppProxyMode.include));
      expect(AppProxyMode.exclude.toPerAppProxy(), equals(PerAppProxyMode.exclude));
    });

    test('present provides title and message for all modes', () {
      final t = TranslationsEn();
      for (final mode in AppProxyMode.values) {
        final presentation = mode.present(t);
        expect(presentation.title, isNotEmpty);
        expect(presentation.message, isNotEmpty);
      }
    });
  });
}

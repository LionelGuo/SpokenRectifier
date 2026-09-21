/// Ticket 30's token guards: the section head stays body-at-w600 by
/// construction, the family fallback chain has ONE source (the theme
/// serves [SrType.familyFallback] to every Text instead of restating
/// the list), and the tooltip theme rides the token table.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:spokenrectifier_app/src/design/theme.dart' show srTheme;
import 'package:spokenrectifier_app/src/design/tokens.dart';

void main() {
  test('SrType.section is exactly body at the emphasized weight', () {
    expect(SrType.section.fontSize, SrType.body.fontSize);
    expect(SrType.section.height, SrType.body.height);
    expect(SrType.section.fontWeight, FontWeight.w600);
  });

  test('the theme serves the fallback chain from the const — no second list '
      '(every Text inside a Material surface inherits it via bodyMedium)',
      () {
    expect(
      srTheme(Brightness.dark).textTheme.bodyMedium?.fontFamilyFallback,
      SrType.familyFallback,
    );
    expect(
      srTheme(Brightness.light).textTheme.bodyMedium?.fontFamilyFallback,
      SrType.familyFallback,
    );
  });

  test('the tooltip theme rides the raised surface and the micro token', () {
    final theme = srTheme(Brightness.dark);
    final deco = theme.tooltipTheme.decoration! as BoxDecoration;
    expect(deco.color, SrPalette.dark.surfaceRaised);
    expect(deco.borderRadius, BorderRadius.circular(SrRadius.control));
    expect((deco.border as Border).top.color, SrPalette.dark.hairline);
    expect(theme.tooltipTheme.textStyle!.fontSize, SrType.micro.fontSize);
  });
}

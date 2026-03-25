import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/screens/sftp_screen.dart';

void main() {
  group('SFTP path helpers', () {
    test('parentRemotePath resolves POSIX parents', () {
      expect(parentRemotePath('/tmp/monkeyssh'), '/tmp');
      expect(parentRemotePath('/tmp'), '/');
      expect(parentRemotePath('/'), '/');
    });

    test('pushSftpPathHistory appends new locations without duplicates', () {
      expect(pushSftpPathHistory(const ['/tmp'], '/tmp'), ['/tmp']);
      expect(pushSftpPathHistory(const ['/tmp'], '/tmp/monkeyssh'), [
        '/tmp',
        '/tmp/monkeyssh',
      ]);
    });

    test('popSftpPathHistory keeps at least one history entry', () {
      expect(popSftpPathHistory(const ['/']), ['/']);
      expect(popSftpPathHistory(const ['/', '/tmp', '/tmp/monkeyssh']), [
        '/',
        '/tmp',
      ]);
    });

    test('detects previewable image file names including svg', () {
      expect(isPreviewableImageFileName('screenshot.png'), isTrue);
      expect(isPreviewableImageFileName('diagram.svg'), isTrue);
      expect(isPreviewableImageFileName('notes.txt'), isFalse);
    });

    test('detects svg file names', () {
      expect(isSvgFileName('diagram.svg'), isTrue);
      expect(isSvgFileName('diagram.SVG'), isTrue);
      expect(isSvgFileName('diagram.png'), isFalse);
    });

    test('measures the widest rendered line instead of the longest string', () {
      const style = TextStyle(fontSize: 20);
      const trailingSlack = 12.0;
      const textDirection = TextDirection.ltr;
      const textScaler = TextScaler.noScaling;
      const narrowerButLonger = 'iiiiiiiiii';
      const widerButShorter = 'WWWW';
      final widths = <String, double>{
        narrowerButLonger: 80,
        widerButShorter: 200,
      };

      expect(
        measureUnwrappedEditorContentWidth(
          lines: const [narrowerButLonger, widerButShorter],
          style: style,
          textDirection: textDirection,
          textScaler: textScaler,
          trailingSlack: trailingSlack,
          measureLineWidth: (line, _) => widths[line]!,
        ),
        closeTo(widths[widerButShorter]! + trailingSlack, 0.001),
      );
    });
  });
}

// ignore_for_file: public_member_api_docs

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/domain/models/acp_session_state.dart';
import 'package:monkeyssh/presentation/widgets/acp_session_presentation.dart';

void main() {
  group('acpCwdSummary', () {
    test('renders home as tilde', () {
      expect(acpCwdSummary('~'), '~');
      expect(acpCwdSummary('~/'), '~');
      expect(acpCwdSummary(''), '~');
      expect(acpCwdSummary(null), '~');
    });

    test('shortens nested paths to their final segment', () {
      expect(acpCwdSummary('/home/dev/project'), '…/project');
      expect(acpCwdSummary('/home/dev/project/'), '…/project');
    });

    test('keeps a single absolute segment', () {
      expect(acpCwdSummary('/srv'), '/srv');
    });
  });

  group('acpRelativeTime', () {
    final now = DateTime(2026, 1, 1, 12);

    test('reports just now within a minute', () {
      expect(
        acpRelativeTime(now.subtract(const Duration(seconds: 10)), now: now),
        'just now',
      );
    });

    test('reports minutes, hours, and days', () {
      expect(
        acpRelativeTime(now.subtract(const Duration(minutes: 5)), now: now),
        '5m ago',
      );
      expect(
        acpRelativeTime(now.subtract(const Duration(hours: 3)), now: now),
        '3h ago',
      );
      expect(
        acpRelativeTime(now.subtract(const Duration(days: 2)), now: now),
        '2d ago',
      );
    });
  });

  group('acpStatusDisplay', () {
    test('every status has a mono label and an icon (never color alone)', () {
      for (final status in AcpConnectionStatus.values) {
        final display = acpStatusDisplay(status);
        expect(display.label, isNotEmpty);
        expect(display.icon, isA<IconData>());
      }
    });

    test('ready is active-toned and failure is error-toned', () {
      expect(
        acpStatusDisplay(AcpConnectionStatus.ready).tone,
        AcpStatusTone.active,
      );
      expect(
        acpStatusDisplay(AcpConnectionStatus.failed).tone,
        AcpStatusTone.error,
      );
    });

    test('status colors resolve from the color scheme', () {
      const scheme = ColorScheme.dark();
      expect(acpStatusColor(scheme, AcpStatusTone.active), scheme.primary);
      expect(acpStatusColor(scheme, AcpStatusTone.error), scheme.error);
    });
  });
}

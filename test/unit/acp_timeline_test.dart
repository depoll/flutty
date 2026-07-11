// ignore_for_file: public_member_api_docs

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:monkeyssh/presentation/models/acp_timeline.dart';
import 'package:monkeyssh/presentation/widgets/acp_resource_chip.dart';

void main() {
  group('AcpImageContent.sourceKind', () {
    test('bytes take precedence', () {
      final image = AcpImageContent(bytes: Uint8List.fromList([1, 2, 3]));
      expect(image.sourceKind, AcpImageSourceKind.bytes);
    });

    test('classifies data, file and network URIs', () {
      expect(
        const AcpImageContent(uri: 'data:image/png;base64,AAAA').sourceKind,
        AcpImageSourceKind.dataUri,
      );
      expect(
        const AcpImageContent(uri: 'file:///tmp/a.png').sourceKind,
        AcpImageSourceKind.fileUri,
      );
      expect(
        const AcpImageContent(uri: 'https://example.com/a.png').sourceKind,
        AcpImageSourceKind.networkUri,
      );
    });
  });

  group('AcpResourceRef.displayName', () {
    test('uses explicit name when present', () {
      const ref = AcpResourceRef(uri: 'file:///a/b/c.txt', name: 'Report');
      expect(ref.displayName, 'Report');
    });

    test('falls back to final path segment', () {
      const ref = AcpResourceRef(uri: 'file:///a/b/c.txt');
      expect(ref.displayName, 'c.txt');
    });

    test('handles trailing slash', () {
      const ref = AcpResourceRef(uri: '/a/b/');
      expect(ref.displayName, 'b');
    });
  });

  group('AcpPlan', () {
    test('computes progress and counts', () {
      const plan = AcpPlan(
        items: [
          AcpPlanItem(title: 'a', status: AcpPlanItemStatus.completed),
          AcpPlanItem(title: 'b', status: AcpPlanItemStatus.inProgress),
          AcpPlanItem(title: 'c'),
          AcpPlanItem(title: 'd', status: AcpPlanItemStatus.completed),
        ],
      );
      expect(plan.totalCount, 4);
      expect(plan.completedCount, 2);
      expect(plan.inProgressCount, 1);
      expect(plan.progress, 0.5);
    });

    test('empty plan has zero progress', () {
      const plan = AcpPlan();
      expect(plan.progress, 0);
      expect(plan.totalCount, 0);
    });
  });

  group('AcpUsage', () {
    test('derives context fraction', () {
      const usage = AcpUsage(contextWindow: 1000, contextUsedTokens: 250);
      expect(usage.contextFraction, 0.25);
      expect(usage.hasData, isTrue);
    });

    test('clamps fraction and guards zero window', () {
      const overflow = AcpUsage(contextWindow: 100, contextUsedTokens: 500);
      expect(overflow.contextFraction, 1.0);
      const noWindow = AcpUsage(contextUsedTokens: 500);
      expect(noWindow.contextFraction, isNull);
    });

    test('empty usage has no data', () {
      expect(const AcpUsage().hasData, isFalse);
    });
  });

  group('equality', () {
    test('value equality holds for identical models', () {
      expect(
        const AcpToolCall(id: '1', title: 'Read'),
        const AcpToolCall(id: '1', title: 'Read'),
      );
      expect(const AcpTextPart('hi'), const AcpTextPart('hi'));
    });
  });

  group('formatResourceSize', () {
    test('formats bytes, KB and MB', () {
      expect(formatResourceSize(512), '512 B');
      expect(formatResourceSize(2048), '2 KB');
      expect(formatResourceSize(1536), '1.5 KB');
      expect(formatResourceSize(5 * 1024 * 1024), '5 MB');
    });
  });
}

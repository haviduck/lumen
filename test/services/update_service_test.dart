// Tests for the pure / parser-only surface of `UpdateService`. The
// network + filesystem paths (`checkForUpdates`, `downloadInstaller`,
// `launchInstaller`) are integration-shaped and live outside this
// file — they need a real HTTP mock + a temp dir, which we can wire
// up in a separate test if we ever regress them.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/update_service.dart';

void main() {
  group('UpdateService.compareVersions', () {
    test('equal versions return 0', () {
      expect(UpdateService.compareVersions('1.0.12', '1.0.12'), 0);
      expect(UpdateService.compareVersions('v1.0.12', '1.0.12'), 0);
      expect(UpdateService.compareVersions('1.0.12+12', '1.0.12'), 0);
    });

    test('newer version returns positive', () {
      expect(UpdateService.compareVersions('1.0.13', '1.0.12') > 0, isTrue);
      expect(UpdateService.compareVersions('1.1.0', '1.0.12') > 0, isTrue);
      expect(UpdateService.compareVersions('2.0.0', '1.999.999') > 0, isTrue);
    });

    test('older version returns negative', () {
      expect(UpdateService.compareVersions('1.0.11', '1.0.12') < 0, isTrue);
      expect(UpdateService.compareVersions('1.0.12', 'v1.0.13') < 0, isTrue);
    });

    test('v-prefix tolerance', () {
      expect(UpdateService.compareVersions('v1.0.12', 'v1.0.13') < 0, isTrue);
      expect(UpdateService.compareVersions('V1.0.13', '1.0.12') > 0, isTrue);
    });

    test('missing trailing parts treated as zero', () {
      expect(UpdateService.compareVersions('1.0', '1.0.0'), 0);
      expect(UpdateService.compareVersions('1.0', '1.0.1') < 0, isTrue);
      expect(UpdateService.compareVersions('1.1', '1.0.99') > 0, isTrue);
    });

    test('pre-release suffix dropped for ordering', () {
      // Conservative reduction: we ship final releases, so a `-rc1`
      // suffix is treated as the same as the bare version for now.
      // If we ever ship pre-releases, revisit.
      expect(UpdateService.compareVersions('1.0.12-rc1', '1.0.12'), 0);
      expect(
        UpdateService.compareVersions('1.0.12+12', '1.0.12+11'),
        0,
      );
    });

    test('non-numeric components fall back to zero', () {
      expect(UpdateService.compareVersions('abc', '0.0.0'), 0);
      expect(UpdateService.compareVersions('1.x.3', '1.0.3'), 0);
    });
  });

  group('LumenRelease.parse', () {
    test('returns null when no installer asset matches', () {
      final r = LumenRelease.parse({
        'tag_name': 'v1.0.12',
        'name': 'Lumen v1.0.12',
        'body': 'notes',
        'html_url': 'https://github.com/haviduck/lumen/releases/tag/v1.0.12',
        'assets': [
          {
            'name': 'lumen-v1.0.12-windows-x64.zip',
            'browser_download_url': 'https://example.com/zip',
            'size': 1234,
          },
        ],
      });
      expect(r, isNull);
    });

    test('picks the Lumen-Setup-*.exe asset and strips v from tag', () {
      final r = LumenRelease.parse({
        'tag_name': 'v1.0.12',
        'name': 'Lumen v1.0.12',
        'body': '## Highlights\nNew installer.',
        'published_at': '2026-05-13T20:51:33Z',
        'html_url': 'https://github.com/haviduck/lumen/releases/tag/v1.0.12',
        'assets': [
          {
            'name': 'lumen-v1.0.12-windows-x64.zip',
            'browser_download_url': 'https://example.com/zip',
            'size': 28_000_000,
          },
          {
            'name': 'Lumen-Setup-v1.0.12.exe',
            'browser_download_url':
                'https://example.com/Lumen-Setup-v1.0.12.exe',
            'size': 30_000_000,
            'digest':
                'sha256:386e97b1e5f17dcdb782cd22ddc9cdc0d4c9d68fe2c456728c7598e149a63cee',
          },
        ],
      });
      expect(r, isNotNull);
      expect(r!.tagName, 'v1.0.12');
      expect(r.version, '1.0.12');
      expect(r.installerBytes, 30_000_000);
      expect(r.installerUrl, contains('Lumen-Setup-v1.0.12.exe'));
      expect(r.installerSha256, isNotNull);
      expect(r.installerSha256, hasLength(64));
      expect(r.publishedAt.year, 2026);
    });

    test('tolerates missing digest field', () {
      final r = LumenRelease.parse({
        'tag_name': 'v1.0.12',
        'assets': [
          {
            'name': 'Lumen-Setup-v1.0.12.exe',
            'browser_download_url':
                'https://example.com/Lumen-Setup-v1.0.12.exe',
            'size': 30_000_000,
          },
        ],
      });
      expect(r, isNotNull);
      expect(r!.installerSha256, isNull);
    });

    test('returns null on missing tag', () {
      final r = LumenRelease.parse({
        'assets': [
          {
            'name': 'Lumen-Setup-v1.0.12.exe',
            'browser_download_url': 'https://example.com/x',
            'size': 1,
          },
        ],
      });
      expect(r, isNull);
    });
  });
}

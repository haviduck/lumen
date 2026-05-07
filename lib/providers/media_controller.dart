import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_windows/webview_windows.dart';

import '../services/extension_provisioner.dart';
import 'media_scripts.dart';

/// Where the watch-media `Webview` is rendered.
///
/// - `chat`   — embedded at the top of the AI chat panel, scaled
///   16:9 to the chat panel's current width.
/// - `editor` — docked to the right of the editor area as a vertical
///   `MultiSplitView` pane (50/50 default, draggable).
///
/// Switching placement does NOT reload the underlying WebView; it
/// just remounts the visual `Webview()` widget under a different
/// parent. Webview2 keeps its texture / DOM state alive across the
/// remount, so the video keeps playing.
enum MediaPlacement { chat, editor }

enum MediaSlot { watch, teams }

/// Owns the watch-media state for the IDE.
///
/// Was previously inlined in `_AiChatState` (URL parsing, the YT
/// `loadingState` listener that injects cleanup CSS, the
/// `WebviewController`). Lifted to a top-level `ChangeNotifier` so
/// both the chat panel AND the editor area can render the same
/// `Webview()` based on the user's chosen placement, without
/// recreating Webview2 every time placement flips.
///
/// Persistence: only the `MediaPlacement` choice is persisted
/// (`media.placement`). The current URL is intentionally session-
/// scoped — a video that was playing when the user closed the IDE
/// shouldn't auto-resume on the next launch.
class MediaController extends ChangeNotifier {
  MediaController() {
    _loadPersistedPlacement();
  }

  /// Webview2 instance for normal watch-media (YouTube/Twitch/arbitrary URL).
  final WebviewController webview = WebviewController();
  bool _webviewInitialized = false;

  /// Separate Webview2 instance for Teams. Teams needs to coexist with
  /// watch-media, so it cannot share [webview] (a WebView2 control can only
  /// show one URL and can only be mounted under one widget parent at a time).
  final WebviewController teamsWebview = WebviewController();
  bool _teamsWebviewInitialized = false;

  String? _url;
  String? get url => _url;

  String? _youtubeId;
  String? get youtubeId => _youtubeId;
  bool get isYoutube => _youtubeId != null;
  // Distinct flag from `isYoutube` because Twitch keeps using its
  // dedicated `player.twitch.tv` embed (no equivalent of YouTube's
  // 150/153 wall, so we don't need the watch-page workaround). Both
  // share the 16:9 aspect-ratio lock in the editor pane.
  bool _isTwitch = false;
  bool get isTwitch => _isTwitch;

  /// True when the current media has a locked aspect ratio (the
  /// embed / watch page only makes sense at 16:9). Drives whether
  /// the editor pane wraps the `Webview` in an `AspectRatio`
  /// letterbox vs. just filling the pane (e.g. a news site that
  /// flows freely).
  bool get isAspectLocked => isYoutube || isTwitch;
  bool get hasMedia => _url != null;

  String? _teamsUrl;
  String? get teamsUrl => _teamsUrl;
  bool get hasTeams => _teamsUrl != null;

  /// True when the current URL is one of Microsoft's Teams web
  /// clients. Used by the chrome label so the panel title swaps
  /// from the generic "MEDIA PLAYER" to "TEAMS" for that
  /// one-click shortcut. Covers both the new
  /// `teams.cloud.microsoft` host (the explorer-activity-bar
  /// shortcut loads this) and the legacy `teams.microsoft.com`
  /// (in case a user pastes a URL).
  bool get isTeams {
    final u = _url;
    if (u == null) return false;
    return u.contains('teams.cloud.microsoft') ||
        u.contains('teams.microsoft.com');
  }

  bool get isTeamsSlot => hasTeams;

  /// Friendly all-caps label for the chrome strip. Adapts to the
  /// loaded URL so the panel title isn't always the generic
  /// "MEDIA PLAYER" — when you load Teams it says "TEAMS",
  /// YouTube says "YOUTUBE", etc. Falls back to the generic label
  /// for arbitrary URLs (we don't try to derive a hostname there
  /// — that would surface raw URLs in the chrome which reads
  /// noisy at 12px caps).
  String get displayLabel {
    if (isTeams) return 'TEAMS';
    if (isYoutube) return 'YOUTUBE';
    if (isTwitch) return 'TWITCH';
    return 'MEDIA PLAYER';
  }

  String displayLabelFor(MediaSlot slot) {
    if (slot == MediaSlot.teams) return 'TEAMS';
    return displayLabel;
  }

  WebviewController webviewFor(MediaSlot slot) {
    return slot == MediaSlot.teams ? teamsWebview : webview;
  }

  bool isAspectLockedFor(MediaSlot slot) {
    return slot == MediaSlot.teams ? false : isAspectLocked;
  }

  MediaPlacement _placement = MediaPlacement.chat;
  MediaPlacement get placement => _placement;

  // Mute state. Toggled via `toggleMute()`, applied to the live DOM
  // by injecting a tiny script that flips `.muted` on every `<video>`
  // and `<audio>` element. Re-applied on every `navigationCompleted`
  // so the muted state survives YouTube's SPA-style page transitions.
  bool _muted = false;
  bool get muted => _muted;

  // Native Webview2 zoom factor (1.0 = normal). Persisted in-memory
  // for the session only — reset to 1.0 on every new `play()` so a
  // zoom set for one site doesn't follow the user to the next.
  double _zoomFactor = 1.0;
  double get zoomFactor => _zoomFactor;
  double _teamsZoomFactor = 1.0;
  double zoomFactorFor(MediaSlot slot) {
    return slot == MediaSlot.teams ? _teamsZoomFactor : _zoomFactor;
  }

  StreamSubscription<LoadingState>? _loadingSub;
  StreamSubscription<LoadingState>? _teamsLoadingSub;

  static const String _placementKey = 'media.placement';

  Future<void> _loadPersistedPlacement() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_placementKey);
      if (raw == 'editor') {
        _placement = MediaPlacement.editor;
        notifyListeners();
      }
    } catch (_) {
      // Best-effort: missing prefs is fine, default is chat.
    }
  }

  Future<void> setPlacement(MediaPlacement p) async {
    if (_placement == p) return;
    _placement = p;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _placementKey,
        p == MediaPlacement.editor ? 'editor' : 'chat',
      );
    } catch (_) {}
  }

  /// Historical hold-over from v1.0–v1.3 when Teams and watch-media
  /// fought for a single editor-right-slot. v1.4's side-panes
  /// column lets them coexist, so this is now permanently `false`
  /// — kept for ABI safety in case any chrome control lazily
  /// references it; remove once we're sure nothing reads it.
  bool get watchMediaForcedToChat => false;

  /// Normalizes user-entered URLs so inputs like `youtube.com/...` or
  /// `teams.cloud.microsoft` still load without requiring the user to type
  /// the full scheme.
  String normalizeUserUrl(String rawUrl) {
    var input = rawUrl.trim();
    if (input.isEmpty) return input;

    final lower = input.toLowerCase();
    if (lower.startsWith('https//')) {
      input = 'https://${input.substring(7)}';
    } else if (lower.startsWith('http//')) {
      input = 'http://${input.substring(6)}';
    } else if (input.startsWith('//')) {
      input = 'https:$input';
    }

    final parsed = Uri.tryParse(input);
    if (parsed != null && parsed.hasScheme) return input;

    final hostCandidate = input.split('/').first.toLowerCase();
    final isLocalHost =
        hostCandidate.startsWith('localhost') ||
        hostCandidate.startsWith('127.0.0.1') ||
        hostCandidate.startsWith('0.0.0.0') ||
        hostCandidate.startsWith('[::1]');
    final looksLikeHost = hostCandidate.contains('.') || isLocalHost;
    if (!looksLikeHost) return input;

    final scheme = isLocalHost ? 'http' : 'https';
    return '$scheme://$input';
  }

  /// Extract the YouTube video id from a watch / share / shorts URL.
  /// Returns null when the URL is not a recognisable YouTube link.
  String? extractYoutubeId(String url) {
    final normalized = normalizeUserUrl(url);
    try {
      final uri = Uri.parse(normalized);
      final host = uri.host.toLowerCase();
      if (host.contains('youtube.com')) {
        final v = uri.queryParameters['v'];
        if (v != null && v.isNotEmpty) return v;
        final shortsIdx = uri.pathSegments.indexOf('shorts');
        if (shortsIdx >= 0 && shortsIdx + 1 < uri.pathSegments.length) {
          return uri.pathSegments[shortsIdx + 1];
        }
      }
      if (host.contains('youtu.be') && uri.pathSegments.isNotEmpty) {
        return uri.pathSegments.first;
      }
    } catch (_) {}
    return null;
  }

  /// Load `url` into the shared webview and notify listeners. YouTube
  /// links go straight to the canonical watch page — bypasses every
  /// embed-permission gate (errors 100 / 101 / 150 / 153) because
  /// the watch page isn't an embed; the loading-state listener
  /// then strips YouTube's masthead / sidebar / comments via injected
  /// CSS.
  Future<void> play(String url) async {
    // v1.4 layout note: previously, if Teams was already active we
    // forced watch-media's placement to `chat` because the editor
    // right-slot could only host one webview at a time (Teams or
    // watch, never both). v1.4 lifted SSH/Teams/Watch into a
    // dedicated full-height side column (`SidePanesColumn`) that
    // stacks all three vertically, so the lock-out is gone — Teams
    // and YouTube can coexist in the side column. Placement is
    // now strictly user-controlled via `setPlacement`.

    final normalizedUrl = normalizeUserUrl(url);
    final ytId = extractYoutubeId(normalizedUrl);
    final isTwitch = ytId == null && normalizedUrl.contains('twitch.tv/');
    String targetUrl;
    if (ytId != null) {
      targetUrl = 'https://www.youtube.com/watch?v=$ytId&autoplay=1';
    } else if (isTwitch) {
      if (normalizedUrl.contains('/videos/')) {
        final vid = normalizedUrl.split('/videos/').last.split('?').first;
        targetUrl =
            'https://player.twitch.tv/?video=$vid&parent=localhost&autoplay=true';
      } else {
        final ch = normalizedUrl
            .split('twitch.tv/')
            .last
            .split('/')
            .first
            .split('?')
            .first;
        targetUrl =
            'https://player.twitch.tv/?channel=$ch&parent=localhost&autoplay=true';
      }
    } else {
      // Anything else just loads as a normal browser tab — news,
      // streams, twitter, whatever the user wants up while they
      // work. Use zoom +/- to fit the page into the panel.
      targetUrl = normalizedUrl;
    }

    try {
      if (!_webviewInitialized) {
        await webview.initialize();
        // Don't let pages spawn new OS windows on `target=_blank`
        // / `window.open(...)`. `sameWindow` routes the popup back
        // into this same Webview2 instance — keeps SSO redirects
        // and "open in new tab" links working without flashing a
        // detached browser window over the IDE.
        try {
          await webview.setPopupWindowPolicy(
            WebviewPopupWindowPolicy.sameWindow,
          );
        } catch (_) {}
        // Load uBlock Origin Lite (MV3) from the bundled asset. uBOL
        // does the heavy lifting: in-stream YouTube ads, network
        // trackers, cosmetic filters, popup *content* once a popup is
        // open. The JS hook below covers what uBOL cannot — preventing
        // the popup itself from spawning (uBOL only blocks the URL it
        // would have loaded, the OS window can still flash). They are
        // complementary, not redundant.
        //
        // Failure mode: if provisioning or loading the extension
        // fails (asset missing, runtime too old, IO error) we silently
        // continue without it. Ads come back; the popup hook still
        // works. Don't promote this to a hard error — IDE shouldn't
        // refuse to render a webview because ad-blocking degraded.
        try {
          final extPath = await ExtensionProvisioner.ensureUblockLite();
          if (extPath != null) {
            await webview.addBrowserExtension(extPath);
          }
        } catch (e) {
          debugPrint('uBOL load failed (non-fatal): $e');
        }
        // Early script: hook `window.open` to refuse non-user-gesture
        // calls (kills popunder ads). Self-gates off Twitch (per user
        // preference — Twitch player legitimately uses window.open for
        // chat-popout) and Teams (defensive — Teams uses a separate
        // WebviewController anyway). Don't drop the gates without
        // rebuilding context.
        try {
          await webview.addScriptToExecuteOnDocumentCreated(
            kPopupSuppressionScript,
          );
        } catch (_) {}
        _webviewInitialized = true;
      }
      _loadingSub ??= webview.loadingState.listen(_onLoadingState);
      // Reset zoom on every new URL — a zoom level set for one site
      // shouldn't follow the user to the next.
      _zoomFactor = 1.0;
      try {
        await webview.setZoomFactor(1.0);
      } catch (_) {}
      await webview.loadUrl(targetUrl);
      _url = normalizedUrl;
      _youtubeId = ytId;
      _isTwitch = isTwitch;
      notifyListeners();
    } catch (e) {
      debugPrint('MediaController.play failed: $e');
    }
  }

  Future<void> playTeams([String? url]) async {
    final raw = (url ?? '').trim();
    final normalizedUrl = normalizeUserUrl(
      raw.isEmpty ? 'teams.cloud.microsoft' : raw,
    );
    try {
      if (!_teamsWebviewInitialized) {
        await teamsWebview.initialize();
        // See `play()` — block Teams' "pop out chat / call" buttons
        // from spawning new OS windows. `sameWindow` reroutes the
        // popup into this same Webview2 instance, which Teams
        // handles gracefully (popped-out view just loads in place).
        try {
          await teamsWebview.setPopupWindowPolicy(
            WebviewPopupWindowPolicy.sameWindow,
          );
        } catch (_) {}
        _teamsWebviewInitialized = true;
      }
      _teamsLoadingSub ??= teamsWebview.loadingState.listen((state) {
        if (state == LoadingState.navigationCompleted) {
          // Placeholder for future Teams-specific cleanup. Keeping a listener
          // mirrors the normal media path and gives us a lifecycle hook.
        }
      });
      _teamsZoomFactor = 1.0;
      try {
        await teamsWebview.setZoomFactor(1.0);
      } catch (_) {}
      await teamsWebview.loadUrl(normalizedUrl);
      _teamsUrl = normalizedUrl;
      // v1.4: previously this method also flipped watch-media
      // placement to `chat` so Teams could own the lone editor
      // right-slot. The new `SidePanesColumn` stacks SSH / Teams /
      // Watch vertically with no exclusivity, so we no longer
      // touch placement here. See the matching note in `play()`.
      notifyListeners();
    } catch (e) {
      debugPrint('MediaController.playTeams failed: $e');
    }
  }

  void close() {
    if (!hasMedia) return;
    _url = null;
    _youtubeId = null;
    _isTwitch = false;
    notifyListeners();
    // Park the webview on `about:blank` so the previous page's
    // audio / video actually stops and its DOM gets garbage-
    // collected. Without this, the user would close the panel but
    // a YouTube video keeps playing audio in the background and
    // Teams keeps its websocket alive — exactly the "doesn't trash
    // properly" complaint. Webview2 itself stays alive (cheap to
    // re-`loadUrl` on the next `play()`); we just unload its
    // current document.
    try {
      webview.loadUrl('about:blank');
    } catch (e) {
      debugPrint('MediaController.close — about:blank navigate failed: $e');
    }
  }

  void closeTeams() {
    if (!hasTeams) return;
    _teamsUrl = null;
    notifyListeners();
    try {
      teamsWebview.loadUrl('about:blank');
    } catch (e) {
      debugPrint(
        'MediaController.closeTeams — about:blank navigate failed: $e',
      );
    }
  }

  /// Toggle the muted state of every `<video>` and `<audio>` element
  /// on the current page. Applied via JS injection (Webview2 has no
  /// global mute API; the underlying ICoreWebView2_8.IsMuted property
  /// isn't exposed by `webview_windows 0.4.0`). The state is also
  /// re-applied on `navigationCompleted` so YouTube's SPA navigations
  /// don't accidentally un-mute when switching videos.
  Future<void> toggleMute() async {
    _muted = !_muted;
    notifyListeners();
    await _applyMute();
  }

  Future<void> toggleMuteFor(MediaSlot slot) async {
    if (slot == MediaSlot.teams) {
      // Teams mute is handled inside Teams itself. Avoid injecting JS into an
      // auth-heavy app where DOM structure is not stable.
      return;
    }
    await toggleMute();
  }

  Future<void> _applyMute() async {
    final mute = _muted ? 'true' : 'false';
    final js =
        '''
(function() {
  var muted = $mute;
  document.querySelectorAll('video, audio').forEach(function(e) {
    try { e.muted = muted; } catch(_) {}
  });
})();
''';
    try {
      await webview.executeScript(js);
    } catch (e) {
      debugPrint('mute apply failed: $e');
    }
  }

  /// Set the native Webview2 zoom factor. Clamped to [0.25, 3.0] so
  /// the user can't accidentally zoom into pixel-soup or out into
  /// nothing-visible.
  Future<void> setZoomFactor(double factor) async {
    final clamped = factor.clamp(0.25, 3.0).toDouble();
    if ((clamped - _zoomFactor).abs() < 0.001) return;
    _zoomFactor = clamped;
    notifyListeners();
    try {
      await webview.setZoomFactor(clamped);
    } catch (e) {
      debugPrint('zoom set failed: $e');
    }
  }

  Future<void> setZoomFactorFor(MediaSlot slot, double factor) async {
    if (slot == MediaSlot.watch) {
      await setZoomFactor(factor);
      return;
    }
    final clamped = factor.clamp(0.25, 3.0).toDouble();
    if ((clamped - _teamsZoomFactor).abs() < 0.001) return;
    _teamsZoomFactor = clamped;
    notifyListeners();
    try {
      await teamsWebview.setZoomFactor(clamped);
    } catch (e) {
      debugPrint('teams zoom set failed: $e');
    }
  }

  Future<void> zoomIn() => setZoomFactor(_zoomFactor + 0.1);
  Future<void> zoomOut() => setZoomFactor(_zoomFactor - 0.1);
  Future<void> resetZoom() => setZoomFactor(1.0);

  Future<void> zoomInFor(MediaSlot slot) =>
      setZoomFactorFor(slot, zoomFactorFor(slot) + 0.1);
  Future<void> zoomOutFor(MediaSlot slot) =>
      setZoomFactorFor(slot, zoomFactorFor(slot) - 0.1);

  /// Open the original media URL in the user's default browser.
  /// Permanent escape hatch — useful for fullscreen / casting / a
  /// real browser tab. On Windows, `cmd /c start "" <url>` invokes
  /// the registered handler for http(s); the empty `""` is the
  /// mandatory window-title argument so URLs containing spaces
  /// don't get treated as a title.
  Future<void> openInBrowser() async {
    await openInBrowserFor(MediaSlot.watch);
  }

  Future<void> openInBrowserFor(MediaSlot slot) async {
    final url = slot == MediaSlot.teams ? _teamsUrl : _url;
    if (url == null) return;
    try {
      if (Platform.isWindows) {
        await Process.start('cmd', ['/c', 'start', '', url]);
      } else if (Platform.isMacOS) {
        await Process.start('open', [url]);
      } else {
        await Process.start('xdg-open', [url]);
      }
    } catch (e) {
      debugPrint('MediaController.openInBrowserFor failed: $e');
    }
  }

  void closeFor(MediaSlot slot) {
    if (slot == MediaSlot.teams) {
      closeTeams();
    } else {
      close();
    }
  }

  /// Permission handler used by the Teams `Webview` widget.
  ///
  /// Microsoft Teams Web needs `getUserMedia` (mic + camera) to make calls,
  /// `notifications` for incoming-call toasts, and `clipboardRead` for paste-
  /// in-meeting. WebView2's default is to ignore the request unless a host
  /// callback responds, so calls silently fail without this. We auto-allow
  /// only on Microsoft-owned hosts (Teams + the SSO redirect chain through
  /// `login.microsoftonline.com` / `microsoft.com`) — that way we never grant
  /// mic/cam to whatever a redirect happens to land on.
  ///
  /// Note: this only covers the WebView2 / browser-level permission. The
  /// user still has to (a) allow desktop apps to use mic/cam in Windows
  /// privacy settings, and (b) accept Teams' own in-app device prompt the
  /// first time they join a call.
  static Future<WebviewPermissionDecision> handleTeamsPermission(
    String url,
    WebviewPermissionKind kind,
    bool isUserInitiated,
  ) async {
    final lower = url.toLowerCase();
    final isMicrosoftHost =
        lower.contains('teams.cloud.microsoft') ||
        lower.contains('teams.microsoft.com') ||
        lower.contains('login.microsoftonline.com') ||
        lower.contains('login.microsoft.com') ||
        lower.contains('.office.com') ||
        lower.contains('.office365.com') ||
        lower.contains('.sharepoint.com');
    if (!isMicrosoftHost) {
      return WebviewPermissionDecision.deny;
    }
    switch (kind) {
      case WebviewPermissionKind.microphone:
      case WebviewPermissionKind.camera:
      case WebviewPermissionKind.notifications:
      case WebviewPermissionKind.clipboardRead:
        return WebviewPermissionDecision.allow;
      case WebviewPermissionKind.geoLocation:
      case WebviewPermissionKind.otherSensors:
      case WebviewPermissionKind.unknown:
        return WebviewPermissionDecision.deny;
    }
  }

  void _onLoadingState(LoadingState state) {
    if (state != LoadingState.navigationCompleted) return;
    if (isYoutube) {
      // YT chrome stripping (masthead / sidebar / comments / ad-surface
      // selectors). Unrelated to network-level ad blocking — uBOL kills
      // the ad delivery, this CSS keeps the watch page looking like a
      // pane-sized player. Brittle: YT renames these custom-element
      // selectors a few times a year. Failure is graceful (unstyled
      // watch page, still a working player).
      webview.executeScript(kYoutubeWatchCleanupJs).catchError((Object e) {
        debugPrint('youtube cleanup script failed: $e');
        return null;
      });
    }
    // Re-apply mute on every navigation. YouTube's watch page is an
    // SPA — clicking a related video swaps the player without a
    // full reload, but the JS DOM still gets re-templated and the
    // <video> element loses our muted=true state. This handler is
    // also a fresh-page mute for the very first load.
    if (_muted) {
      _applyMute();
    }
  }

  @override
  void dispose() {
    _loadingSub?.cancel();
    _teamsLoadingSub?.cancel();
    if (_webviewInitialized) webview.dispose();
    if (_teamsWebviewInitialized) teamsWebview.dispose();
    super.dispose();
  }
}

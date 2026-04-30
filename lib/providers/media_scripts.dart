// JS payloads injected into the watch-media `Webview`.
//
// As of the uBlock Origin Lite (MV3) integration, network-level ad
// blocking is owned by the bundled extension (loaded via
// `WebviewController.addBrowserExtension`). The JS in this file covers
// the two things uBOL doesn't:
//
//  - **Cosmetic chrome stripping** for the YouTube watch page
//    (`kYoutubeWatchCleanupJs`). uBOL hides ad surfaces but doesn't
//    remove the masthead / sidebar / comments — that's a Lumen-
//    specific "make it look like a pane-sized player" choice, not an
//    ad-blocking concern.
//
//  - **Popup *spawn* prevention** (`kPopupSuppressionScript`). uBOL
//    blocks the URL a popunder *would* navigate to, but the OS popup
//    window can still flash before the URL is denied. The JS hook
//    refuses the `window.open` call entirely when it isn't backed by
//    a fresh user gesture, so no popup window is ever spawned. Self-
//    gated off Twitch and Teams (see body for the why on each).
//
// The earlier YouTube-specific network/state hooks
// (`kYoutubeAdBlockEarlyScript`, `kYoutubeAdSkipTickerScript`) were
// removed when uBOL came online — they were brittle (YT API rewrites)
// and uBOL handles the same job more durably via filter-list updates.
// Don't reinstate them unless uBOL provisioning is broken; the proper
// fallback in that case is to fix the extension load, not paper over
// it with hand-rolled JS hooks.

library;

/// Popup / popunder suppression. Runs on every document the shared
/// `webview` loads EXCEPT Twitch and Teams (host-gated). The strategy
/// is two-pronged:
///
/// 1. Hook `window.open` and refuse calls that don't have a fresh user
///    activation (`navigator.userActivation.isActive === false`).
///    Modern Chromium gives us a ~5s window after a real click during
///    which `isActive` stays true, so legitimate "click → opens share
///    dialog" flows still work; popunder ad scripts that schedule
///    `setTimeout(window.open, ...)` minutes later get silently dropped.
///
/// 2. Capture-phase click swallow for the "invisible-overlay-as-link"
///    clickjack pattern: a near-fullscreen `<a target="_blank">` with
///    very low opacity AND a high z-index is treated as hostile and
///    the click is `preventDefault()`ed before the page sees it.
///    Tightly scoped — a legit fullscreen click target (e.g. a video
///    poster) won't match the transparent / high-z combo.
///
/// We deliberately do NOT change the host-side
/// `WebviewPopupWindowPolicy` (still `sameWindow`) — SSO redirect
/// chains and Microsoft login popups rely on it, and the JS hook is
/// more surgical anyway.
const String kPopupSuppressionScript = r'''
(function() {
  var host = (location && location.hostname || '').toLowerCase();
  if (host.indexOf('twitch.tv') >= 0) return;
  if (host.indexOf('teams.microsoft') >= 0 || host.indexOf('teams.cloud.microsoft') >= 0) return;
  if (window.__lumenPopupHooked) return;
  window.__lumenPopupHooked = true;

  try {
    var origOpen = window.open;
    window.open = function(url, name, features) {
      try {
        var act = navigator.userActivation;
        if (act && act.isActive === false) {
          try { console.debug('[lumen] suppressed non-gesture window.open:', url); } catch (_) {}
          return null;
        }
      } catch (_) {}
      return origOpen.apply(window, arguments);
    };
  } catch (_) {}

  try {
    document.addEventListener('click', function(e) {
      try {
        var t = e.target;
        var a = (t && t.closest) ? t.closest('a[target="_blank"]') : null;
        if (!a) return;
        var r = a.getBoundingClientRect();
        var vw = window.innerWidth || 0;
        var vh = window.innerHeight || 0;
        if (vw === 0 || vh === 0) return;
        var coversViewport = r.width >= vw * 0.8 && r.height >= vh * 0.8;
        if (!coversViewport) return;
        var cs = getComputedStyle(a);
        var transparent = (cs.opacity && parseFloat(cs.opacity) < 0.05)
          || cs.visibility === 'hidden';
        var highZ = parseInt(cs.zIndex || '0', 10) > 1000;
        if (transparent && highZ) {
          e.preventDefault();
          e.stopPropagation();
          try { console.debug('[lumen] suppressed click-hijack overlay:', a); } catch (_) {}
        }
      } catch (_) {}
    }, true);
  } catch (_) {}
})();
''';

/// CSS injection that strips the YouTube watch page down to the player.
/// Pure cosmetic chrome stripping — uBOL handles network-level ads.
/// Brittle by nature (YT renames these custom-element selectors a few
/// times a year), but failure is graceful: the user sees the unstyled
/// watch page, which is still a fully functional player.
const String kYoutubeWatchCleanupJs = r'''
(function() {
  var css = `
    ytd-masthead, #masthead, #masthead-container,
    ytd-watch-next-secondary-results-renderer,
    #related, #secondary, #secondary-inner,
    ytd-comments, #comments, #below, ytd-merch-shelf-renderer,
    ytd-popup-container, tp-yt-iron-overlay-backdrop { display: none !important; }

    html, body, ytd-app, ytd-page-manager,
    ytd-watch-flexy, #primary, #primary-inner,
    #player-container-outer, #player-container-inner,
    #player-container, #player, ytd-player, #movie_player {
      background: #000 !important;
    }
    #player-container-outer, #player-container-inner,
    #player-container, #player, ytd-player, #movie_player, video {
      width: 100% !important;
      height: 100vh !important;
      max-height: 100vh !important;
      margin: 0 !important;
      padding: 0 !important;
    }
    body { overflow: hidden !important; }
  `;
  var existing = document.getElementById('lumen-yt-cleanup');
  if (existing) existing.remove();
  var s = document.createElement('style');
  s.id = 'lumen-yt-cleanup';
  s.textContent = css;
  (document.head || document.documentElement).appendChild(s);
})();
''';

import Foundation

/// سكربت يُحقن في صفحة Topdown. لا يغيّر سلوك الموقع؛ يراقب فقط استجابات
/// /api/resolve و /api/story و /api/story/chapter ليعرف التطبيق ما يمكن تحميله.
enum BridgeScript {
    static let source = #"""
(function () {
  if (window.__topdownApp) return;
  window.__topdownApp = true;
  var post = function (msg) { try { window.webkit.messageHandlers.topdown.postMessage(msg); } catch (e) {} };
  var abs = function (u) { try { return new URL(u, location.href).href; } catch (e) { return u; } };
  var original = window.fetch;
  var lastImages = [];

  window.fetch = function (input, init) {
    var url = typeof input === 'string' ? input : (input && input.url) || '';
    var body = init && init.body;
    var p = original.apply(this, arguments);
    p.then(function (res) {
      try {
        if (!res.ok) return;
        var u = new URL(url, location.href);
        if (u.origin !== location.origin) return;
        if (u.pathname === '/api/resolve') {
          var item = {}; try { item = JSON.parse(body || '{}'); } catch (e) {}
          res.clone().json().then(function (r) {
            if (r && r.url) post({ type: 'resolve', item: item, url: abs(r.url), kind: r.kind || 'direct' });
          }).catch(function () {});
        } else if (u.pathname === '/api/story') {
          res.clone().json().then(function (d) {
            if (!d || !d.url) return;
            post({ type: 'story', title: d.title || '', url: d.url, cover: d.cover || '',
                   chapters: (d.chapters || []).map(function (c) { return { url: c.url, title: c.title || '', number: (typeof c.number === 'number') ? c.number : null }; }) });
          }).catch(function () {});
        } else if (u.pathname === '/api/story/chapter') {
          res.clone().json().then(function (c) {
            if (!c || !c.images) return;
            lastImages = c.images.slice();
            post({ type: 'chapter', url: u.searchParams.get('url') || '', title: c.title || '', images: c.images });
            setTimeout(report, 400);
          }).catch(function () {});
        }
      } catch (e) {}
    }, function () {});
    return p;
  };

  var lastState = '';
  function report() {
    var v = document.querySelector('video.player');
    var src = v ? abs(v.currentSrc || v.getAttribute('src') || '') : '';
    var reader = false;
    if (lastImages.length) {
      var imgs = document.querySelectorAll('img');
      for (var i = 0; i < imgs.length && !reader; i++) {
        var s = imgs[i].getAttribute('src') || '';
        if (s.indexOf('/api/manga-image') === 0 || lastImages.indexOf(s) !== -1) reader = true;
      }
    }
    var state = JSON.stringify([src, reader]);
    if (state !== lastState) { lastState = state; post({ type: 'state', playerSrc: src, reader: reader }); }
  }
  var t = null;
  var schedule = function () { clearTimeout(t); t = setTimeout(report, 250); };
  document.addEventListener('DOMContentLoaded', function () {
    new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['src'] });
    report();
  });
  window.addEventListener('popstate', schedule);
  document.addEventListener('loadedmetadata', schedule, true);
})();
"""#
}

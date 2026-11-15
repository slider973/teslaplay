import Foundation

/// Pages servies par l'extension. JavaScript volontairement conservateur (ES5, XHR)
/// car la version exacte du Chromium embarqué dans la Tesla n'est pas connue.
enum WebPages {
    private static let style = #"""
    <style>
      html,body{margin:0;height:100%;background:#000;overflow:hidden;font-family:-apple-system,Helvetica,Arial,sans-serif;color:#fff}
      #m{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);background:#000;display:block}
      #hud{position:fixed;left:12px;top:12px;display:flex;gap:10px;align-items:center;transition:opacity .4s;z-index:2}
      #hud button,#hud a{background:rgba(40,40,40,.85);color:#fff;border:1px solid #555;border-radius:10px;padding:12px 18px;font-size:18px;text-decoration:none}
      #msg{position:fixed;left:0;right:0;top:45%;text-align:center;font-size:22px;color:#aaa;z-index:1}
      #info{font-size:14px;color:#bbb;background:rgba(0,0,0,.6);padding:4px 8px;border-radius:6px}
    </style>
    """#

    /// Rotation automatique (via /status) + décalage manuel, mise à l'échelle "contain", HUD.
    private static let commonScript = #"""
    var rotAuto = 0, rotUser = 0, hideTimer = null;
    try { rotUser = parseInt(localStorage.getItem('tm_rot') || '0', 10) || 0; } catch (e) {}
    function $(id) { return document.getElementById(id); }
    function mediaSize(el) {
      return el.tagName === 'VIDEO' ? [el.videoWidth, el.videoHeight] : [el.naturalWidth, el.naturalHeight];
    }
    function layout() {
      var el = $('m'), s = mediaSize(el), w = s[0], h = s[1];
      if (!w || !h) return;
      var r = (rotAuto + rotUser) % 360, side = (r % 180) !== 0;
      var W = window.innerWidth, H = window.innerHeight;
      var k = Math.min(W / (side ? h : w), H / (side ? w : h));
      el.style.width = Math.round(w * k) + 'px';
      el.style.height = Math.round(h * k) + 'px';
      el.style.transform = 'translate(-50%,-50%) rotate(' + r + 'deg)';
      $('rot').textContent = '↻ ' + (rotUser ? '+' + rotUser + '°' : 'auto');
    }
    function pollStatus() {
      var x = new XMLHttpRequest();
      x.open('GET', '/status?t=' + Date.now(), true);
      x.timeout = 3000;
      x.onload = function () {
        try {
          var s = JSON.parse(x.responseText);
          if (typeof s.rotation === 'number' && s.rotation !== rotAuto) { rotAuto = s.rotation; layout(); }
        } catch (e) {}
      };
      x.send();
    }
    function showHud() {
      $('hud').style.opacity = '1';
      if (hideTimer) clearTimeout(hideTimer);
      hideTimer = setTimeout(function () { $('hud').style.opacity = '0'; }, 4000);
    }
    $('rot').onclick = function (e) {
      e.stopPropagation(); rotUser = (rotUser + 90) % 360;
      try { localStorage.setItem('tm_rot', String(rotUser)); } catch (err) {}
      layout(); showHud();
    };
    $('fs').onclick = function (e) {
      e.stopPropagation();
      var d = document.documentElement, f = d.requestFullscreen || d.webkitRequestFullscreen;
      if (f) { try { f.call(d); } catch (err) {} }
      showHud();
    };
    document.body.addEventListener('click', showHud);
    window.addEventListener('resize', layout);
    setInterval(pollStatus, 1000);
    setInterval(layout, 1000);
    pollStatus(); showHud();
    """#

    // MARK: - Accueil

    /// Les services protégés (DRM) sont noirs en recopie d'écran : ils doivent être lus
    /// directement par le navigateur de la voiture (comme CarTV le fait sur l'écran CarPlay).
    static let home = #"""
    <!doctype html>
    <html lang="fr"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>TeslaMirror</title>
    <style>
      html,body{margin:0;background:#111;color:#eee;font-family:-apple-system,Helvetica,Arial,sans-serif}
      main{max-width:1100px;margin:0 auto;padding:28px 16px}
      h1{margin:0 0 4px;font-size:30px} h2{font-size:20px;margin:30px 0 6px}
      p{color:#999;margin:0 0 14px;font-size:16px}
      .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:14px}
      a.tile{display:flex;align-items:center;justify-content:center;min-height:96px;border-radius:16px;
             background:#222;border:1px solid #333;color:#fff;text-decoration:none;font-size:22px;font-weight:600;text-align:center;padding:10px}
      a.main{background:#c62828;border-color:#e53935;font-size:26px;min-height:120px}
      a.alt{background:#1e1e1e;font-size:18px}
    </style></head><body><main>
    <h1>TeslaMirror</h1>
    <p>Usage à l'arrêt uniquement.</p>

    <div class="grid">
      <a class="tile main" href="/mirror">Recopier l'écran de l'iPhone</a>
      <a class="tile alt" href="/mjpeg">Recopie (mode compatibilité)</a>
    </div>

    <h2>Films et séries</h2>
    <p>Ces services sont protégés et apparaissent en noir en recopie. Ils sont lus ici directement par la voiture, avec le son sur les haut-parleurs.</p>
    <div class="grid">
      <a class="tile" href="https://www.netflix.com/browse">Netflix</a>
      <a class="tile" href="https://www.youtube.com/">YouTube</a>
      <a class="tile" href="https://www.disneyplus.com/">Disney+</a>
      <a class="tile" href="https://www.primevideo.com/">Prime Video</a>
      <a class="tile" href="https://www.molotov.tv/">Molotov</a>
      <a class="tile" href="https://www.rts.ch/play/tv">Play RTS</a>
      <a class="tile" href="https://www.twitch.tv/">Twitch</a>
      <a class="tile" href="https://tv.apple.com/">Apple TV+</a>
    </div>
    </main></body></html>
    """#

    // MARK: - V1 : MJPEG

    static let mjpeg = #"""
    <!doctype html>
    <html lang="fr"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
    <title>TeslaMirror (MJPEG)</title>
    """# + style + #"""
    </head><body>
    <div id="msg">En attente de l'iPhone…</div>
    <img id="m" src="/stream" alt="">
    <div id="hud"><button id="rot">↻</button><button id="fs">Plein écran</button><a href="/mirror">H.264</a><span id="info">MJPEG</span></div>
    <script>
    """# + commonScript + #"""
    var img = $('m');
    img.onload = function () { $('msg').style.display = 'none'; layout(); };
    img.onerror = function () {
      $('msg').style.display = 'block';
      setTimeout(function () { img.src = '/stream?t=' + Date.now(); }, 1500);
    };
    </script></body></html>
    """#

    // MARK: - V2 : H.264 fMP4 / WebSocket / Media Source Extensions

    static let player = #"""
    <!doctype html>
    <html lang="fr"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
    <title>TeslaMirror</title>
    """# + style + #"""
    </head><body>
    <div id="msg">En attente de l'iPhone…</div>
    <video id="m" muted autoplay playsinline disablepictureinpicture></video>
    <div id="hud"><button id="rot">↻</button><button id="fs">Plein écran</button><a href="/mjpeg">MJPEG</a><span id="info">H.264</span></div>
    <script>
    """# + commonScript + #"""
    var MS = window.ManagedMediaSource || window.MediaSource;
    var v = $('m');
    var ms = null, sb = null, queue = [], ws = null, firstByteAt = 0, lastTrim = 0, fellBack = false;

    function fallback(reason) {
      if (fellBack) return; fellBack = true;
      if (ws) { try { ws.close(); } catch (e) {} }
      location.replace('/mjpeg?from=' + encodeURIComponent(reason));
    }
    function setInfo(t) { $('info').textContent = t; }

    if (!MS || !window.WebSocket) { fallback('mse-absent'); }

    function resetMSE(codec) {
      var mime = 'video/mp4; codecs="' + codec + '"';
      if (!MS.isTypeSupported(mime)) { fallback('codec-' + codec); return; }
      queue = []; sb = null; firstByteAt = 0;
      ms = new MS();
      if (window.ManagedMediaSource && MS === window.ManagedMediaSource) { v.disableRemotePlayback = true; }
      ms.addEventListener('sourceopen', function () {
        try {
          sb = ms.addSourceBuffer(mime);
          sb.mode = 'segments';
          sb.addEventListener('updateend', function () { liveEdge(); pump(); });
          sb.addEventListener('error', function () { reconnect(); });
          pump();
        } catch (e) { fallback('addsourcebuffer'); }
      });
      v.src = URL.createObjectURL(ms);
      setInfo('H.264 ' + codec);
    }

    function pump() {
      if (!sb || sb.updating || !queue.length || !ms || ms.readyState !== 'open') return;
      var now = Date.now(), b = sb.buffered;
      // Purge régulière pour éviter QuotaExceededError sur une longue session.
      if (b.length && now - lastTrim > 5000 && v.currentTime - b.start(0) > 15) {
        lastTrim = now;
        try { sb.remove(0, v.currentTime - 8); return; } catch (e) {}
      }
      try { sb.appendBuffer(queue.shift()); }
      catch (e) {
        if (e.name === 'QuotaExceededError') { queue = []; lastTrim = 0; } else { reconnect(); }
      }
    }

    // Reste collé au bord "live" : saute en avant si le retard dépasse ~0,5 s ou si on est hors buffer.
    function liveEdge() {
      var b = v.buffered;
      if (!b.length) return;
      var end = b.end(b.length - 1), start = b.start(b.length - 1);
      if (v.currentTime < start || end - v.currentTime > 0.5) { v.currentTime = Math.max(start, end - 0.05); }
      if (v.paused) { var p = v.play(); if (p && p.catch) p.catch(function () {}); }
    }

    function connect() {
      ws = new WebSocket('ws://' + location.host + '/ws');
      ws.binaryType = 'arraybuffer';
      ws.onmessage = function (ev) {
        if (typeof ev.data === 'string') {
          var m = null; try { m = JSON.parse(ev.data); } catch (e) {}
          if (m && m.type === 'init') { resetMSE(m.codec); }
          return;
        }
        if (!firstByteAt) firstByteAt = Date.now();
        if (!ms) return;
        queue.push(ev.data);
        // Retard trop important côté navigateur : on repart d'un init + GOP frais.
        if (queue.length > 90) { reconnect(); return; }
        pump();
      };
      ws.onclose = function () { if (!fellBack) setTimeout(reconnect, 1000); };
    }
    function reconnect() {
      if (ws) { ws.onclose = null; try { ws.close(); } catch (e) {} }
      ms = null; sb = null; queue = []; firstByteAt = 0;
      connect();
    }

    v.addEventListener('loadeddata', function () { $('msg').style.display = 'none'; layout(); });
    v.addEventListener('resize', layout);
    v.addEventListener('error', function () { fallback('video-error'); });
    // Données reçues mais rien de décodé après 10 s → repli MJPEG.
    setInterval(function () {
      if (!fellBack && firstByteAt && v.readyState < 2 && Date.now() - firstByteAt > 10000) fallback('timeout');
    }, 2000);

    if (MS && window.WebSocket) connect();
    </script></body></html>
    """#
}

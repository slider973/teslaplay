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
      <a class="tile main" href="/tv" style="background:#1565c0;border-color:#1e88e5">TV (IPTV)</a>
      <a class="tile main" href="/tv#plex" style="background:#e5a00d;border-color:#f0b429;color:#111">Plex</a>
      <a class="tile main" href="/tv#jellyfin" style="background:#6a1b9a;border-color:#8e24aa">Jellyfin</a>
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
    <audio id="snd" playsinline></audio>
    <button id="sound" style="position:fixed;right:16px;bottom:16px;z-index:5;font-size:22px;padding:14px 22px;border-radius:14px;border:1px solid #444;background:#1e1e24cc;color:#fff">🔊 Activer le son</button>
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

    // ---------- Son (canal séparé /wsa, AAC en fMP4) ----------
    // Lecture lancée par un toucher : le navigateur bloque le son sans geste de l'utilisateur.
    var a = $('snd'), ams = null, asb = null, aq = [], aws = null, audioOn = false;
    function aReset(codec) {
      var mime = 'audio/mp4; codecs="' + codec + '"';
      if (!MS.isTypeSupported(mime)) { $('sound').textContent = '🔇 Son non pris en charge'; return; }
      aq = []; asb = null;
      ams = new MS();
      ams.addEventListener('sourceopen', function () {
        try {
          asb = ams.addSourceBuffer(mime); asb.mode = 'segments';
          asb.addEventListener('updateend', function () { aEdge(); aPump(); });
          aPump();
        } catch (e) { aRestart(); }
      });
      a.src = URL.createObjectURL(ams);
      var p = a.play(); if (p && p.catch) p.catch(function () {});
    }
    function aPump() {
      if (!asb || asb.updating || !aq.length || !ams || ams.readyState !== 'open') return;
      var b = asb.buffered;
      if (b.length && a.currentTime - b.start(0) > 20) { try { asb.remove(0, a.currentTime - 10); return; } catch (e) {} }
      try { asb.appendBuffer(aq.shift()); } catch (e) { if (e.name === 'QuotaExceededError') aq = []; else aRestart(); }
    }
    // Bord live : léger accéléré si on prend du retard (inaudible), saut seulement si > 1,5 s.
    function aEdge() {
      var b = a.buffered; if (!b.length) return;
      var lag = b.end(b.length - 1) - a.currentTime;
      if (a.currentTime < b.start(b.length - 1) || lag > 1.5) { a.currentTime = Math.max(b.start(b.length - 1), b.end(b.length - 1) - 0.15); }
      a.playbackRate = lag > 0.45 ? 1.08 : 1.0;
      if (a.paused) { var p = a.play(); if (p && p.catch) p.catch(function () {}); }
    }
    function aConnect() {
      aws = new WebSocket('ws://' + location.host + '/wsa');
      aws.binaryType = 'arraybuffer';
      aws.onmessage = function (ev) {
        if (typeof ev.data === 'string') {
          var m = null; try { m = JSON.parse(ev.data); } catch (e) {}
          if (m && m.type === 'init') aReset(m.codec);
          return;
        }
        if (!ams) return;
        aq.push(ev.data);
        if (aq.length > 60) { aRestart(); return; }
        aPump();
      };
      aws.onclose = function () { if (audioOn) setTimeout(aRestart, 1000); };
    }
    function aRestart() {
      if (aws) { aws.onclose = null; try { aws.close(); } catch (e) {} }
      ams = null; asb = null; aq = [];
      if (audioOn) aConnect();
    }
    $('sound').onclick = function (e) {
      e.stopPropagation();
      audioOn = !audioOn;
      if (audioOn) {
        var p = a.play(); if (p && p.catch) p.catch(function () {});   // débloque la lecture (geste)
        aConnect();
        this.textContent = '🔇 Couper le son';
      } else {
        aRestart(); a.pause(); a.removeAttribute('src'); a.load();
        this.textContent = '🔊 Activer le son';
      }
    };
    </script></body></html>
    """#

    // MARK: - Lecteur intégré (IPTV + Plex)

    /// Lu par le navigateur de la voiture, flux relayés par l'iPhone (hls.js / mpegts.js).
    /// Aucun identifiant n'arrive ici : l'extension injecte jeton Plex et URL IPTV elle-même.
    static let tv = #"""
    <!doctype html>
    <html lang="fr"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <title>TeslaMirror TV</title>
    <style>
      *{box-sizing:border-box}
      html,body{margin:0;height:100%;background:#0d0d0f;color:#eee;font-family:-apple-system,Helvetica,Arial,sans-serif}
      header{position:sticky;top:0;z-index:3;display:flex;gap:10px;align-items:center;padding:12px 16px;background:#141418;border-bottom:1px solid #26262c}
      header button,header a,.btn{background:#24242a;color:#fff;border:1px solid #35353d;border-radius:12px;padding:12px 20px;font-size:18px;text-decoration:none;cursor:pointer}
      header button.on{background:#c62828;border-color:#e53935}
      header input{flex:1;min-width:120px;background:#1d1d22;color:#fff;border:1px solid #35353d;border-radius:12px;padding:12px 14px;font-size:18px}
      #crumbs{padding:12px 16px 0;color:#aaa;font-size:16px}
      #crumbs a{color:#ddd;text-decoration:none;margin-right:8px}
      .wrap{display:flex;gap:14px;padding:14px 16px}
      #groups{flex:0 0 240px;max-height:calc(100vh - 90px);overflow:auto;position:sticky;top:76px}
      #groups div{padding:12px;border-radius:10px;cursor:pointer;font-size:16px;color:#ccc}
      #groups div.on{background:#24242a;color:#fff}
      #grid{flex:1;display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:12px;align-content:start}
      .card{background:#1a1a1f;border:1px solid #26262c;border-radius:12px;padding:10px;cursor:pointer;text-align:center;font-size:15px;overflow:hidden}
      .card img{width:100%;aspect-ratio:16/10;object-fit:contain;background:#111;border-radius:8px;display:block;margin-bottom:8px}
      .card.poster img{aspect-ratio:2/3;object-fit:cover}
      .card .sub{color:#888;font-size:13px;margin-top:4px}
      .msg{padding:30px 16px;color:#aaa;font-size:18px;line-height:1.5}
      #more{grid-column:1/-1;margin:10px auto}
      #player{position:fixed;inset:0;background:#000;z-index:10;display:none}
      #player video{width:100%;height:100%;background:#000}
      #pbar{position:absolute;left:12px;top:12px;right:12px;display:flex;gap:10px;align-items:center;transition:opacity .4s}
      #ptitle{font-size:18px;text-shadow:0 1px 3px #000}
      #perr{position:absolute;left:0;right:0;top:40%;text-align:center;font-size:20px;color:#f88;padding:0 20px;display:none}
      #ptap{position:absolute;inset:0;display:none;align-items:center;justify-content:center;font-size:28px;background:rgba(0,0,0,.5);cursor:pointer}
      @media (max-width:700px){#groups{display:none}}
    </style></head><body>
    <header>
      <a href="/">⌂</a>
      <button id="tabTV" class="on">TV</button>
      <button id="tabPlex">Plex</button>
      <button id="tabJF">Jellyfin</button>
      <input id="q" type="search" placeholder="Rechercher…">
    </header>
    <div id="crumbs"></div>
    <div class="wrap"><div id="groups"></div><div id="grid"></div></div>
    <div id="player">
      <video id="v" controls playsinline autoplay></video>
      <div id="pbar"><button class="btn" id="pback">← Retour</button><span id="ptitle"></span></div>
      <div id="perr"></div>
      <div id="ptap">▶ Toucher pour lire</div>
    </div>
    <script src="/lib/hls.min.js"></script>
    <script src="/lib/mpegts.js"></script>
    <script>
    function $(id) { return document.getElementById(id); }
    function esc(s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return '&#' + c.charCodeAt(0) + ';'; }); }
    function getJSON(url, ok, fail) {
      var x = new XMLHttpRequest();
      x.open('GET', url, true); x.setRequestHeader('Accept', 'application/json'); x.timeout = 20000;
      x.onload = function () {
        if (x.status >= 200 && x.status < 300) { try { ok(JSON.parse(x.responseText)); return; } catch (e) {} }
        if (fail) fail(x.status + ' ' + (x.responseText || '').slice(0, 200));
      };
      x.onerror = x.ontimeout = function () { if (fail) fail('réseau'); };
      x.send();
    }
    var mode = 'tv', grid = $('grid'), groupsEl = $('groups'), crumbs = $('crumbs');

    // ---------- IPTV ----------
    var iptv = null, curGroup = -1, shown = 0, PAGE = 120;
    function loadTV() {
      groupsEl.style.display = ''; crumbs.innerHTML = '';
      if (iptv) return renderTV();
      grid.innerHTML = '<div class="msg">Chargement des chaînes…</div>';
      getJSON('/api/iptv', function (d) { iptv = d; renderGroups(); renderTV(); },
              function (e) { grid.innerHTML = '<div class="msg">Erreur : ' + esc(e) + '</div>'; });
    }
    function renderGroups() {
      var h = '<div data-g="-1" class="' + (curGroup < 0 ? 'on' : '') + '">Toutes (' + iptv.channels.length + ')</div>';
      for (var i = 0; i < iptv.groups.length; i++) h += '<div data-g="' + i + '" class="' + (curGroup === i ? 'on' : '') + '">' + esc(iptv.groups[i]) + '</div>';
      groupsEl.innerHTML = h;
    }
    groupsEl.onclick = function (e) {
      var g = e.target.getAttribute('data-g'); if (g == null) return;
      curGroup = parseInt(g, 10); renderGroups(); renderTV();
    };
    function tvMatches() {
      var q = $('q').value.toLowerCase(), out = [], c = iptv.channels;
      for (var i = 0; i < c.length; i++) {
        if (curGroup >= 0 && c[i][1] !== curGroup) continue;
        if (q && c[i][0].toLowerCase().indexOf(q) < 0) continue;
        out.push(i);
      }
      return out;
    }
    function renderTV(append) {
      if (!iptv.channels.length) {
        grid.innerHTML = '<div class="msg">Aucune chaîne. Ajoutez votre liste IPTV (M3U ou Xtream) dans l\'app TeslaMirror sur l\'iPhone.</div>';
        return;
      }
      var list = tvMatches(), h = '';
      if (!append) shown = 0;
      var end = Math.min(list.length, shown + PAGE);
      for (var k = shown; k < end; k++) {
        var i = list[k], c = iptv.channels[i];
        h += '<div class="card" data-i="' + i + '">' + (c[2] ? '<img loading="lazy" src="' + esc(c[2]) + '" onerror="this.style.visibility=\'hidden\'">' : '<img alt="">') + esc(c[0]) + '</div>';
      }
      shown = end;
      var old = $('more'); if (old) old.parentNode.removeChild(old);
      if (append) grid.insertAdjacentHTML('beforeend', h); else grid.innerHTML = h || '<div class="msg">Aucun résultat.</div>';
      if (shown < list.length) grid.insertAdjacentHTML('beforeend', '<button class="btn" id="more">Afficher plus (' + (list.length - shown) + ')</button>');
    }

    // ---------- Plex ----------
    var plexStack = [];
    function plexThumb(t) { return t ? '/plex/photo/:/transcode?width=300&height=450&minSize=1&upscale=1&url=' + encodeURIComponent(t) : ''; }
    function loadPlex() {
      groupsEl.style.display = 'none';
      if (plexStack.length) return plexOpen(plexStack.pop());
      getJSON('/api/plex', function (s) {
        if (!s.configured) { grid.innerHTML = '<div class="msg">Plex n\'est pas connecté. Ouvrez l\'app TeslaMirror sur l\'iPhone › Plex › Se connecter.</div>'; return; }
        plexStack = [];
        plexOpen({ title: s.name || 'Plex', url: '/plex/library/sections', kind: 'sections' });
      });
    }
    function plexOpen(level) {
      plexStack.push(level);
      var h = '';
      for (var i = 0; i < plexStack.length; i++) h += '<a href="#" data-l="' + i + '">' + esc(plexStack[i].title) + '</a>' + (i < plexStack.length - 1 ? '› ' : '');
      crumbs.innerHTML = h;
      grid.innerHTML = '<div class="msg">Chargement…</div>';
      getJSON(level.url, function (d) { renderPlex(level, (d.MediaContainer || {})); },
              function (e) { grid.innerHTML = '<div class="msg">Erreur Plex : ' + esc(e) + '</div>'; });
    }
    crumbs.onclick = function (e) {
      var l = e.target.getAttribute('data-l'); if (l == null) return;
      e.preventDefault();
      if (mode === 'jf') { var j = jfStack[+l]; jfStack = jfStack.slice(0, +l); return jfOpen(j); }
      var lvl = plexStack[+l]; plexStack = plexStack.slice(0, +l); plexOpen(lvl);
    };
    var plexItems = [];
    function renderPlex(level, mc) {
      var h = '', q = $('q').value.toLowerCase();
      plexItems = [];
      if (level.kind === 'sections') {
        plexItems.push({ type: 'dir', title: 'En cours', url: '/plex/library/onDeck' });
        (mc.Directory || []).forEach(function (d) {
          if (d.type === 'movie' || d.type === 'show')
            plexItems.push({ type: 'dir', title: d.title, url: '/plex/library/sections/' + d.key + '/all?X-Plex-Container-Start=0&X-Plex-Container-Size=500' });
        });
        plexItems.forEach(function (it, i) { h += '<div class="card" data-p="' + i + '" style="padding:28px 10px;font-size:20px">' + esc(it.title) + '</div>'; });
      } else {
        (mc.Metadata || []).forEach(function (m) {
          if (q && (m.title || '').toLowerCase().indexOf(q) < 0) return;
          var it = { type: m.type, title: m.title, key: m.ratingKey, thumb: m.thumb || m.parentThumb || m.grandparentThumb };
          if (m.type === 'episode') it.title = (m.grandparentTitle ? m.grandparentTitle + ' · ' : '') + 'E' + (m.index || '') + ' ' + m.title;
          if (m.type === 'show' || m.type === 'season') it.url = '/plex/library/metadata/' + m.ratingKey + '/children';
          plexItems.push(it);
        });
        plexItems.forEach(function (it, i) {
          h += '<div class="card poster" data-p="' + i + '">' + (it.thumb ? '<img loading="lazy" src="' + plexThumb(it.thumb) + '">' : '<img alt="">') + esc(it.title) + '</div>';
        });
      }
      grid.innerHTML = h || '<div class="msg">Vide.</div>';
    }
    function plexClick(i) {
      var it = plexItems[i]; if (!it) return;
      if (it.type === 'movie' || it.type === 'episode' || it.type === 'clip') return playPlex(it);
      if (it.url) plexOpen({ title: it.title, url: it.url, kind: 'list' });
    }
    var plexSession = null;
    function playPlex(it) {
      plexSession = 'tm' + Date.now();
      var q = 'path=' + encodeURIComponent('/library/metadata/' + it.key) +
        '&mediaIndex=0&partIndex=0&protocol=hls&fastSeek=1&directPlay=0&directStream=1&directStreamAudio=1' +
        '&subtitleSize=100&audioBoost=100&location=wan&videoResolution=1920x1080&maxVideoBitrate=8000' +
        '&subtitles=burn&copyts=1&session=' + plexSession + '&X-Plex-Session-Identifier=' + plexSession;
      play('/plex/video/:/transcode/universal/start.m3u8?' + q, it.title, true);
    }

    // ---------- Jellyfin ----------
    var jf = null, jfStack = [], jfItems = [];
    function jfList(id, type) {
      var sort = (type === 'Series' || type === 'Season') ? 'ParentIndexNumber,IndexNumber' : 'SortName';
      return '/jf/Users/' + jf.userId + '/Items?ParentId=' + id + '&SortBy=' + sort + '&Limit=500&Fields=PrimaryImageAspectRatio';
    }
    function loadJF() {
      groupsEl.style.display = 'none';
      getJSON('/api/jellyfin', function (s) {
        if (!s.configured) { crumbs.innerHTML = ''; grid.innerHTML = '<div class="msg">Jellyfin n\'est pas connecté. Ouvrez l\'app TeslaMirror sur l\'iPhone › Jellyfin.</div>'; return; }
        jf = s; jfStack = [];
        jfOpen({ title: s.name || 'Jellyfin', url: '/jf/Users/' + s.userId + '/Views', kind: 'views' });
      });
    }
    function jfOpen(level) {
      jfStack.push(level);
      var h = '';
      for (var i = 0; i < jfStack.length; i++) h += '<a href="#" data-l="' + i + '">' + esc(jfStack[i].title) + '</a>' + (i < jfStack.length - 1 ? '› ' : '');
      crumbs.innerHTML = h;
      grid.innerHTML = '<div class="msg">Chargement…</div>';
      getJSON(level.url, function (d) { renderJF(level, d); },
              function (e) { grid.innerHTML = '<div class="msg">Erreur Jellyfin : ' + esc(e) + '</div>'; });
    }
    function renderJF(level, d) {
      var h = '', q = $('q').value.toLowerCase();
      jfItems = [];
      if (level.kind === 'views') {
        jfItems.push({ type: 'dir', title: 'Reprendre', url: '/jf/Users/' + jf.userId + '/Items/Resume?MediaTypes=Video&Limit=60' });
      }
      (d.Items || []).forEach(function (m) {
        if (q && (m.Name || '').toLowerCase().indexOf(q) < 0) return;
        var it = { type: m.Type, title: m.Name, id: m.Id };
        if (m.Type === 'Episode') it.title = (m.SeriesName ? m.SeriesName + ' · ' : '') + 'S' + (m.ParentIndexNumber || '') + 'E' + (m.IndexNumber || '') + ' ' + m.Name;
        if (m.ImageTags && m.ImageTags.Primary) it.thumb = '/jf/Items/' + m.Id + '/Images/Primary?maxHeight=450&quality=80';
        else if (m.SeriesId && m.SeriesPrimaryImageTag) it.thumb = '/jf/Items/' + m.SeriesId + '/Images/Primary?maxHeight=450&quality=80';
        if (!/^(Movie|Episode|Video|MusicVideo|TvChannel)$/.test(m.Type)) it.url = jfList(m.Id, m.Type);
        jfItems.push(it);
      });
      jfItems.forEach(function (it, i) {
        if (it.type === 'dir') { h += '<div class="card" data-j="' + i + '" style="padding:28px 10px;font-size:20px">' + esc(it.title) + '</div>'; return; }
        h += '<div class="card poster" data-j="' + i + '">' + (it.thumb ? '<img loading="lazy" src="' + it.thumb + '">' : '<img alt="">') + esc(it.title) + '</div>';
      });
      grid.innerHTML = h || '<div class="msg">Vide.</div>';
    }
    function jfClick(i) {
      var it = jfItems[i]; if (!it) return;
      if (it.url) return jfOpen({ title: it.title, url: it.url, kind: 'list' });
      var sess = 'tm' + Date.now();
      play('/jf/Videos/' + it.id + '/master.m3u8?MediaSourceId=' + it.id +
           '&VideoCodec=h264&AudioCodec=aac,mp3&MaxStreamingBitrate=8000000&TranscodingMaxAudioChannels=2' +
           '&SegmentContainer=ts&MinSegments=1&BreakOnNonKeyFrames=true&PlaySessionId=' + sess + '&DeviceId=teslamirror',
           it.title, true);
    }

    grid.onclick = function (e) {
      var el = e.target; while (el && el !== grid && !el.getAttribute('data-i') && !el.getAttribute('data-p') && !el.getAttribute('data-j') && el.id !== 'more') el = el.parentNode;
      if (!el || el === grid) return;
      if (el.id === 'more') return renderTV(true);
      if (el.getAttribute('data-i') != null) { var i = +el.getAttribute('data-i'); return play('/iptv/' + i, iptv.channels[i][0], false); }
      if (el.getAttribute('data-j') != null) return jfClick(+el.getAttribute('data-j'));
      plexClick(+el.getAttribute('data-p'));
    };

    // ---------- Lecteur ----------
    var v = $('v'), hls = null, ts = null, barTimer = null;
    function stopEngines() {
      if (hls) { try { hls.destroy(); } catch (e) {} hls = null; }
      if (ts) { try { ts.destroy(); } catch (e) {} ts = null; }
      v.onerror = null; v.removeAttribute('src'); try { v.load(); } catch (e) {}
    }
    function showErr(t) { $('perr').textContent = t; $('perr').style.display = 'block'; }
    function tryPlay() {
      var p = v.play();
      if (p && p.catch) p.catch(function () { $('ptap').style.display = 'flex'; });
    }
    $('ptap').onclick = function () { $('ptap').style.display = 'none'; v.muted = false; tryPlay(); };
    function showBar() {
      $('pbar').style.opacity = '1'; clearTimeout(barTimer);
      barTimer = setTimeout(function () { $('pbar').style.opacity = '0'; }, 3500);
    }
    $('player').addEventListener('click', showBar);
    $('player').addEventListener('touchstart', showBar);
    function codecMsg() { showErr('Format non lisible par le navigateur de la voiture (souvent HEVC/H.265, MPEG-2 ou AC-3). Essayez une autre chaîne ou une autre qualité.'); }

    function play(url, title, isPlex) {
      stopEngines();
      $('perr').style.display = 'none'; $('ptap').style.display = 'none';
      $('ptitle').textContent = title; $('player').style.display = 'block'; showBar();
      var abs = location.protocol + '//' + location.host + url;
      if (!isPlex && /\.(mp4|m4v|mov|webm|mkv)(\?|$)/i.test(title + ' ' + url)) return playNative(abs);
      playHls(abs, isPlex ? null : function () { playTs(abs, function () { playNative(abs); }); });
    }
    function playHls(url, fallback) {
      if (!window.Hls || !Hls.isSupported()) { return fallback ? fallback() : playNative(url); }
      hls = new Hls({ maxBufferLength: 30, backBufferLength: 30, manifestLoadingMaxRetry: 2 });
      hls.on(Hls.Events.ERROR, function (ev, d) {
        if (!d.fatal) return;
        if (d.details === 'manifestParsingError' && fallback) { hls.destroy(); hls = null; return fallback(); }
        if (/Codec|incompatible/i.test(d.details)) return codecMsg();
        if (d.type === Hls.ErrorTypes.NETWORK_ERROR) {
          var code = d.response && d.response.code;
          if (fallback && !code) { hls.destroy(); hls = null; return fallback(); }
          return showErr('Source injoignable (' + (code || d.details) + ').');
        }
        if (d.type === Hls.ErrorTypes.MEDIA_ERROR) { hls.recoverMediaError(); return; }
        showErr('Erreur de lecture : ' + d.details);
      });
      hls.on(Hls.Events.MANIFEST_PARSED, tryPlay);
      hls.loadSource(url); hls.attachMedia(v);
    }
    function playTs(url, fallback) {
      if (!window.mpegts || !mpegts.getFeatureList().mseLivePlayback) return fallback();
      ts = mpegts.createPlayer({ type: 'mpegts', isLive: true, url: url },
                               { enableWorker: false, liveBufferLatencyChasing: true, lazyLoad: false });
      ts.on(mpegts.Events.ERROR, function (type, detail) {
        // Pas du MPEG-TS (fichier MP4, etc.) : on laisse le lecteur natif essayer.
        if (type === mpegts.ErrorTypes.MEDIA_ERROR) { try { ts.destroy(); } catch (e) {} ts = null; return fallback(); }
        showErr('Erreur flux : ' + detail);
      });
      ts.attachMediaElement(v); ts.load(); tryPlay();
    }
    function playNative(url) {
      v.onerror = function () { v.onerror = null; codecMsg(); };
      v.src = url; tryPlay();
    }
    $('pback').onclick = function (e) {
      e.stopPropagation(); stopEngines(); $('player').style.display = 'none';
      if (plexSession) { var x = new XMLHttpRequest(); x.open('GET', '/plex/video/:/transcode/universal/stop?session=' + plexSession, true); x.send(); plexSession = null; }
    };

    // ---------- Onglets ----------
    function setMode(m) {
      mode = m; $('tabTV').className = m === 'tv' ? 'on' : ''; $('tabPlex').className = m === 'plex' ? 'on' : '';
      $('tabJF').className = m === 'jf' ? 'on' : '';
      if (m === 'tv') loadTV(); else if (m === 'jf') loadJF(); else { plexStack = []; loadPlex(); }
    }
    $('tabTV').onclick = function () { setMode('tv'); };
    $('tabPlex').onclick = function () { setMode('plex'); };
    $('tabJF').onclick = function () { setMode('jf'); };
    var qTimer = null;
    $('q').oninput = function () {
      clearTimeout(qTimer);
      qTimer = setTimeout(function () {
        if (mode === 'tv' && iptv) renderTV();
        else if (mode === 'plex' && plexStack.length) { var l = plexStack.pop(); plexOpen(l); }
        else if (mode === 'jf' && jfStack.length) { var j = jfStack.pop(); jfOpen(j); }
      }, 250);
    };
    setMode(location.hash === '#plex' ? 'plex' : location.hash === '#jellyfin' ? 'jf' : 'tv');
    </script></body></html>
    """#
}

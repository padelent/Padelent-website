/* Padelent app. Plain JavaScript, no build step. Talks to Supabase over its REST APIs. */
(function () {
  'use strict';

  var C = window.PADELENT_CONFIG || {};
  var SB = String(C.supabaseUrl || '').replace(/\/$/, '');
  var KEY = C.supabaseKey || '';
  var MAX_MB = C.maxVideoMB || 50;
  var $app = document.getElementById('app');

  /* ================================================================ utils */

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function money(p) { p = Number(p) || 0; return '£' + (p % 100 ? (p / 100).toFixed(2) : String(p / 100)); }
  function initials(n) {
    var w = String(n || '').trim().split(/\s+/).filter(Boolean);
    return (w.length ? w.slice(0, 2).map(function (x) { return x[0]; }).join('') : '?').toUpperCase();
  }
  function firstName(n) { return String(n || '').trim().split(/\s+/)[0] || ''; }
  function $(sel, root) { return (root || document).querySelector(sel); }
  function $$(sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }
  var store = {
    get: function (k) { try { return JSON.parse(localStorage.getItem(k)); } catch (e) { return null; } },
    set: function (k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) {} },
    del: function (k) { try { localStorage.removeItem(k); } catch (e) {} }
  };
  var toastTimer;
  function toast(msg, bad) {
    var t = document.getElementById('toast');
    t.textContent = msg; t.className = 'show' + (bad ? ' bad' : '');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { t.className = ''; }, bad ? 5000 : 3000);
  }
  var DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  var MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  function pad(n) { return n < 10 ? '0' + n : '' + n; }
  function when(ts) {
    if (!ts) return '';
    var d = new Date(ts), now = new Date();
    var day0 = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    var diff = Math.floor((day0 - new Date(d.getFullYear(), d.getMonth(), d.getDate())) / 86400000);
    var hm = pad(d.getHours()) + ':' + pad(d.getMinutes());
    if (diff <= 0) return 'Today, ' + hm;
    if (diff === 1) return 'Yesterday, ' + hm;
    if (diff < 7) return DAYS[d.getDay()] + ' ' + d.getDate() + ' ' + MONTHS[d.getMonth()];
    return d.getDate() + ' ' + MONTHS[d.getMonth()] + (d.getFullYear() !== now.getFullYear() ? ' ' + d.getFullYear() : '');
  }
  function shortDate(ts) { var d = new Date(ts); return d.getDate() + ' ' + MONTHS[d.getMonth()]; }

  var GRADS = [['#2E5A88', '#0E2238'], ['#3E6B4F', '#10261A'], ['#7A4A2A', '#2A170B'], ['#5B3E7A', '#1C1230'],
    ['#8A2E3B', '#2A0C12'], ['#2B6F73', '#0B2426'], ['#6E6A2A', '#22200A'], ['#2E4A88', '#0C1630']];
  function grad(id) {
    var h = 0, s = String(id || ''); for (var i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) >>> 0;
    var g = GRADS[h % GRADS.length]; return 'linear-gradient(160deg,' + g[0] + ',' + g[1] + ')';
  }
  var SIDE = { drive: 'Drive (right)', reves: 'Revés (left)', both: 'Both sides' };
  var HAND = { right: 'Right-handed', left: 'Left-handed' };
  var SPECIALITIES = ['Beginners', 'Bandeja', 'Víbora', 'Smash', 'Lob', 'Off the glass', 'Net play', 'Serve & return',
    'Footwork', 'Tactics', 'Left-handed players', 'Juniors'];
  var WORK_ON = ['Bandeja', 'Víbora', 'Smash', 'Lob', 'Off the glass', 'Net play', 'Serve & return', 'Footwork', 'Tactics', 'Volleys', 'Chiquita'];
  var LEVELS = ['0.5', '1.0', '1.5', '2.0', '2.5', '3.0', '3.5', '4.0', '4.5', '5.0', '5.5', '6.0', '7.0'];
  var STAR_WORDS = ['', 'Poor', 'Not great', 'Good', 'Great', 'Excellent'];
  var REVIEW_TAGS = ['Clear explanation', 'Great drills', 'Really detailed', 'Spotted my problem', 'Friendly', 'Worth the price'];

  /* ================================================================ icons */
  var I = {
    logo: '<svg aria-hidden="true" width="28" height="28" viewBox="0 0 28 28" fill="none"><circle cx="14" cy="14" r="12" fill="#D7F23A"/><path d="M4 9c5 2 7 8 5 15M24 19c-5-2-7-8-5-15" stroke="#0A1420" stroke-width="1.8" stroke-linecap="round"/></svg>',
    star: function (on, size) { size = size || 16; return '<svg aria-hidden="true" width="' + size + '" height="' + size + '" viewBox="0 0 24 24"><path d="M12 2.5l2.9 6.2 6.8.8-5 4.7 1.3 6.7L12 17.6 6 20.9l1.3-6.7-5-4.7 6.8-.8z" fill="' + (on === false ? 'none' : '#D7F23A') + '" stroke="' + (on === false ? '#4A5A6B' : '#D7F23A') + '" stroke-width="1.4" stroke-linejoin="round"/></svg>'; },
    tick: '<svg aria-label="Verified coach" role="img" width="18" height="18" viewBox="0 0 24 24"><circle cx="12" cy="12" r="11" fill="#D7F23A"/><path d="M7 12.5l3.2 3.2L17 9" stroke="#0A1420" stroke-width="2.4" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    play: '<svg aria-hidden="true" width="12" height="12" viewBox="0 0 12 12"><path d="M3 1.5v9l7.5-4.5z" fill="#0A1420"/></svg>',
    lock: '<svg aria-hidden="true" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#D7F23A" stroke-width="2.2"><rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V8a4 4 0 018 0v3"/></svg>',
    info: '<svg aria-hidden="true" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="#FFB547" stroke-width="2.2"><circle cx="12" cy="12" r="10"/><path d="M12 8h.01M11 12h1v5h1"/></svg>',
    court: '<svg class="court-bg" aria-hidden="true" viewBox="0 0 400 500" preserveAspectRatio="xMidYMid slice" fill="none"><path d="M110 60H290M110 60L-60 520M290 60L460 520M98 84H302M-40 470H440M200 84V470" stroke="#fff" stroke-width="2"/><path d="M55 190H345" stroke="#fff" stroke-width="5"/></svg>',
    home: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M3 11l9-7 9 7v9a1 1 0 01-1 1h-5v-6H9v6H4a1 1 0 01-1-1z"/></svg>',
    search: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="7"/><path d="M20 20l-4-4"/></svg>',
    lessons: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><rect x="3" y="5" width="13" height="14" rx="2"/><path d="M16 10l5-3v10l-5-3"/></svg>',
    user: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="8" r="4"/><path d="M4 21c1-4 4.5-6 8-6s7 2 8 6"/></svg>',
    money: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="2.5" y="6" width="19" height="12" rx="2"/><circle cx="12" cy="12" r="2.5"/></svg>',
    shield: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"/></svg>'
  };

  /* ================================================================ Supabase */

  var session = store.get('padelent.session');
  var me = null;
  var state = { newCount: 0 };

  function saveSession(s) { session = s; if (s) store.set('padelent.session', s); else store.del('padelent.session'); }
  function fromAuth(d) {
    return { access_token: d.access_token, refresh_token: d.refresh_token,
      expires_at: d.expires_at || Math.floor(Date.now() / 1000) + (Number(d.expires_in) || 3600), user: d.user || null };
  }
  function appUrl() { return location.origin + '/app/'; }

  function errMsg(d, status) {
    var m = d && typeof d === 'object' ? (d.message || d.msg || d.error_description || d.error) : (typeof d === 'string' ? d : '');
    m = String(m || '');
    if (/invalid login credentials/i.test(m)) return 'That email and password do not match.';
    if (/already registered|already been registered|already exists/i.test(m)) return 'There is already an account with that email. Try logging in.';
    if (/email not confirmed/i.test(m)) return 'Please confirm your email first. Check your inbox for our link.';
    if (/password should be at least/i.test(m)) return 'Your password needs at least 8 characters.';
    if (/rate limit|too many/i.test(m)) return 'Too many tries. Please wait a minute and try again.';
    if (/payload too large|maximum allowed size|exceeded the maximum/i.test(m)) return 'That file is too big. Keep videos under ' + MAX_MB + 'MB.';
    if (/mime type|invalid_mime/i.test(m)) return 'That file type is not supported. Use an MP4 or MOV video.';
    if (status === 401 || /jwt/i.test(m)) return 'Please log in again.';
    return m || 'Something went wrong. Please try again.';
  }

  function raw(method, path, body, useSession, headers) {
    var h = { apikey: KEY };
    if (body !== undefined) h['Content-Type'] = 'application/json';
    if (useSession && session) h.Authorization = 'Bearer ' + session.access_token;
    else if (KEY.indexOf('sb_') !== 0) h.Authorization = 'Bearer ' + KEY;
    if (headers) for (var k in headers) h[k] = headers[k];
    return fetch(SB + path, { method: method, headers: h, body: body !== undefined ? JSON.stringify(body) : undefined })
      .catch(function () { throw new Error('No connection. Check your signal and try again.'); })
      .then(function (r) {
        return r.text().then(function (t) {
          var d = null;
          if (t) { try { d = JSON.parse(t); } catch (e) { d = t; } }
          if (!r.ok) {
            if (r.status === 401 && useSession) { saveSession(null); me = null; }
            throw new Error(errMsg(d, r.status));
          }
          return d;
        });
      });
  }

  var refreshing = null;
  function fresh() {
    if (!session) return Promise.resolve();
    if (session.expires_at - 90 > Date.now() / 1000) return Promise.resolve();
    if (!refreshing) {
      refreshing = raw('POST', '/auth/v1/token?grant_type=refresh_token', { refresh_token: session.refresh_token }, false)
        .then(function (d) { saveSession(fromAuth(d)); })
        .catch(function () { saveSession(null); me = null; })
        .then(function () { refreshing = null; });
    }
    return refreshing;
  }
  function api(method, path, body) { return fresh().then(function () { return raw(method, path, body, true); }); }
  function rpc(fn, args) { return api('POST', '/rest/v1/rpc/' + fn, args || {}); }
  function rest(path) { return api('GET', '/rest/v1/' + path); }

  function encPath(p) { return p.split('/').map(encodeURIComponent).join('/'); }
  function publicUrl(path) { return SB + '/storage/v1/object/public/coach-media/' + encPath(path); }
  var VTYPES = { mp4: 'video/mp4', mov: 'video/quicktime', m4v: 'video/x-m4v', webm: 'video/webm', '3gp': 'video/3gpp' };
  function extOf(f) { var m = /\.([a-z0-9]+)$/i.exec(f.name || ''); return m ? m[1].toLowerCase() : ''; }
  function typeOf(f) { return f.type || VTYPES[extOf(f)] || 'video/mp4'; }
  function rand() { return Math.random().toString(36).slice(2, 10); }

  function upload(bucket, path, blob, type, onProgress) {
    return fresh().then(function () {
      return new Promise(function (resolve, reject) {
        if (!session) return reject(new Error('Please log in again.'));
        var x = new XMLHttpRequest();
        x.open('POST', SB + '/storage/v1/object/' + bucket + '/' + encPath(path));
        x.setRequestHeader('apikey', KEY);
        x.setRequestHeader('Authorization', 'Bearer ' + session.access_token);
        x.setRequestHeader('Content-Type', type);
        x.setRequestHeader('x-upsert', 'false');
        x.setRequestHeader('cache-control', '3600');
        if (x.upload && onProgress) x.upload.onprogress = function (e) { if (e.lengthComputable) onProgress(e.loaded / e.total); };
        x.onload = function () {
          if (x.status >= 200 && x.status < 300) { if (onProgress) onProgress(1); resolve(path); }
          else { var d; try { d = JSON.parse(x.responseText); } catch (e) { d = x.responseText; } reject(new Error(errMsg(d, x.status))); }
        };
        x.onerror = function () { reject(new Error('Upload failed. Check your connection and try again.')); };
        x.send(blob);
      });
    });
  }

  var signCache = {};
  function signedUrl(path) {
    var c = signCache[path];
    if (c && c.exp > Date.now()) return Promise.resolve(c.url);
    return api('POST', '/storage/v1/object/sign/lesson-videos/' + encPath(path), { expiresIn: 3600 }).then(function (d) {
      var u = d && (d.signedURL || d.signedUrl);
      if (!u) throw new Error('Video not available.');
      if (u.indexOf('http') !== 0) u = SB + '/storage/v1' + (u.charAt(0) === '/' ? '' : '/') + u;
      signCache[path] = { url: u, exp: Date.now() + 50 * 60 * 1000 };
      return u;
    });
  }
  function hydrateVideos(root) {
    $$('video[data-path]', root).forEach(function (v) {
      signedUrl(v.getAttribute('data-path')).then(function (u) { v.src = u + '#t=0.1'; })
        .catch(function () { v.outerHTML = '<div class="file small muted">This video could not be loaded.</div>'; });
    });
  }

  function loadMe() {
    if (!session) { me = null; return Promise.resolve(null); }
    return rpc('my_profile').then(function (p) { me = p || null; if (!me) saveSession(null); return me; })
      .catch(function (e) { if (!session) me = null; throw e; });
  }
  function refreshNewCount() {
    if (!me || me.role !== 'coach') return Promise.resolve();
    return rpc('coach_feed').then(function (f) { state.newCount = (f || []).filter(function (l) { return l.status === 'new' || l.needs_coach; }).length; updateBadges(); }).catch(function () {});
  }
  function updateBadges() {
    $$('[data-badge]').forEach(function (b) { b.textContent = state.newCount; b.style.display = state.newCount ? '' : 'none'; });
  }

  /* ================================================================ shell */

  var navToken = 0;
  function navItems() {
    if (!me) return [['#/home', 'Coaches', 'search', 'home']];
    var a = me.role === 'coach'
      ? [['#/lessons', 'Lessons', 'lessons', 'lessons', true], ['#/home', 'Coaches', 'search', 'home'], ['#/profile', 'My profile', 'user', 'profile'], ['#/earnings', 'Earnings', 'money', 'earnings']]
      : [['#/home', 'Home', 'home', 'home'], ['#/coaches', 'Coaches', 'search', 'coaches'], ['#/lessons', 'My lessons', 'lessons', 'lessons'], ['#/profile', 'Profile', 'user', 'profile']];
    if (me.is_admin) a.push(['#/admin', 'Admin', 'shield', 'admin']);
    return a;
  }
  function shell(active, inner, opts) {
    opts = opts || {};
    var items = navItems();
    var nav = items.map(function (n) {
      return '<a href="' + n[0] + '" class="' + (n[3] === active ? 'on' : '') + '">' + n[1] +
        (n[4] ? '<span class="count" data-badge style="display:none"></span>' : '') + '</a>';
    }).join('');
    var right = me
      ? '<a class="avatar acc" href="#/profile" aria-label="My profile">' + esc(initials(me.full_name)) + '</a>'
      : '<a class="btn sm" href="#/login">Log in</a><a class="btn sm acc" href="#/signup">Sign up</a>';
    var tabs = me ? '<nav class="tabbar" aria-label="App">' + items.map(function (n) {
      return '<a href="' + n[0] + '" class="' + (n[3] === active ? 'on' : '') + '">' + I[n[2]] + '<span>' + n[1] + '</span>' +
        (n[4] ? '<span class="dot" data-badge style="display:none"></span>' : '') + '</a>';
    }).join('') + '</nav>' : '';
    return '<header class="top"><div class="top-in">' +
      '<a class="logo" href="#/">' + I.logo + 'Padelent</a>' +
      (me ? '<span class="pill-tag">' + (me.role === 'coach' ? 'Coach' : 'Player') + '</span>' : '') +
      '<nav class="nav" aria-label="Main">' + nav + '</nav>' +
      '<div style="display:flex;gap:10px;align-items:center;' + (me ? '' : 'margin-left:auto') + '">' + right + '</div>' +
      '</div></header>' +
      '<main class="page' + (opts.narrow ? ' narrow' : '') + '" id="main">' + inner + '</main>' + tabs;
  }
  function render(html) { $app.innerHTML = html; updateBadges(); window.scrollTo(0, 0); }
  function loading(active) { render(shell(active, '<div class="boot" style="min-height:40vh"><span class="spinner"></span></div>')); }
  function failed(active, e) {
    render(shell(active, '<div class="empty"><h2>Something went wrong</h2><p class="muted">' + esc(e && e.message) +
      '</p><button class="btn acc" onclick="location.reload()">Try again</button></div>'));
  }
  function go(h) { if (location.hash === h) route(); else location.hash = h; }

  /* ================================================================ pieces */

  function photoBox(name, id, url, ratio, video) {
    return '<div class="ph" style="background:' + grad(id) + ';aspect-ratio:' + (ratio || '4 / 5') + '">' + I.court.replace('court-bg', 'court-bg" style="opacity:.18') +
      (url ? '<img src="' + esc(url) + '" alt="" loading="lazy">' : '<span class="ini">' + esc(initials(name)) + '</span>') +
      (video ? '<span class="badge">' + I.play + 'Intro video</span>' : '') + '</div>';
  }
  function ratingHtml(c) {
    return c.review_count > 0
      ? '<span class="star">' + I.star() + fmtRating(c.avg_rating) + ' <span class="muted">(' + c.review_count + ')</span></span>'
      : '<span class="muted" style="font-weight:700">New coach</span>';
  }
  function fmtRating(x) { var r = Math.round(Number(x) * 100) / 100; return r % 1 === 0 ? r.toFixed(1) : String(r); }
  function playLine(c) {
    return [SIDE[c.side] ? SIDE[c.side].replace(/ \(.*\)/, '') : '', HAND[c.hand] || ''].filter(Boolean).join(' · ');
  }
  function coachCard(c) {
    var where = [c.club, c.city].filter(Boolean).join(', ');
    return '<a class="ccard" href="#/coach/' + c.id + '">' + photoBox(c.full_name, c.id, c.photo_url, null, !!c.intro_video_url) +
      '<div style="display:flex;flex-direction:column;gap:3px;min-width:0">' +
      '<div class="cname"><span>' + esc(c.full_name) + '</span>' + I.tick + '</div>' +
      (where ? '<div class="muted small">' + esc(where) + '</div>' : '') +
      (playLine(c) ? '<div class="small" style="color:#D5DEE6">' + esc(playLine(c)) + '</div>' : '') + '</div>' +
      '<div class="meta">' + ratingHtml(c) + '<span>' + money(c.price_pence) + '<span class="muted"> / lesson</span></span></div>' +
      (c.lessons_done ? '<div class="muted small">' + c.lessons_done + ' lesson' + (c.lessons_done === 1 ? '' : 's') + ' given</div>' : '') + '</a>';
  }
  // Blue = still open or needs the coach. Green = done (follow-up chat still open). Grey = closed.
  function statusPill(s, forRole, l) {
    l = l || {};
    var cls, label;
    if (s === 'done' && l.closed_at) { cls = 'closed'; label = 'Closed'; }
    else if (s === 'done' && forRole === 'coach' && l.needs_coach) { cls = 'open fresh'; label = 'New message'; }
    else if (s === 'done') { cls = 'done'; label = 'Done'; }
    else if (forRole === 'coach') { cls = 'open' + (s === 'new' ? ' fresh' : ''); label = s === 'new' ? 'New' : 'Awaiting your reply'; }
    else { cls = 'open'; label = 'Open'; }
    return '<span class="st ' + cls + '"><i></i>' + label + '</span>';
  }
  function fileRow(f, i) {
    return '<div class="file" data-i="' + i + '"><span class="nm">' + esc(f.name || 'Video') + '</span><span class="muted small">' +
      (f.size / 1048576).toFixed(f.size > 10485760 ? 0 : 1) + 'MB</span><span class="prog"><b></b></span>' +
      '<button type="button" class="x" aria-label="Remove ' + esc(f.name) + '">×</button></div>';
  }
  function pickVideos(listEl, files, max) {
    // returns a small controller that keeps a list of chosen video files
    var ctl = { files: files || [], max: max || 3 };
    ctl.add = function (list) {
      Array.prototype.forEach.call(list, function (f) {
        if (ctl.files.length >= ctl.max) { toast('You can add up to ' + ctl.max + ' videos.', true); return; }
        if (!/^video\//.test(typeOf(f))) { toast(f.name + ' is not a video.', true); return; }
        if (f.size > MAX_MB * 1048576) { toast(f.name + ' is over ' + MAX_MB + 'MB. Trim it or film at 1080p instead of 4K.', true); return; }
        ctl.files.push(f);
      });
      ctl.draw();
    };
    ctl.draw = function () {
      listEl.innerHTML = ctl.files.map(fileRow).join('');
      $$('.x', listEl).forEach(function (b, i) { b.onclick = function () { ctl.files.splice(i, 1); ctl.draw(); }; });
      if (ctl.onchange) ctl.onchange();
    };
    ctl.uploadAll = function () {
      var paths = [];
      return ctl.files.reduce(function (p, f, i) {
        return p.then(function () {
          var bar = $('.file[data-i="' + i + '"] .prog b', listEl);
          var ext = extOf(f) || (typeOf(f) === 'video/quicktime' ? 'mov' : 'mp4');
          var path = me.id + '/' + Date.now() + '-' + rand() + '.' + ext;
          $$('.x', listEl).forEach(function (b) { b.disabled = true; });
          return upload('lesson-videos', path, f, typeOf(f), function (r) { if (bar) bar.style.width = Math.round(r * 100) + '%'; })
            .then(function (pth) { paths.push(pth); });
        });
      }, Promise.resolve()).then(function () { return paths; });
    };
    return ctl;
  }
  function videoTags(paths) {
    if (!paths || !paths.length) return '';
    return '<div class="vids">' + paths.map(function (p) {
      return '<video controls playsinline preload="metadata" data-path="' + esc(p) + '"></video>';
    }).join('') + '</div>';
  }
  function needPlayer(active) {
    if (!me) { go('#/login?next=' + encodeURIComponent(location.hash)); return false; }
    return true;
  }

  /* ================================================================ auth pages */

  function authFrame(inner) {
    return '<div class="auth">' + I.court.replace('court-bg', 'court-bg" style="opacity:.1') +
      '<a class="logo" href="/" style="position:relative;font-size:28px">' + I.logo + 'Padelent</a>' +
      '<div class="box">' + inner + '</div>' +
      '<p class="small muted" style="position:relative">Padel plus talent · <a href="/privacy.html">Privacy</a></p></div>';
  }
  function qs(name) {
    var q = (location.hash.split('?')[1] || '');
    var m = new RegExp('(?:^|&)' + name + '=([^&]*)').exec(q);
    return m ? decodeURIComponent(m[1]) : '';
  }
  function afterAuth() {
    var next = qs('next') || store.get('padelent.next') || '#/';
    store.del('padelent.next');
    if (next.indexOf('#/') !== 0) next = '#/';
    return loadMe().then(function () { refreshNewCount(); go(next); });
  }

  function pageLogin() {
    if (me) return go('#/');
    $app.innerHTML = authFrame(
      '<h1 style="font-size:32px">Log in</h1>' +
      '<form class="form" id="f" novalidate>' +
      '<label class="f">Email<input class="in" type="email" name="email" autocomplete="email" required></label>' +
      '<label class="f">Password<input class="in" type="password" name="password" autocomplete="current-password" required></label>' +
      '<p class="err" id="e" hidden></p>' +
      '<button class="btn acc big block" type="submit">Log in</button></form>' +
      '<div style="display:flex;justify-content:space-between;flex-wrap:wrap;gap:8px">' +
      '<a class="link" href="#/forgot">Forgot password?</a><a class="link" href="#/signup' + (qs('next') ? '?next=' + encodeURIComponent(qs('next')) : '') + '">Create an account</a></div>');
    $('#f').onsubmit = function (ev) {
      ev.preventDefault();
      var f = ev.target, b = $('button[type=submit]', f), e = $('#e');
      e.hidden = true; b.disabled = true; b.textContent = 'Logging in…';
      raw('POST', '/auth/v1/token?grant_type=password', { email: f.email.value.trim(), password: f.password.value }, false)
        .then(function (d) { saveSession(fromAuth(d)); return afterAuth(); })
        .catch(function (err) { e.textContent = err.message; e.hidden = false; b.disabled = false; b.textContent = 'Log in'; });
    };
  }

  function pageSignup() {
    if (me) return go('#/');
    var role = qs('role') === 'coach' ? 'coach' : 'player';
    $app.innerHTML = authFrame(
      '<h1 style="font-size:32px">Create your account</h1>' +
      '<form class="form" id="f" novalidate>' +
      '<div class="f" style="display:flex;flex-direction:column;gap:8px;font-weight:700">I am a' +
      '<div class="seg" role="radiogroup" aria-label="Account type">' +
      '<button type="button" class="chip' + (role === 'player' ? ' on' : '') + '" data-role="player" role="radio" aria-checked="' + (role === 'player') + '">Player</button>' +
      '<button type="button" class="chip' + (role === 'coach' ? ' on' : '') + '" data-role="coach" role="radio" aria-checked="' + (role === 'coach') + '">Coach</button></div></div>' +
      '<label class="f">Full name<input class="in" name="name" autocomplete="name" required maxlength="80"></label>' +
      '<label class="f">Email<input class="in" type="email" name="email" autocomplete="email" required></label>' +
      '<label class="f">Password <span class="hint">At least 8 characters</span><input class="in" type="password" name="password" autocomplete="new-password" minlength="8" required></label>' +
      '<p class="small muted" id="rolehint"></p>' +
      '<p class="err" id="e" hidden></p>' +
      '<button class="btn acc big block" type="submit">Create account</button>' +
      '<p class="small muted">By signing up you agree to how we use your details in our <a href="/privacy.html">privacy notice</a>.</p></form>' +
      '<a class="link" href="#/login' + (qs('next') ? '?next=' + encodeURIComponent(qs('next')) : '') + '">I already have an account</a>');
    function setRole(r) {
      role = r;
      $$('[data-role]').forEach(function (b) { var on = b.getAttribute('data-role') === r; b.classList.toggle('on', on); b.setAttribute('aria-checked', on); });
      $('#rolehint').textContent = r === 'coach'
        ? 'Coach accounts are checked by us before your profile goes live.'
        : 'Find a coach, send a clip of your game and get a video lesson back.';
    }
    $$('[data-role]').forEach(function (b) { b.onclick = function () { setRole(b.getAttribute('data-role')); }; });
    setRole(role);
    $('#f').onsubmit = function (ev) {
      ev.preventDefault();
      var f = ev.target, b = $('button[type=submit]', f), e = $('#e');
      var name = f.name.value.trim(), email = f.email.value.trim(), pw = f.password.value;
      e.hidden = true;
      if (!name) { e.textContent = 'Please add your name.'; e.hidden = false; return; }
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) { e.textContent = 'Please check your email address.'; e.hidden = false; return; }
      if (pw.length < 8) { e.textContent = 'Your password needs at least 8 characters.'; e.hidden = false; return; }
      b.disabled = true; b.textContent = 'Creating account…';
      if (qs('next')) store.set('padelent.next', qs('next'));
      raw('POST', '/auth/v1/signup?redirect_to=' + encodeURIComponent(appUrl()),
        { email: email, password: pw, data: { role: role, full_name: name } }, false)
        .then(function (d) {
          if (d && d.access_token) { saveSession(fromAuth(d)); return afterAuth(); }
          if (d && d.user && Array.isArray(d.user.identities) && d.user.identities.length === 0) {
            throw new Error('There is already an account with that email. Try logging in.');
          }
          $('.box').innerHTML = '<h1 style="font-size:30px">Check your email</h1><p>We have sent a link to <b>' + esc(email) +
            '</b>. Tap it to confirm your account and you will be logged straight in.</p><p class="muted small">Not there? Check your junk folder.</p>';
        })
        .catch(function (err) { e.textContent = err.message; e.hidden = false; b.disabled = false; b.textContent = 'Create account'; });
    };
  }

  function pageForgot() {
    $app.innerHTML = authFrame(
      '<h1 style="font-size:32px">Reset password</h1><p class="muted">Enter your email and we will send you a link to set a new password.</p>' +
      '<form class="form" id="f" novalidate><label class="f">Email<input class="in" type="email" name="email" autocomplete="email" required></label>' +
      '<p class="err" id="e" hidden></p><button class="btn acc big block" type="submit">Send link</button></form>' +
      '<a class="link" href="#/login">Back to log in</a>');
    $('#f').onsubmit = function (ev) {
      ev.preventDefault();
      var f = ev.target, b = $('button[type=submit]', f), e = $('#e');
      b.disabled = true;
      raw('POST', '/auth/v1/recover?redirect_to=' + encodeURIComponent(appUrl()), { email: f.email.value.trim() }, false)
        .then(function () { $('.box').innerHTML = '<h1 style="font-size:30px">Check your email</h1><p>If there is an account for that email, a reset link is on its way.</p><a class="link" href="#/login">Back to log in</a>'; })
        .catch(function (err) { e.textContent = err.message; e.hidden = false; b.disabled = false; });
    };
  }

  function pageReset() {
    if (!session) return go('#/login');
    $app.innerHTML = authFrame(
      '<h1 style="font-size:32px">Set a new password</h1>' +
      '<form class="form" id="f" novalidate><label class="f">New password <span class="hint">At least 8 characters</span><input class="in" type="password" name="password" autocomplete="new-password" minlength="8" required></label>' +
      '<p class="err" id="e" hidden></p><button class="btn acc big block" type="submit">Save password</button></form>');
    $('#f').onsubmit = function (ev) {
      ev.preventDefault();
      var f = ev.target, e = $('#e');
      if (f.password.value.length < 8) { e.textContent = 'Your password needs at least 8 characters.'; e.hidden = false; return; }
      api('PUT', '/auth/v1/user', { password: f.password.value })
        .then(function () { toast('Password saved'); return afterAuth(); })
        .catch(function (err) { e.textContent = err.message; e.hidden = false; });
    };
  }

  /* ================================================================ player: home + coaches */

  function scoreFor(c, p) {
    var s = (c.review_count ? Number(c.avg_rating) : 4.2);
    if (p) {
      var spec = (c.specialities || []).map(function (x) { return x.toLowerCase(); });
      (p.working_on || []).forEach(function (w) { if (spec.indexOf(String(w).toLowerCase()) >= 0) s += 2; });
      if (p.side && c.side && (c.side === p.side || c.side === 'both')) s += 1;
      if (p.hand === 'left' && (c.hand === 'left' || spec.indexOf('left-handed players') >= 0)) s += 1.5;
      if (p.level != null && Number(p.level) < 2 && spec.indexOf('beginners') >= 0) s += 1.5;
    }
    return s + Math.min(c.lessons_done || 0, 100) / 100;
  }
  function filterCoaches(list, f) {
    if (!f || f === 'All') return list;
    if (f === 'Left-handed coaches') return list.filter(function (c) { return c.hand === 'left'; });
    if (f === 'Under £30') return list.filter(function (c) { return c.price_pence < 3000; });
    return list.filter(function (c) { return (c.specialities || []).some(function (s) { return s.toLowerCase() === f.toLowerCase(); }); });
  }

  function pageHome(onlyList) {
    var t = ++navToken, active = onlyList ? 'coaches' : 'home';
    if (me && me.role === 'coach' && !onlyList && location.hash.indexOf('#/home') !== 0) return go('#/lessons');
    loading(active);
    rest('coach_cards?select=*').then(function (cards) {
      if (t !== navToken) return;
      cards = cards || [];
      var p = me && me.player;
      var filter = 'All';
      var chips = ['All', 'Left-handed coaches', 'Under £30'].concat(SPECIALITIES.filter(function (s) { return s !== 'Left-handed players'; }));
      var hero = '';
      if (!onlyList) {
        if (me && me.role === 'player') {
          var hasGame = p && (p.level != null || p.side || (p.working_on || []).length);
          hero = '<div class="hero"><div class="panel welcome">' + I.court +
            '<div style="position:relative"><div class="slogan">Padel plus talent</div>' +
            '<h1 style="margin-top:8px">Welcome back, ' + esc(firstName(me.full_name) || 'there') + '</h1>' +
            '<p style="margin-top:8px;color:#D5DEE6;max-width:520px">Pick a coach, upload a clip of your game and get a personal video lesson back.</p></div>' +
            '<div style="position:relative;display:flex;gap:10px;flex-wrap:wrap"><a class="btn acc" href="#/coaches">Find a coach</a><a class="btn" href="#/lessons">My lessons</a></div></div>' +
            '<div class="panel" style="display:flex;flex-direction:column;gap:14px"><div style="display:flex;justify-content:space-between;align-items:center"><h3>Your game</h3><a class="link" href="#/profile">' + (hasGame ? 'Edit' : 'Add') + '</a></div>' +
            (hasGame
              ? '<div class="facts"><div><span class="muted">Level</span><b>' + (p.level != null ? Number(p.level).toFixed(1) : '–') + '</b></div>' +
                '<div><span class="muted">Side</span><b>' + esc(SIDE[p.side] || '–') + '</b></div>' +
                '<div><span class="muted">Hand</span><b>' + esc(HAND[p.hand] || '–') + '</b></div>' +
                '<div><span class="muted">Working on</span><b>' + esc((p.working_on || []).slice(0, 2).join(', ') || '–') + '</b></div></div>'
              : '<p class="muted">Tell us your level, side and what you want to work on, and we will recommend coaches who suit how you play.</p><a class="btn sm acc" href="#/profile" style="align-self:flex-start">Add your game</a>') +
            '</div></div>';
        } else if (!me) {
          hero = '<div class="panel welcome" style="position:relative;overflow:hidden;display:flex;flex-direction:column;gap:18px">' + I.court +
            '<div style="position:relative"><div class="slogan">Padel plus talent</div><h1 style="margin-top:8px">Online padel lessons from <span style="color:var(--acc)">real coaches</span></h1>' +
            '<p style="margin-top:10px;color:#D5DEE6;max-width:560px">Send a clip of your game. Your coach sends back a personal video lesson.</p></div>' +
            '<div style="position:relative;display:flex;gap:10px;flex-wrap:wrap"><a class="btn acc" href="#/signup">Get started</a><a class="btn" href="#/signup?role=coach">I am a coach</a></div></div>';
        }
      }
      var head = onlyList ? '<div><h1>Coaches</h1><p class="muted" style="margin-top:6px">Every coach is checked by Padelent before they go live.</p></div>' : '';
      render(shell(active, head + hero +
        '<div class="chips scroll" id="chips">' + chips.map(function (c) { return '<button class="chip' + (c === 'All' ? ' on' : '') + '" data-f="' + esc(c) + '">' + esc(c) + '</button>'; }).join('') + '</div>' +
        '<div id="rows" style="display:flex;flex-direction:column;gap:44px"></div>' +
        (!onlyList ? '<section class="band"><div><h2>How a lesson works</h2><p style="margin-top:6px;font-weight:500">No booking times. Your coach replies when they are off court.</p></div>' +
          '<div class="steps"><span><i class="n">1</i>Upload your clip</span><span><i class="n">2</i>Coach reviews it</span><span><i class="n">3</i>Get your video lesson</span></div></section>' : '')));
      function draw() {
        var rows = $('#rows');
        var list = filterCoaches(cards, filter);
        var rec = list.slice().sort(function (a, b) { return scoreFor(b, p) - scoreFor(a, p); });
        if (!cards.length) {
          rows.innerHTML = '<div class="panel empty"><h2>Coaches are joining now</h2><p class="muted">We are checking our first coaches. Check back very soon.</p></div>';
          return;
        }
        if (!list.length) { rows.innerHTML = '<div class="empty"><p class="muted">No coaches match that yet.</p></div>'; return; }
        if (filter !== 'All' || onlyList || cards.length < 8) {
          var title = filter !== 'All' ? filter : (p && !onlyList ? 'Recommended for you' : (onlyList ? 'All coaches' : 'Our coaches'));
          rows.innerHTML = '<section class="section"><h2>' + esc(title) + '</h2><div class="grid4">' + rec.map(coachCard).join('') + '</div></section>';
          return;
        }
        var DAY = 86400000, now = Date.now();
        var popular = list.slice().sort(function (a, b) { return (b.lessons_done - a.lessons_done) || (b.avg_rating - a.avg_rating); });
        var rising = list.filter(function (c) { return c.review_count > 0 && now - new Date(c.created_at) < 120 * DAY; })
          .sort(function (a, b) { return b.avg_rating - a.avg_rating; });
        var fresh = list.slice().sort(function (a, b) { return new Date(b.created_at) - new Date(a.created_at); }).slice(0, 12);
        function row(title, sub, arr) {
          if (!arr.length) return '';
          return '<section class="section"><div class="sec-head"><div><h2>' + title + '</h2>' + (sub ? '<p class="muted" style="margin-top:4px">' + sub + '</p>' : '') + '</div>' +
            '<a class="link" href="#/coaches">View all</a></div><div class="rowscroll">' + arr.slice(0, 12).map(coachCard).join('') + '</div></section>';
        }
        rows.innerHTML = (p ? row('Recommended for you', 'Coaches who suit how you play', rec) : '') +
          row('Popular coaches', '', popular) + row('Rising stars', 'New coaches already getting great reviews', rising) + row('New coaches', '', fresh);
      }
      $$('#chips .chip').forEach(function (b) {
        b.onclick = function () {
          filter = b.getAttribute('data-f');
          $$('#chips .chip').forEach(function (x) { x.classList.toggle('on', x === b); });
          draw();
        };
      });
      draw();
    }).catch(function (e) { if (t === navToken) failed(active, e); });
  }

  function pageCoach(id) {
    var t = ++navToken;
    loading('coaches');
    Promise.all([
      rest('coach_cards?select=*&id=eq.' + encodeURIComponent(id)),
      rest('reviews?select=rating,tags,comment,display_name,topic,created_at&coach_id=eq.' + encodeURIComponent(id) + '&order=created_at.desc&limit=40')
    ]).then(function (r) {
      if (t !== navToken) return;
      var c = r[0] && r[0][0], reviews = r[1] || [], preview = false;
      if (!c && me && me.id === id && me.coach) {
        preview = true;
        c = Object.assign({}, me.coach, { full_name: me.full_name, avg_rating: 0, review_count: 0, lessons_done: 0 });
      }
      if (!c) { render(shell('coaches', '<div class="empty"><h2>Coach not found</h2><a class="btn acc" href="#/coaches">See all coaches</a></div>')); return; }
      var fn = firstName(c.full_name) || 'this coach';
      var isMe = me && me.id === id;
      var bookHref = !me ? '#/signup?next=' + encodeURIComponent('#/book/' + id) : '#/book/' + id;
      var canBook = !preview && (!me || me.role === 'player');
      var facts = [['Racket', c.racket], ['Plays with', HAND[c.hand]], ['Court side', SIDE[c.side]], ['Playing level', c.playing_level],
        ['Coaching for', c.years_coaching != null && c.years_coaching !== '' ? c.years_coaching + ' year' + (c.years_coaching == 1 ? '' : 's') : ''],
        ['Qualifications', c.qualifications], ['Languages', c.languages]]
        .filter(function (f) { return f[1]; });
      var pin = '<svg aria-hidden="true" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 21s-7-6.2-7-11.5A7 7 0 0119 9.5C19 14.8 12 21 12 21z"/><circle cx="12" cy="9.5" r="2.5"/></svg>';
      var tickList = '<svg aria-hidden="true" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#D7F23A" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>';
      var avatarIn = c.photo_url ? '<img src="' + esc(c.photo_url) + '" alt="">' : '<span>' + esc(initials(c.full_name)) + '</span>';
      var shown = 5;

      var hero = '<section class="cphero" style="background:' + grad(c.id) + '">' +
        (c.photo_url ? '<img class="cover" src="' + esc(c.photo_url) + '" alt="">' : I.court) +
        '<div class="shade"></div>' +
        '<a class="round-btn" href="#/coaches" aria-label="Back to coaches">' +
          '<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M19 12H5M11 6l-6 6 6 6"/></svg></a>' +
        '<div class="in">' +
          '<div class="bigav" style="background:' + grad(c.id) + '">' + avatarIn + '</div>' +
          '<div class="nm"><h1>' + esc(c.full_name) + '</h1>' + I.tick.replace('width="18" height="18"', 'width="24" height="24"') + '</div>' +
          (c.club ? '<div class="club">' + esc(c.club) + '</div>' : '') +
          (c.city ? '<div class="loc">' + pin + esc(c.city) + '</div>' : '') +
          (c.headline ? '<div class="hl">' + esc(c.headline) + '</div>' : '') +
        '</div></section>';

      var stats = '<div class="cpstats">' +
        '<div><b>' + (c.review_count ? fmtRating(c.avg_rating) + ' ' + I.star(true, 20) : 'New') + '</b><span>' + (c.review_count ? c.review_count + ' rating' + (c.review_count === 1 ? '' : 's') : 'No ratings yet') + '</span></div>' +
        '<div><b>' + money(c.price_pence) + '</b><span>Per lesson</span></div>' +
        '<div><b>' + (c.lessons_done || 0) + '</b><span>Lesson' + (c.lessons_done === 1 ? '' : 's') + '</span></div></div>';

      var about = (c.intro_video_url || c.bio) ? '<section class="cpsec"><div class="lab">About</div>' +
        (c.intro_video_url ? '<div class="media16"><video controls playsinline preload="metadata" src="' + esc(c.intro_video_url) + '#t=0.1"' + (c.photo_url ? ' poster="' + esc(c.photo_url) + '"' : '') + '></video></div>' : '') +
        (c.bio ? '<p class="bio" id="bio">' + esc(c.bio) + '</p><button class="link more" id="more" hidden>Read more</button>' : '') + '</section>' : '';

      var specs = (c.specialities || []).length ? '<section class="cpsec"><div class="lab">Specialities</div><ul class="ticks">' +
        c.specialities.map(function (x) { return '<li>' + tickList + esc(x) + '</li>'; }).join('') + '</ul></section>' : '';

      var playing = facts.length ? '<section class="cpsec"><div class="lab">Playing profile</div><div>' +
        facts.map(function (f) { return '<div class="kv"><span class="muted">' + f[0] + '</span><b>' + esc(f[1]) + '</b></div>'; }).join('') + '</div></section>' : '';


      function reviewHtml(rv) {
        return '<div class="rv"><div class="rv-top"><span class="avatar">' + esc(initials(rv.display_name)) + '</span>' +
          '<div style="flex:1;min-width:0"><b>' + esc(rv.display_name) + '</b><div class="muted small">' + shortDate(rv.created_at) + (rv.topic ? ' · ' + esc(rv.topic) : '') + '</div></div>' +
          '<span class="rate">' + rv.rating.toFixed(1) + ' ' + I.star(true, 16).replace(/#D7F23A/g, '#F5B301') + '</span></div>' +
          (rv.comment ? '<p>' + esc(rv.comment) + '</p>' : '') +
          ((rv.tags || []).length ? '<div class="chips">' + rv.tags.map(function (x) { return '<span class="chip" style="min-height:30px;font-size:13px">' + esc(x) + '</span>'; }).join('') + '</div>' : '') + '</div>';
      }
      var revs = '<section class="cpsec"><div class="lab">Most recent reviews</div>' + (reviews.length
        ? '<div id="revs">' + reviews.slice(0, shown).map(reviewHtml).join('') + '</div>' + (reviews.length > shown ? '<button class="btn sm" id="allrevs" style="align-self:flex-start">Show all ' + reviews.length + ' reviews</button>' : '')
        : '<p class="muted">No reviews yet. Be the first to book a lesson with ' + esc(fn) + '.</p>') + '</section>';

      var bar = canBook
        ? '<div class="cpbar"><div class="price"><b>' + money(c.price_pence) + '</b><span>per lesson</span></div><a class="btn acc big" href="' + bookHref + '">Book a lesson</a></div>'
        : (isMe ? '<div class="cpbar"><div class="price"><b>Your profile</b><span>' + (preview ? 'Only you can see it until approved' : 'This is what players see') + '</span></div><a class="btn acc" href="#/profile">Edit profile</a></div>' : '');

      render(shell('coaches',
        (preview ? '<div class="notice warn">' + I.info + '<span>Preview. Your profile is not public yet. We will approve it once it is complete.</span></div>' : '') +
        '<div class="cpwrap">' + hero + stats + about + specs + playing + revs + '</div>' + (bar ? bar + '<div style="height:70px"></div>' : ''), { narrow: true }));

      var bio = $('#bio'), more = $('#more');
      if (bio && more && bio.scrollHeight > bio.clientHeight + 4) {
        more.hidden = false;
        more.onclick = function () { var open = bio.classList.toggle('open'); more.textContent = open ? 'Show less' : 'Read more'; };
      }
      if ($('#allrevs')) $('#allrevs').onclick = function () { $('#revs').innerHTML = reviews.map(reviewHtml).join(''); this.remove(); };
    }).catch(function (e) { if (t === navToken) failed('coaches', e); });
  }

  /* ================================================================ booking */

  function pageBook(id) {
    if (!needPlayer()) return;
    if (me.role !== 'player') { render(shell('home', '<div class="empty"><h2>Coach accounts cannot book lessons</h2><p class="muted">Make a separate player account to try it as a player.</p></div>')); return; }
    var t = ++navToken;
    loading('coaches');
    rest('coach_cards?select=*&id=eq.' + encodeURIComponent(id)).then(function (r) {
      if (t !== navToken) return;
      var c = r && r[0];
      if (!c) { render(shell('coaches', '<div class="empty"><h2>This coach is not taking lessons right now</h2><a class="btn acc" href="#/coaches">See all coaches</a></div>')); return; }
      var fn = firstName(c.full_name);
      var p = me.player || {};
      var gameMissing = p.level == null || !p.side;
      render(shell('coaches',
        '<a class="back" href="#/coach/' + c.id + '">‹ ' + esc(c.full_name) + '</a>' +
        '<div><h1>Your lesson with ' + esc(fn) + '</h1><p class="muted" style="margin-top:6px">Send a clip of your game and tell ' + esc(fn) + ' what you want help with.</p></div>' +
        (gameMissing ? '<div class="notice warn">' + I.info + '<span>Add your level and court side so ' + esc(fn) + ' can coach your game. <a href="#/profile">Add your game</a></span></div>' : '') +
        '<form class="form" id="f" novalidate>' +
        '<label class="f">What do you want help with?<input class="in" name="topic" maxlength="140" placeholder="e.g. My bandeja keeps landing short" required></label>' +
        '<div class="chips" id="quick">' + WORK_ON.slice(0, 8).map(function (w) { return '<button type="button" class="chip">' + esc(w) + '</button>'; }).join('') + '</div>' +
        '<label class="f">Message to ' + esc(fn) + ' <span class="hint">What happens in the clip, what you have tried, how it feels</span><textarea class="in" name="body" maxlength="5000" rows="5"></textarea></label>' +
        '<div class="f" style="display:flex;flex-direction:column;gap:10px;font-weight:700">Your videos <span class="hint">Up to 3 clips, ' + MAX_MB + 'MB each. Film at 1080p, not 4K. Side on or from behind works best.</span>' +
        '<div class="files" id="files"></div>' +
        '<button type="button" class="btn" id="add" style="align-self:flex-start">+ Add video</button>' +
        '<input type="file" id="pick" accept="video/*" multiple hidden></div>' +
        '<div class="panel" style="display:flex;flex-direction:column;gap:6px"><div style="display:flex;justify-content:space-between;font-weight:700;font-size:18px"><span>Video lesson with ' + esc(fn) + '</span><span>' + money(c.price_pence) + '</span></div>' +
        (C.paymentsEnabled ? '<p class="muted small">You pay securely by card on the next step.</p>' : '<p class="small" style="color:var(--acc);font-weight:700">Test mode: card payments are not switched on yet, so this lesson is free.</p>') + '</div>' +
        '<p class="err" id="e" hidden></p>' +
        '<button class="btn acc big block" type="submit" id="send">Send to ' + esc(fn) + '</button></form>', { narrow: true }));
      var picker = pickVideos($('#files'), [], 3);
      $('#add').onclick = function () { $('#pick').click(); };
      $('#pick').onchange = function (ev) { picker.add(ev.target.files); ev.target.value = ''; };
      $$('#quick .chip').forEach(function (b) { b.onclick = function () { var i = $('#f').topic; if (!i.value.trim()) i.value = b.textContent + ': '; else i.value = b.textContent + ': ' + i.value.replace(/^[^:]+:\s*/, ''); i.focus(); }; });
      $('#f').onsubmit = function (ev) {
        ev.preventDefault();
        var f = ev.target, e = $('#e'), b = $('#send');
        e.hidden = true;
        var topic = f.topic.value.trim();
        if (!topic) { e.textContent = 'Tell ' + fn + ' what you want help with.'; e.hidden = false; f.topic.focus(); return; }
        if (!picker.files.length) { e.textContent = 'Add at least one video of your game.'; e.hidden = false; return; }
        b.disabled = true; b.textContent = 'Uploading videos…'; $('#add').disabled = true;
        picker.uploadAll().then(function (paths) {
          b.textContent = 'Sending…';
          return rpc('book_lesson', { p_coach: c.id, p_topic: topic, p_body: f.body.value, p_videos: paths });
        }).then(function () {
          toast('Sent to ' + fn + '. You will see the reply in My lessons.');
          go('#/space/' + c.id);
        }).catch(function (err) {
          e.textContent = err.message; e.hidden = false; b.disabled = false; b.textContent = 'Send to ' + fn; $('#add').disabled = false;
        });
      };
    }).catch(function (e) { if (t === navToken) failed('coaches', e); });
  }

  /* ================================================================ lessons lists */

  function pageLessons() {
    if (!needPlayer()) return;
    return me.role === 'coach' ? coachFeed() : playerLessons();
  }

  function coachFeed() {
    var t = ++navToken;
    loading('lessons');
    rpc('coach_feed').then(function (feed) {
      if (t !== navToken) return;
      feed = feed || [];
      feed.sort(function (a, b) { return (b.needs_coach ? 1 : 0) - (a.needs_coach ? 1 : 0); });
      state.newCount = feed.filter(function (l) { return l.status === 'new' || l.needs_coach; }).length;
      var now = new Date(), m0 = new Date(now.getFullYear(), now.getMonth(), 1);
      var doneMonth = feed.filter(function (l) { return l.status === 'done' && new Date(l.created_at) >= m0; });
      var earned = doneMonth.reduce(function (s, l) { return s + l.price_pence - l.platform_fee_pence; }, 0);
      var n = { all: feed.length, 'new': 0, awaiting: 0, done: 0 };
      function tabOf(l) { return l.needs_coach ? 'new' : l.status; }
      feed.forEach(function (l) { n[tabOf(l)] = (n[tabOf(l)] || 0) + 1; });
      var tab = store.get('padelent.feedtab') || 'all';
      var c = me.coach || {};
      render(shell('lessons',
        (!c.approved ? approvalNotice() : '') +
        '<div><h1>Lessons</h1><p class="muted" style="margin-top:6px">Newest first. Tap a player to open your lessons with them.</p></div>' +
        '<div class="stats"><div class="stat"><div class="muted small">New lessons</div><div class="v">' + n['new'] + '</div></div>' +
        '<div class="stat"><div class="muted small">Awaiting your reply</div><div class="v">' + n.awaiting + '</div></div>' +
        '<div class="stat"><div class="muted small">Done this month</div><div class="v">' + doneMonth.length + '</div></div>' +
        '<div class="stat"><div class="muted small">Earned this month</div><div class="v">' + money(earned) + '</div></div></div>' +
        '<div class="tabs" role="tablist">' + [['all', 'All'], ['new', 'New'], ['awaiting', 'Awaiting your reply'], ['done', 'Done']].map(function (x) {
          return '<button role="tab" data-tab="' + x[0] + '" class="' + (x[0] === tab ? 'on' : '') + '">' + x[1] + '<span class="c">' + (n[x[0]] || 0) + '</span></button>'; }).join('') + '</div>' +
        '<div id="feed"></div>'));
      function draw() {
        var list = feed.filter(function (l) { return tab === 'all' || tabOf(l) === tab; });
        $('#feed').innerHTML = list.length ? '<div class="list">' + list.map(function (l) {
          var game = [l.level != null ? 'Level ' + Number(l.level).toFixed(1) : '', SIDE[l.side] ? SIDE[l.side].replace(/ \(.*\)/, '') : '', HAND[l.hand] || ''].filter(Boolean).join(' · ');
          return '<a class="lrow' + (l.status === 'new' || l.needs_coach ? ' new' : '') + '" href="#/space/' + l.player_id + '">' +
            '<span class="avatar">' + esc(initials(l.player_name)) + '</span>' +
            '<span class="main"><span style="display:flex;gap:10px;align-items:baseline;flex-wrap:wrap"><b style="font-size:17px">' + esc(l.player_name) + '</b><span class="muted small">' + esc(game) + '</span></span>' +
            '<span class="t" style="' + (l.status === 'new' ? 'font-weight:700' : '') + '">' + esc(l.topic) + '</span>' +
            '<span class="muted small">Lesson ' + l.nth + ' with you · ' + l.video_count + ' video' + (l.video_count == 1 ? '' : 's') + '</span></span>' +
            '<span class="side"><span class="muted small">' + when(l.created_at) + '</span>' + statusPill(l.status, 'coach', l) + '</span></a>';
        }).join('') + '</div>'
          : '<div class="panel empty"><h3>' + (feed.length ? 'Nothing here' : 'No lessons yet') + '</h3><p class="muted">' +
            (feed.length ? 'Try another tab.' : (c.approved ? 'When a player books you, their lesson appears here.' : 'Once your profile is approved, players can find and book you.')) + '</p></div>';
      }
      $$('.tabs button').forEach(function (b) {
        b.onclick = function () { tab = b.getAttribute('data-tab'); store.set('padelent.feedtab', tab); $$('.tabs button').forEach(function (x) { x.classList.toggle('on', x === b); }); draw(); };
      });
      draw();
    }).catch(function (e) { if (t === navToken) failed('lessons', e); });
  }

  function approvalNotice() {
    var c = (me && me.coach) || {};
    var todo = [];
    if (!c.photo_url) todo.push('a photo');
    if (!c.bio) todo.push('an about you');
    if (!c.club && !c.city) todo.push('your club or city');
    if (!(c.specialities || []).length) todo.push('your specialities');
    return '<div class="notice warn">' + I.info + '<span><b>Your profile is waiting for approval.</b> ' +
      (todo.length ? 'Add ' + todo.join(', ') + ' so we can approve you. <a href="#/profile">Complete your profile</a>' : 'Thanks, it is complete. We will email you when you are live.') + '</span></div>';
  }

  function playerLessons() {
    var t = ++navToken;
    loading('lessons');
    rpc('player_coaches').then(function (rows) {
      if (t !== navToken) return;
      rows = rows || [];
      render(shell('lessons', '<div><h1>My lessons</h1><p class="muted" style="margin-top:6px">Each coach has a private space with all your lessons together.</p></div>' +
        (rows.length ? '<div class="list">' + rows.map(function (r) {
          return '<a class="lrow" href="#/space/' + r.coach_id + '">' +
            '<span class="avatar">' + (r.photo_url ? '<img src="' + esc(r.photo_url) + '" alt="">' : esc(initials(r.coach_name))) + '</span>' +
            '<span class="main"><b style="font-size:17px">' + esc(r.coach_name) + '</b><span class="t">' + esc(r.last_topic) + '</span>' +
            '<span class="muted small">' + r.lesson_count + ' lesson' + (r.lesson_count == 1 ? '' : 's') + ' · ' + when(r.last_at) + '</span></span>' +
            '<span class="side">' + statusPill(r.last_status, 'player', { closed_at: r.last_closed_at }) + (r.to_review > 0 ? '<span class="small" style="color:var(--acc);font-weight:700">Leave a review</span>' : '') + '</span></a>';
        }).join('') + '</div>'
          : '<div class="panel empty"><h2>No lessons yet</h2><p class="muted">Pick a coach and send them a clip of your game.</p><a class="btn acc" href="#/coaches">Find a coach</a></div>')));
    }).catch(function (e) { if (t === navToken) failed('lessons', e); });
  }

  /* ================================================================ lesson space */

  function pageSpace(other) {
    if (!needPlayer()) return;
    var t = ++navToken;
    loading('lessons');
    rpc('get_space', { p_other: other }).then(function (sp) {
      if (t !== navToken) return;
      if (!sp) { render(shell('lessons', '<div class="empty"><h2>Not found</h2><p class="muted">You do not have any lessons here.</p><a class="btn acc" href="#/lessons">My lessons</a></div>')); return; }
      var isCoach = sp.role === 'coach';
      var lessons = sp.lessons || [];
      var opens = isCoach ? lessons.filter(function (l) { return l.status === 'new' || l.needs_coach; }) : [];
      if (opens.length) {
        opens.forEach(function (l) { if (l.status === 'new') l.status = 'awaiting'; l.needs_coach = false; });
        Promise.all(opens.map(function (l) { return rpc('open_lesson', { p_lesson: l.id }); })).then(refreshNewCount).catch(function () {});
      }
      drawSpace(sp, other);
    }).catch(function (e) { if (t === navToken) failed('lessons', e); });
  }

  function drawSpace(sp, other) {
    var isCoach = sp.role === 'coach';
    var o = sp.other || {};
    var lessons = sp.lessons || [];
    var fn = firstName(o.full_name) || (isCoach ? 'your player' : 'your coach');
    var last = lessons[lessons.length - 1];
    var active = last && !last.closed_at ? last : null;           // lesson you can still write in
    var open = active && active.status !== 'done' ? active : null;  // waiting for the coach's lesson reply
    var followup = active && active.status === 'done' ? active : null;  // done, chat still open
    var myName = me.full_name;

    var aside = '';
    if (isCoach) {
      var p = o.player || {};
      aside = '<div class="panel"><details class="game" open><summary><h3>' + esc(fn) + '’s game</h3><span class="muted small" style="display:flex;gap:5px;align-items:center">' + I.lock + 'Private</span></summary>' +
        '<div style="display:flex;align-items:center;gap:14px;margin:14px 0 6px"><span style="font-family:var(--head);font-weight:800;font-size:42px;line-height:1;color:var(--acc)">' + (p.level != null ? Number(p.level).toFixed(1) : '–') + '</span><span class="muted small" style="line-height:1.3">Level rating<br>out of 7</span></div>' +
        [['Plays with', HAND[p.hand] ? HAND[p.hand].replace('-handed', ' hand') : ''], ['Court side', SIDE[p.side]], ['Racket', p.racket], ['Home club', p.home_club], ['Playing for', p.playing_for], ['Plays', p.how_often]]
          .map(function (k) { return '<div class="kv"><span class="muted">' + k[0] + '</span><b>' + esc(k[1] || '–') + '</b></div>'; }).join('') +
        ((p.working_on || []).length ? '<div class="muted small" style="margin-top:12px">Working on</div><div class="chips" style="margin-top:6px">' + p.working_on.map(function (w) { return '<span class="chip" style="min-height:34px">' + esc(w) + '</span>'; }).join('') + '</div>' : '') +
        (p.goal ? '<div class="muted small" style="margin-top:12px">Goal</div><div style="margin-top:2px">' + esc(p.goal) + '</div>' : '') +
        '</details></div>';
    } else {
      aside = '<a class="panel" href="#/coach/' + o.id + '" style="display:flex;gap:14px;align-items:center;text-decoration:none;color:#fff">' +
        '<span class="avatar" style="width:56px;height:56px;font-size:18px;background:' + grad(o.id) + '">' + (o.photo_url ? '<img src="' + esc(o.photo_url) + '" alt="">' : esc(initials(o.full_name))) + '</span>' +
        '<span><b>' + esc(o.full_name) + '</b><br><span class="muted small">' + esc(o.club || '') + '</span><br><span class="link small" style="min-height:0">View profile</span></span></a>';
    }
    if (lessons.length > 1) {
      aside += '<div style="display:flex;flex-direction:column;gap:8px"><h3>All lessons with ' + esc(fn) + '</h3>' + lessons.slice().reverse().map(function (l) {
        var i = lessons.indexOf(l) + 1;
        return '<a href="#" data-jump="' + l.id + '" class="panel" style="padding:12px 14px;display:flex;flex-direction:column;gap:4px;text-decoration:none;color:#fff;' + (l === last ? 'border-color:var(--acc)' : '') + '">' +
          '<span style="display:flex;justify-content:space-between;gap:8px;align-items:center"><b>Lesson ' + i + '</b>' + statusPill(l.status, sp.role, l) + '</span>' +
          '<span class="small" style="color:#D5DEE6">' + esc(l.topic) + '</span><span class="muted small">' + shortDate(l.created_at) + '</span></a>';
      }).join('') + '</div>';
    }

    var thread = lessons.map(function (l, i) {
      var cur = l === last;
      var head = '<div class="divider' + (cur ? ' cur' : '') + '" id="l-' + l.id + '">Lesson ' + (i + 1) + ' · ' + esc(l.topic) + ' · ' + shortDate(l.created_at) + '</div>';
      var shownFollow = false;
      var msgs = (l.messages || []).map(function (m) {
        var sep = '';
        if (!shownFollow && l.done_at && new Date(m.created_at) > new Date(l.done_at)) {
          shownFollow = true;
          sep = '<div class="divider" style="font-size:13px">Follow-up chat</div>';
        }
        var mine = m.sender_id === me.id;
        var fromCoach = isCoach ? mine : !mine;
        var name = mine ? myName + ' (you)' : o.full_name;
        return sep + '<div class="msg' + (fromCoach ? ' coach' : '') + '"><span class="avatar' + (fromCoach ? ' acc' : '') + '">' + esc(initials(mine ? myName : o.full_name)) + '</span>' +
          '<div class="bub"><div class="who"><b>' + esc(name) + '</b><span class="muted small">' + when(m.created_at) + '</span></div>' +
          (m.body ? '<div class="body">' + esc(m.body) + '</div>' : '') + videoTags(m.videos) + '</div></div>';
      }).join('');
      var after = '';
      if (!isCoach && l.status === 'done') {
        after = l.review
          ? '<div class="small muted" style="text-align:center">You rated this lesson ' + '★'.repeat(l.review.rating) + '</div>'
          : '<div class="panel" style="display:flex;justify-content:space-between;align-items:center;gap:14px;flex-wrap:wrap;border-color:rgba(215,242,58,.5)"><div><b>How was your lesson?</b><div class="muted small">Your review helps other players find great coaches.</div></div><a class="btn acc" href="#/review/' + o.id + '/' + l.id + '">Leave a review</a></div>';
      }
      if (!isCoach && l.status !== 'done') {
        after = '<div class="small muted" style="text-align:center">' + (l.status === 'new' ? esc(fn) + ' has your lesson and will reply in their own time.' : esc(fn) + ' is working on your lesson.') + '</div>';
      }
      if (l.closed_at) after += '<div class="small muted" style="text-align:center">Lesson closed by ' + esc(isCoach ? 'you' : fn) + ' · ' + shortDate(l.closed_at) + '</div>';
      return head + msgs + after;
    }).join('');

    var composer = '';
    if (isCoach && open) {
      composer = '<form class="panel composer" id="cf"><h3>Reply to ' + esc(fn) + '</h3>' +
        '<textarea class="in" name="body" rows="5" maxlength="5000" placeholder="Write your tips and drills…"></textarea>' +
        '<div class="files" id="files"></div>' +
        '<div class="acts"><button type="button" class="btn acc" id="rec"><span style="width:10px;height:10px;border-radius:50%;background:#E5484D;display:inline-block"></span>Record video reply</button>' +
        '<button type="button" class="btn" id="add">Upload a video</button>' +
        '<input type="file" id="pick" accept="video/*" multiple hidden><input type="file" id="cam" accept="video/*" capture="user" hidden></div>' +
        '<p class="err" id="e" hidden></p>' +
        '<div class="acts" style="justify-content:flex-end"><button type="submit" class="btn" data-done="0">Send, keep open</button><button type="submit" class="btn white" data-done="1">Send and mark done</button></div>' +
        '<p class="muted small">Tip: to draw on ' + esc(fn) + '’s clip, screen-record it on your phone while you talk and mark it up, then upload the recording.</p></form>';
    } else if (isCoach && followup) {
      composer = '<form class="panel composer" id="cf"><h3>Message ' + esc(fn) + '</h3>' +
        '<p class="muted small">The lesson is done, but you can keep chatting about how ' + esc(fn) + ' is getting on. Close the lesson when you are finished.</p>' +
        '<textarea class="in" name="body" rows="3" maxlength="5000" placeholder="Message to ' + esc(fn) + '"></textarea>' +
        '<div class="files" id="files"></div>' +
        '<div class="acts"><button type="button" class="btn" id="add">+ Add video</button><input type="file" id="pick" accept="video/*" multiple hidden>' +
        '<span style="flex:1"></span><button type="button" class="btn" id="close">Close lesson</button><button type="submit" class="btn acc" data-done="0">Send</button></div><p class="err" id="e" hidden></p></form>';
    } else if (isCoach) {
      composer = '<div class="panel muted" style="text-align:center">All lessons with ' + esc(fn) + ' are closed. When they book again, it appears here and in your Lessons.</div>';
    } else if (followup) {
      composer = '<form class="panel composer" id="cf"><h3>How are you getting on?</h3>' +
        '<p class="muted small">Tell ' + esc(fn) + ' how the drills are going or ask a quick question. You can chat here until ' + esc(fn) + ' closes the lesson.</p>' +
        '<textarea class="in" name="body" rows="3" maxlength="5000" placeholder="Message to ' + esc(fn) + '"></textarea>' +
        '<div class="files" id="files"></div>' +
        '<div class="acts"><button type="button" class="btn" id="add">+ Add video</button><input type="file" id="pick" accept="video/*" multiple hidden>' +
        '<span style="flex:1"></span><button type="submit" class="btn acc" data-done="0">Send</button></div><p class="err" id="e" hidden></p></form>' +
        '<div class="panel" style="display:flex;justify-content:space-between;align-items:center;gap:14px;flex-wrap:wrap"><div><b>Want a full new lesson?</b><div class="muted small">' + money(o.price_pence) + ' per lesson. It goes into this same space.</div></div><a class="btn" href="#/book/' + o.id + '">Book another lesson</a></div>';
    } else if (open) {
      composer = '<form class="panel composer" id="cf"><h3>Add to this lesson</h3><p class="muted small">Forgot something? Send ' + esc(fn) + ' another message or clip.</p>' +
        '<textarea class="in" name="body" rows="3" maxlength="5000" placeholder="Message to ' + esc(fn) + '"></textarea>' +
        '<div class="files" id="files"></div>' +
        '<div class="acts"><button type="button" class="btn" id="add">+ Add video</button><input type="file" id="pick" accept="video/*" multiple hidden>' +
        '<span style="flex:1"></span><button type="submit" class="btn acc" data-done="0">Send</button></div><p class="err" id="e" hidden></p></form>';
    } else {
      composer = '<div class="panel" style="display:flex;justify-content:space-between;align-items:center;gap:14px;flex-wrap:wrap"><div><b>Ready for your next lesson?</b><div class="muted small">' + money(o.price_pence) + ' per lesson. It goes into this same space.</div></div><a class="btn acc" href="#/book/' + o.id + '">Book another lesson</a></div>';
    }

    render(shell('lessons',
      '<a class="back" href="#/lessons">‹ ' + (isCoach ? 'All lessons' : 'My lessons') + '</a>' +
      '<div style="display:flex;align-items:center;gap:16px;flex-wrap:wrap"><span class="avatar" style="width:60px;height:60px;font-size:20px;' + (!isCoach ? 'background:' + grad(o.id) : '') + '">' + (!isCoach && o.photo_url ? '<img src="' + esc(o.photo_url) + '" alt="">' : esc(initials(o.full_name))) + '</span>' +
      '<div style="flex:1;min-width:200px"><h1 style="font-size:clamp(26px,4vw,38px)">' + esc(o.full_name) + '</h1><div class="muted">' + lessons.length + ' lesson' + (lessons.length === 1 ? '' : 's') + ' together · Only you and ' + esc(fn) + ' can see this space</div></div>' +
      (!isCoach && !open && lessons.length ? '' : '') + '</div>' +
      '<div class="space"><aside>' + aside + '</aside><section class="thread">' + thread + composer + '</section></div>'));

    hydrateVideos($('#main'));
    $$('[data-jump]').forEach(function (a) { a.onclick = function (ev) { ev.preventDefault(); var el = document.getElementById('l-' + a.getAttribute('data-jump')); if (el) el.scrollIntoView({ behavior: 'smooth', block: 'start' }); }; });
    if (lessons.length > 1 && last) { var el = document.getElementById('l-' + last.id); if (el) setTimeout(function () { el.scrollIntoView({ block: 'start' }); window.scrollBy(0, -90); }, 50); }
    if (window.matchMedia('(max-width: 900px)').matches) { var d = $('details.game'); if (d) d.open = false; }

    var form = $('#cf');
    if (!form) return;
    var picker = pickVideos($('#files'), [], 3);
    $('#add').onclick = function () { $('#pick').click(); };
    $('#pick').onchange = function (ev) { picker.add(ev.target.files); ev.target.value = ''; };
    if ($('#rec')) { $('#rec').onclick = function () { $('#cam').click(); }; $('#cam').onchange = function (ev) { picker.add(ev.target.files); ev.target.value = ''; }; }
    if ($('#close')) $('#close').onclick = function () {
      if (!confirm('Close this lesson? ' + fn + ' will not be able to send more messages until they book again.')) return;
      this.disabled = true;
      rpc('close_lesson', { p_lesson: active.id }).then(function () { toast('Lesson closed'); refreshNewCount(); pageSpace(other); })
        .catch(function (err) { toast(err.message, true); });
    };
    var doneFlag = false;
    $$('button[type=submit]', form).forEach(function (b) { b.onclick = function () { doneFlag = b.getAttribute('data-done') === '1'; }; });
    form.onsubmit = function (ev) {
      ev.preventDefault();
      var e = $('#e'), body = form.body.value.trim();
      e.hidden = true;
      if (!body && !picker.files.length) { e.textContent = 'Write a message or add a video.'; e.hidden = false; return; }
      if (isCoach && doneFlag && !picker.files.length && !confirm('Mark this lesson done without a video reply?')) return;
      var btns = $$('button', form); btns.forEach(function (b) { b.disabled = true; });
      picker.uploadAll().then(function (paths) {
        return rpc('send_message', { p_lesson: active.id, p_body: body, p_videos: paths, p_mark_done: !!(isCoach && doneFlag && open) });
      }).then(function () {
        toast(isCoach && doneFlag ? 'Sent. ' + fn + ' has been told the lesson is ready.' : 'Sent');
        refreshNewCount();
        pageSpace(other);
      }).catch(function (err) { e.textContent = err.message; e.hidden = false; btns.forEach(function (b) { b.disabled = false; }); });
    };
  }

  /* ================================================================ review */

  function pageReview(coachId, lessonId) {
    if (!needPlayer()) return;
    var t = ++navToken;
    loading('lessons');
    rpc('get_space', { p_other: coachId }).then(function (sp) {
      if (t !== navToken) return;
      var l = sp && (sp.lessons || []).filter(function (x) { return x.id === lessonId; })[0];
      if (!l || sp.role !== 'player') { render(shell('lessons', '<div class="empty"><h2>Lesson not found</h2><a class="btn acc" href="#/lessons">My lessons</a></div>')); return; }
      var o = sp.other, fn = firstName(o.full_name);
      var idx = sp.lessons.indexOf(l) + 1;
      var rating = l.review ? l.review.rating : 0, tags = [];
      render(shell('lessons',
        '<a class="back" href="#/space/' + coachId + '">‹ Back to lesson</a>' +
        '<div class="panel" style="display:flex;gap:16px;align-items:center"><span class="avatar" style="width:64px;height:64px;font-size:20px;border-radius:14px;background:' + grad(o.id) + '">' + (o.photo_url ? '<img src="' + esc(o.photo_url) + '" alt="">' : esc(initials(o.full_name))) + '</span>' +
        '<div><div class="slogan" style="font-size:12px">Lesson ' + idx + ' · ' + (l.status === 'done' ? 'Done' : 'Not finished') + '</div><h3 style="font-size:21px;margin-top:2px">' + esc(o.full_name) + ' replied to your lesson</h3><div class="muted small">' + esc(l.topic) + '</div></div></div>' +
        (l.status !== 'done' ? '<div class="notice warn">' + I.info + '<span>You can review once ' + esc(fn) + ' has replied.</span></div>' :
        '<form class="form" id="f"><div style="text-align:center;display:flex;flex-direction:column;align-items:center;gap:6px"><h1>How was your lesson?</h1><p class="muted">Tap a star to rate ' + esc(fn) + '</p>' +
        '<div class="stars" role="radiogroup" aria-label="Star rating">' + [1, 2, 3, 4, 5].map(function (i) { return '<button type="button" role="radio" aria-label="' + i + ' star' + (i > 1 ? 's' : '') + '" data-s="' + i + '"></button>'; }).join('') + '</div>' +
        '<div id="word" style="font-family:var(--head);font-weight:800;font-size:20px;color:var(--acc);min-height:28px"></div></div>' +
        '<div class="f" style="display:flex;flex-direction:column;gap:10px;font-weight:700">What stood out? <span class="hint">Optional</span><div class="chips" id="tags">' + REVIEW_TAGS.map(function (x) { return '<button type="button" class="chip">' + esc(x) + '</button>'; }).join('') + '</div></div>' +
        '<label class="f">Add a comment <span class="hint">Optional</span><textarea class="in" name="comment" maxlength="500" rows="4">' + esc(l.review ? l.review.comment : '') + '</textarea>' +
        '<span class="hint" style="display:flex;justify-content:space-between"><span>Shown on ' + esc(fn) + '’s profile with your first name and initial</span><span id="cnt">0 / 500</span></span></label>' +
        '<p class="err" id="e" hidden></p><button class="btn acc big block" type="submit">Post review</button>' +
        '<a class="link" href="#/space/' + coachId + '" style="align-self:center">Not now</a></form>'), { narrow: true }));
      if (l.status !== 'done') return;
      function drawStars() {
        $$('.stars button').forEach(function (b) { var s = +b.getAttribute('data-s'); b.innerHTML = I.star(s <= rating, 52); b.setAttribute('aria-checked', s === rating); });
        $('#word').textContent = STAR_WORDS[rating] || '';
      }
      $$('.stars button').forEach(function (b) { b.onclick = function () { rating = +b.getAttribute('data-s'); drawStars(); }; });
      $$('#tags .chip').forEach(function (b) { b.onclick = function () { b.classList.toggle('on'); }; });
      var ta = $('#f').comment; function cnt() { $('#cnt').textContent = ta.value.length + ' / 500'; } ta.oninput = cnt; cnt();
      drawStars();
      $('#f').onsubmit = function (ev) {
        ev.preventDefault();
        var e = $('#e');
        if (!rating) { e.textContent = 'Tap a star to rate your lesson.'; e.hidden = false; return; }
        tags = $$('#tags .chip.on').map(function (b) { return b.textContent; });
        var b = $('button[type=submit]'); b.disabled = true;
        rpc('post_review', { p_lesson: l.id, p_rating: rating, p_tags: tags, p_comment: ta.value.trim() })
          .then(function () { toast('Thanks! Your review is live on ' + fn + '’s profile.'); go('#/space/' + coachId); })
          .catch(function (err) { e.textContent = err.message; e.hidden = false; b.disabled = false; });
      };
    }).catch(function (e) { if (t === navToken) failed('lessons', e); });
  }

  /* ================================================================ profiles */

  function pageProfile() {
    if (!needPlayer()) return;
    ++navToken;
    loadMe().then(function () { if (me) (me.role === 'coach' ? coachProfileForm : playerProfileForm)(); })
      .catch(function (e) { failed('profile', e); });
  }

  function segBtns(name, opts, val) {
    return '<div class="chips" data-seg="' + name + '">' + opts.map(function (o) {
      return '<button type="button" class="chip' + (o[0] === val ? ' on' : '') + '" data-v="' + esc(o[0]) + '">' + esc(o[1]) + '</button>'; }).join('') + '</div>';
  }
  function multiBtns(name, opts, vals) {
    vals = (vals || []).map(function (v) { return String(v).toLowerCase(); });
    return '<div class="chips" data-multi="' + name + '">' + opts.map(function (o) {
      return '<button type="button" class="chip' + (vals.indexOf(o.toLowerCase()) >= 0 ? ' on' : '') + '">' + esc(o) + '</button>'; }).join('') + '</div>';
  }
  function wireChips(root) {
    $$('[data-seg]', root).forEach(function (g) {
      $$('.chip', g).forEach(function (b) { b.onclick = function () { var on = !b.classList.contains('on'); $$('.chip', g).forEach(function (x) { x.classList.remove('on'); }); if (on) b.classList.add('on'); }; });
    });
    $$('[data-multi] .chip', root).forEach(function (b) { b.onclick = function () { b.classList.toggle('on'); }; });
  }
  function segVal(name) { var b = $('[data-seg="' + name + '"] .chip.on'); return b ? b.getAttribute('data-v') : ''; }
  function multiVal(name) { return $$('[data-multi="' + name + '"] .chip.on').map(function (b) { return b.textContent; }); }
  function logoutBtn() {
    return '<div class="panel" style="display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap"><div><b>' + esc(me.full_name) + '</b><div class="muted small">' + esc((session && session.user && session.user.email) || '') + '</div></div>' +
      '<div style="display:flex;gap:10px;flex-wrap:wrap"><a class="btn sm" href="mailto:' + esc(C.contactEmail) + '">Help</a><button class="btn sm" id="logout">Log out</button></div></div>';
  }
  function wireLogout() {
    var b = $('#logout'); if (!b) return;
    b.onclick = function () {
      var tok = session && session.access_token;
      if (tok) raw('POST', '/auth/v1/logout', {}, true).catch(function () {});
      saveSession(null); me = null; state.newCount = 0; go('#/login');
    };
  }

  function playerProfileForm() {
    var p = me.player || {};
    var lv = p.level != null ? Number(p.level).toFixed(1) : '';
    render(shell('profile',
      '<div><h1>My padel profile</h1></div>' +
      '<div class="notice">' + I.lock + '<span>Private. Only coaches you book a lesson with can see this. It helps them coach your game, not a generic one.</span></div>' +
      '<form class="form" id="f">' +
      '<label class="f">Name<input class="in" name="full_name" maxlength="80" value="' + esc(me.full_name) + '" autocomplete="name"></label>' +
      '<div class="f" style="display:flex;flex-direction:column;gap:10px;font-weight:700"><span style="display:flex;justify-content:space-between;gap:8px;flex-wrap:wrap">Level rating <span class="hint">Use your Playtomic level if you have one</span></span>' +
      '<div class="levels" data-seg="level">' + LEVELS.map(function (l) { return '<button type="button" class="chip' + (l === lv ? ' on' : '') + '" data-v="' + l + '">' + l + '</button>'; }).join('') + '</div></div>' +
      '<div class="f" style="display:flex;flex-direction:column;gap:10px;font-weight:700">Which hand do you play with?' + segBtns('hand', [['right', 'Right-handed'], ['left', 'Left-handed']], p.hand) + '</div>' +
      '<div class="f" style="display:flex;flex-direction:column;gap:10px;font-weight:700">Which side do you play?' + segBtns('side', [['drive', 'Drive (right)'], ['reves', 'Revés (left)'], ['both', 'Both']], p.side) + '</div>' +
      '<div class="row2"><label class="f">Racket<input class="in" name="racket" maxlength="80" value="' + esc(p.racket) + '" placeholder="e.g. Bullpadel Vertex 04"></label>' +
      '<label class="f">Home club<input class="in" name="home_club" maxlength="120" value="' + esc(p.home_club) + '"></label></div>' +
      '<div class="row2"><label class="f">Playing for<input class="in" name="playing_for" maxlength="60" value="' + esc(p.playing_for) + '" placeholder="e.g. 2 years"></label>' +
      '<label class="f">How often<input class="in" name="how_often" maxlength="60" value="' + esc(p.how_often) + '" placeholder="e.g. 2–3 times a week"></label></div>' +
      '<div class="f" style="display:flex;flex-direction:column;gap:10px;font-weight:700">What do you want to work on? <span class="hint">Pick as many as you like</span>' + multiBtns('working_on', WORK_ON, p.working_on) + '</div>' +
      '<label class="f">Your goal<textarea class="in" name="goal" maxlength="500" rows="3" placeholder="e.g. Move up to level 4 and win our club league">' + esc(p.goal) + '</textarea></label>' +
      '<p class="err" id="e" hidden></p><button class="btn acc big" type="submit" style="align-self:flex-end">Save profile</button></form>' + logoutBtn(), { narrow: true }));
    wireChips($('#f')); wireLogout();
    $('#f').onsubmit = function (ev) {
      ev.preventDefault();
      var f = ev.target, b = $('button[type=submit]', f), e = $('#e');
      b.disabled = true; e.hidden = true;
      rpc('save_my_profile', { p: { full_name: f.full_name.value, level: segVal('level'), hand: segVal('hand'), side: segVal('side'),
        racket: f.racket.value.trim(), home_club: f.home_club.value.trim(), playing_for: f.playing_for.value.trim(), how_often: f.how_often.value.trim(),
        working_on: multiVal('working_on'), goal: f.goal.value.trim() } })
        .then(function (p2) { me = p2; toast('Profile saved'); b.disabled = false; })
        .catch(function (err) { e.textContent = err.message; e.hidden = false; b.disabled = false; });
    };
  }

  function toJpeg(file, max) {
    return new Promise(function (resolve, reject) {
      var url = URL.createObjectURL(file), img = new Image();
      img.onload = function () {
        var s = Math.min(1, max / Math.max(img.naturalWidth, img.naturalHeight));
        var cv = document.createElement('canvas');
        cv.width = Math.round(img.naturalWidth * s); cv.height = Math.round(img.naturalHeight * s);
        cv.getContext('2d').drawImage(img, 0, 0, cv.width, cv.height);
        URL.revokeObjectURL(url);
        cv.toBlob(function (b) { b ? resolve(b) : reject(new Error('Could not read that photo.')); }, 'image/jpeg', 0.86);
      };
      img.onerror = function () { URL.revokeObjectURL(url); reject(new Error('Could not read that photo. Try a JPG or PNG.')); };
      img.src = url;
    });
  }

  function coachProfileForm() {
    var c = me.coach || {};
    render(shell('profile',
      (!c.approved ? approvalNotice() : '<div class="notice accb">' + I.lock.replace('stroke="#D7F23A"', 'stroke="#D7F23A"') + '<span><b>You are live.</b> Players can find and book you. <a href="#/coach/' + me.id + '">View your public profile</a></span></div>') +
      '<div style="display:flex;justify-content:space-between;align-items:flex-end;gap:12px;flex-wrap:wrap"><h1>My coach profile</h1><a class="btn sm" href="#/coach/' + me.id + '">' + (c.approved ? 'View public profile' : 'Preview') + '</a></div>' +
      '<form class="form" id="f">' +
      '<div class="row2"><div class="f" style="display:flex;flex-direction:column;gap:10px;font-weight:700">Photo <span class="hint">A clear, friendly photo. Square or portrait.</span>' +
      '<div style="display:flex;gap:14px;align-items:center"><div style="width:96px">' + photoBox(me.full_name, me.id, c.photo_url, '1 / 1') + '</div>' +
      '<button type="button" class="btn sm" id="photoBtn">' + (c.photo_url ? 'Change photo' : 'Add photo') + '</button><input type="file" id="photo" accept="image/*" hidden></div></div>' +
      '<div class="f" style="display:flex;flex-direction:column;gap:10px;font-weight:700">Intro video <span class="hint">Up to 60 seconds: who you are and how you coach.</span>' +
      (c.intro_video_url ? '<video controls playsinline preload="metadata" src="' + esc(c.intro_video_url) + '#t=0.1" style="border-radius:12px;max-height:160px;background:#000"></video>' : '') +
      '<div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap"><button type="button" class="btn sm" id="introBtn">' + (c.intro_video_url ? 'Replace video' : 'Add intro video') + '</button>' +
      (c.intro_video_url ? '<button type="button" class="link" id="introDel">Remove</button>' : '') + '<span class="prog" id="introProg" hidden><b></b></span></div><input type="file" id="intro" accept="video/*" hidden></div></div>' +
      '<label class="f">Full name<input class="in" name="full_name" maxlength="80" value="' + esc(me.full_name) + '"></label>' +
      '<label class="f">Headline <span class="hint">One line players see under your name</span><input class="in" name="headline" maxlength="120" value="' + esc(c.headline) + '" placeholder="e.g. Coaching left-handers and revés players"></label>' +
      '<div class="row2"><label class="f">Home club<input class="in" name="club" maxlength="120" value="' + esc(c.club) + '"></label>' +
      '<label class="f">City<input class="in" name="city" maxlength="80" value="' + esc(c.city) + '"></label></div>' +
      '<label class="f">About you<textarea class="in" name="bio" maxlength="2000" rows="6" placeholder="Your padel background and how you coach">' + esc(c.bio) + '</textarea></label>' +
      '<label class="f">Price per video lesson (£) <span class="hint">You receive ' + (100 - (C.platformFeePercent || 20)) + '%. Padelent keeps ' + (C.platformFeePercent || 20) + '%.</span><input class="in" name="price" type="number" inputmode="decimal" min="5" max="1000" step="1" value="' + (c.price_pence ? c.price_pence / 100 : 30) + '" style="max-width:200px"></label>' +
      '<p class="muted small" id="youget" style="margin-top:-12px"></p>' +
      '<div class="f" style="display:flex;flex-direction:column;gap:10px;font-weight:700">Specialities' + multiBtns('specialities', SPECIALITIES, c.specialities) + '</div>' +
      '<div class="row2"><div class="f" style="display:flex;flex-direction:column;gap:10px;font-weight:700">Plays with' + segBtns('hand', [['right', 'Right hand'], ['left', 'Left hand']], c.hand) + '</div>' +
      '<div class="f" style="display:flex;flex-direction:column;gap:10px;font-weight:700">Court side' + segBtns('side', [['drive', 'Drive'], ['reves', 'Revés'], ['both', 'Both']], c.side) + '</div></div>' +
      '<div class="row2"><label class="f">Racket<input class="in" name="racket" maxlength="80" value="' + esc(c.racket) + '"></label>' +
      '<label class="f">Years coaching<input class="in" name="years_coaching" type="number" inputmode="numeric" min="0" max="70" value="' + (c.years_coaching != null ? c.years_coaching : '') + '"></label></div>' +
      '<div class="row2"><label class="f">Playing level<input class="in" name="playing_level" maxlength="120" value="' + esc(c.playing_level) + '" placeholder="e.g. Former pro, Spanish circuit"></label>' +
      '<label class="f">Qualifications<input class="in" name="qualifications" maxlength="200" value="' + esc(c.qualifications) + '" placeholder="e.g. LTA Padel Coach Level 2"></label></div>' +
      '<label class="f">Languages<input class="in" name="languages" maxlength="120" value="' + esc(c.languages) + '" placeholder="e.g. English, Spanish"></label>' +
      '<p class="err" id="e" hidden></p><button class="btn acc big" type="submit" style="align-self:flex-end">Save profile</button></form>' + logoutBtn(), { narrow: true }));
    wireChips($('#f')); wireLogout();
    var f = $('#f');
    function youget() { var v = Math.round(parseFloat(f.price.value) * 100) || 0; $('#youget').textContent = v ? 'You receive ' + money(Math.round(v * (100 - (C.platformFeePercent || 20)) / 100)) + ' per lesson.' : ''; }
    f.price.oninput = youget; youget();
    $('#photoBtn').onclick = function () { $('#photo').click(); };
    $('#photo').onchange = function (ev) {
      var file = ev.target.files[0]; if (!file) return;
      var b = $('#photoBtn'); b.disabled = true; b.textContent = 'Uploading…';
      toJpeg(file, 900).then(function (blob) {
        return upload('coach-media', me.id + '/photo-' + Date.now() + '.jpg', blob, 'image/jpeg');
      }).then(function (path) { return rpc('save_my_profile', { p: { photo_url: publicUrl(path) } }); })
        .then(function (p2) { me = p2; toast('Photo saved'); coachProfileForm(); })
        .catch(function (err) { toast(err.message, true); b.disabled = false; b.textContent = 'Add photo'; });
    };
    $('#introBtn').onclick = function () { $('#intro').click(); };
    if ($('#introDel')) $('#introDel').onclick = function () { rpc('save_my_profile', { p: { intro_video_url: '' } }).then(function (p2) { me = p2; coachProfileForm(); }); };
    $('#intro').onchange = function (ev) {
      var file = ev.target.files[0]; if (!file) return;
      if (file.size > MAX_MB * 1048576) { toast('That video is over ' + MAX_MB + 'MB. Keep it under 60 seconds at 1080p.', true); return; }
      var b = $('#introBtn'), prog = $('#introProg'); b.disabled = true; b.textContent = 'Uploading…'; prog.hidden = false;
      upload('coach-media', me.id + '/intro-' + Date.now() + '.' + (extOf(file) || 'mp4'), file, typeOf(file), function (r) { $('b', prog).style.width = Math.round(r * 100) + '%'; })
        .then(function (path) { return rpc('save_my_profile', { p: { intro_video_url: publicUrl(path) } }); })
        .then(function (p2) { me = p2; toast('Intro video saved'); coachProfileForm(); })
        .catch(function (err) { toast(err.message, true); b.disabled = false; b.textContent = 'Add intro video'; prog.hidden = true; });
    };
    f.onsubmit = function (ev) {
      ev.preventDefault();
      var b = $('button[type=submit]', f), e = $('#e');
      var price = Math.round(parseFloat(f.price.value) * 100);
      e.hidden = true;
      if (!(price >= 500 && price <= 100000)) { e.textContent = 'Set a price between £5 and £1,000.'; e.hidden = false; return; }
      b.disabled = true;
      rpc('save_my_profile', { p: { full_name: f.full_name.value, headline: f.headline.value.trim(), club: f.club.value.trim(), city: f.city.value.trim(),
        bio: f.bio.value.trim(), price_pence: price, specialities: multiVal('specialities'), hand: segVal('hand'), side: segVal('side'),
        racket: f.racket.value.trim(), years_coaching: f.years_coaching.value, playing_level: f.playing_level.value.trim(),
        qualifications: f.qualifications.value.trim(), languages: f.languages.value.trim() } })
        .then(function (p2) { me = p2; toast('Profile saved'); coachProfileForm(); })
        .catch(function (err) { e.textContent = err.message; e.hidden = false; b.disabled = false; });
    };
  }

  /* ================================================================ coach earnings */

  function pageEarnings() {
    if (!needPlayer()) return;
    if (me.role !== 'coach') return go('#/');
    var t = ++navToken;
    loading('earnings');
    rpc('coach_feed').then(function (feed) {
      if (t !== navToken) return;
      var done = (feed || []).filter(function (l) { return l.status === 'done'; });
      var total = done.reduce(function (s, l) { return s + l.price_pence - l.platform_fee_pence; }, 0);
      var now = new Date(), m0 = new Date(now.getFullYear(), now.getMonth(), 1);
      var month = done.filter(function (l) { return new Date(l.created_at) >= m0; }).reduce(function (s, l) { return s + l.price_pence - l.platform_fee_pence; }, 0);
      render(shell('earnings', '<div><h1>Earnings</h1><p class="muted" style="margin-top:6px">What you earn from finished lessons, after Padelent’s ' + (C.platformFeePercent || 20) + '% share.</p></div>' +
        (!C.paymentsEnabled ? '<div class="notice warn">' + I.info + '<span>Card payments are not switched on yet, so lessons are free while we test. Payouts to your bank start when payments go live.</span></div>' : '') +
        '<div class="stats" style="grid-template-columns:repeat(3,1fr)"><div class="stat"><div class="muted small">This month</div><div class="v">' + money(month) + '</div></div>' +
        '<div class="stat"><div class="muted small">All time</div><div class="v">' + money(total) + '</div></div>' +
        '<div class="stat"><div class="muted small">Lessons done</div><div class="v">' + done.length + '</div></div></div>' +
        (done.length ? '<div class="panel" style="overflow-x:auto"><table class="table"><thead><tr><th>Date</th><th>Player</th><th>Lesson</th><th>Price</th><th>You earn</th></tr></thead><tbody>' +
          done.map(function (l) { return '<tr><td>' + shortDate(l.created_at) + '</td><td>' + esc(l.player_name) + '</td><td>' + esc(l.topic) + '</td><td>' + money(l.price_pence) + '</td><td><b>' + money(l.price_pence - l.platform_fee_pence) + '</b></td></tr>'; }).join('') +
          '</tbody></table></div>' : '<div class="panel empty"><p class="muted">Finished lessons will show here.</p></div>')));
    }).catch(function (e) { if (t === navToken) failed('earnings', e); });
  }

  /* ================================================================ admin */

  function pageAdmin() {
    if (!needPlayer()) return;
    if (!me.is_admin) return go('#/');
    var t = ++navToken;
    loading('admin');
    rpc('admin_overview').then(function (a) {
      if (t !== navToken) return;
      var pending = a.coaches.filter(function (c) { return !c.approved; });
      var live = a.coaches.filter(function (c) { return c.approved; });
      function coachRow(c) {
        return '<div class="admin-coach"><span class="avatar" style="width:56px;height:56px;border-radius:12px;background:' + grad(c.id) + '">' + (c.photo_url ? '<img src="' + esc(c.photo_url) + '" alt="">' : esc(initials(c.full_name))) + '</span>' +
          '<div style="flex:1;min-width:0"><b>' + esc(c.full_name || '(no name)') + '</b> <span class="muted small">' + esc(c.email) + '</span>' +
          '<div class="muted small">' + esc([c.club, c.city].filter(Boolean).join(', ') || 'No club yet') + ' · ' + money(c.price_pence) + ' · joined ' + shortDate(c.created_at) + '</div>' +
          (c.qualifications ? '<div class="small">' + esc(c.qualifications) + '</div>' : '') +
          (c.bio ? '<div class="small muted" style="margin-top:4px;max-height:4.5em;overflow:hidden">' + esc(c.bio) + '</div>' : '<div class="small" style="color:var(--amber)">No bio yet</div>') + '</div>' +
          '<button class="btn sm ' + (c.approved ? '' : 'acc') + '" data-approve="' + c.id + '" data-to="' + (!c.approved) + '">' + (c.approved ? 'Hide' : 'Approve') + '</button></div>';
      }
      render(shell('admin', '<div><h1>Admin</h1><p class="muted" style="margin-top:6px">Only you can see this page.</p></div>' +
        '<div class="stats"><div class="stat"><div class="muted small">Players</div><div class="v">' + a.players + '</div></div>' +
        '<div class="stat"><div class="muted small">Coaches live</div><div class="v">' + live.length + '</div></div>' +
        '<div class="stat"><div class="muted small">Lessons (done)</div><div class="v">' + a.lessons + ' <span class="muted small">(' + a.lessons_done + ')</span></div></div>' +
        '<div class="stat"><div class="muted small">Padelent share</div><div class="v">' + money(a.revenue_pence) + '</div></div></div>' +
        '<section class="section"><h2>Waiting for approval (' + pending.length + ')</h2><div class="panel">' + (pending.length ? pending.map(coachRow).join('') : '<p class="muted">Nobody waiting.</p>') + '</div></section>' +
        '<section class="section"><h2>Live coaches (' + live.length + ')</h2><div class="panel">' + (live.length ? live.map(coachRow).join('') : '<p class="muted">No live coaches yet.</p>') + '</div></section>'));
      $$('[data-approve]').forEach(function (b) {
        b.onclick = function () {
          b.disabled = true;
          rpc('admin_set_approved', { p_coach: b.getAttribute('data-approve'), p_approved: b.getAttribute('data-to') === 'true' })
            .then(function () { toast(b.getAttribute('data-to') === 'true' ? 'Coach approved' : 'Coach hidden'); pageAdmin(); })
            .catch(function (e) { toast(e.message, true); b.disabled = false; });
        };
      });
    }).catch(function (e) { if (t === navToken) failed('admin', e); });
  }

  /* ================================================================ router */

  function route() {
    var h = location.hash || '#/';
    var path = h.split('?')[0];
    var m;
    if (path === '#/login') return pageLogin();
    if (path === '#/signup') return pageSignup();
    if (path === '#/forgot') return pageForgot();
    if (path === '#/reset') return pageReset();
    if (path === '#/' || path === '#' || path === '') {
      if (!me) return pageHome(false);
      return go(me.role === 'coach' ? '#/lessons' : '#/home');
    }
    if (path === '#/home') return pageHome(false);
    if (path === '#/coaches') return pageHome(true);
    if ((m = /^#\/coach\/([0-9a-f-]{36})$/.exec(path))) return pageCoach(m[1]);
    if ((m = /^#\/book\/([0-9a-f-]{36})$/.exec(path))) return pageBook(m[1]);
    if ((m = /^#\/space\/([0-9a-f-]{36})$/.exec(path))) return pageSpace(m[1]);
    if ((m = /^#\/review\/([0-9a-f-]{36})\/([0-9a-f-]{36})$/.exec(path))) return pageReview(m[1], m[2]);
    if (path === '#/lessons') return pageLessons();
    if (path === '#/profile') return pageProfile();
    if (path === '#/earnings') return pageEarnings();
    if (path === '#/admin') return pageAdmin();
    go('#/');
  }

  function boot() {
    if (!SB || !KEY) { $app.innerHTML = '<div class="empty"><h2>App not configured</h2></div>'; return; }
    var h = location.hash;
    // Links from our emails (confirm account, reset password) come back with the login in the address.
    if (/access_token=/.test(h)) {
      var q = new URLSearchParams(h.slice(1));
      saveSession({ access_token: q.get('access_token'), refresh_token: q.get('refresh_token'),
        expires_at: Number(q.get('expires_at')) || Math.floor(Date.now() / 1000) + (Number(q.get('expires_in')) || 3600), user: null });
      var type = q.get('type');
      history.replaceState(null, '', location.pathname + (type === 'recovery' ? '#/reset' : (store.get('padelent.next') || '#/')));
      if (type !== 'recovery') store.del('padelent.next');
      if (type === 'signup') setTimeout(function () { toast('Email confirmed. Welcome to Padelent!'); }, 300);
    } else if (/error_description=/.test(h)) {
      var eq = new URLSearchParams(h.slice(1));
      history.replaceState(null, '', location.pathname + '#/login');
      setTimeout(function () { toast(/expired/i.test(eq.get('error_description') || '') ? 'That link has expired. Please try again.' : (eq.get('error_description') || 'That link did not work.'), true); }, 300);
    }
    loadMe().catch(function () {}).then(function () {
      if (session && session.access_token && !(session.user && session.user.email)) {
        raw('GET', '/auth/v1/user', undefined, true).then(function (u) { if (session) { session.user = u; saveSession(session); } }).catch(function () {});
      }
      window.addEventListener('hashchange', route);
      route();
      refreshNewCount();
    });
  }
  boot();
})();

// @ts-nocheck
// Padelent "send-push" Edge Function.
// Delivers phone notifications (Web Push). It has no settings or secrets of its own:
// the database sends it everything it needs for each notification.
//
// Deploy: Supabase → Edge Functions → Deploy a new function → Via Editor,
// name it send-push, paste this whole file, Deploy. Then switch OFF "Verify JWT"
// (Enforce JWT verification) in the function's settings.
// ---- Web Push (RFC 8291 aes128gcm + RFC 8292 VAPID) using only WebCrypto ----
const enc = new TextEncoder();
function b64u(buf) {
  const b = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  let s = ''; for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function unb64u(str) {
  const s = atob(str.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((str.length + 3) % 4));
  const out = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i); return out;
}
function concat(...parts) {
  const n = parts.reduce((a, p) => a + p.length, 0), out = new Uint8Array(n); let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; } return out;
}
async function hkdf(salt, ikm, info, len) {
  const key = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits']);
  return new Uint8Array(await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt, info }, key, len * 8));
}
function rawToJwk(raw, d) {
  return { kty: 'EC', crv: 'P-256', x: b64u(raw.slice(1, 33)), y: b64u(raw.slice(33, 65)), ...(d ? { d } : {}), ext: true };
}

async function generateVapidKeys() {
  const kp = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const jwk = await crypto.subtle.exportKey('jwk', kp.privateKey);
  const pub = new Uint8Array(await crypto.subtle.exportKey('raw', kp.publicKey));
  return { publicKey: b64u(pub), privateKey: jwk.d };
}

// Encrypts one payload for one subscription. `fixed` is only for test vectors.
async function encryptPayload(plaintext, p256dh, authSecret, fixed) {
  const uaPublic = unb64u(p256dh), auth = unb64u(authSecret);
  let asKeys, asPublic;
  if (fixed) {
    asPublic = unb64u(fixed.asPublic);
    asKeys = { privateKey: await crypto.subtle.importKey('jwk', rawToJwk(asPublic, fixed.asPrivate), { name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']) };
  } else {
    asKeys = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
    asPublic = new Uint8Array(await crypto.subtle.exportKey('raw', asKeys.publicKey));
  }
  const uaKey = await crypto.subtle.importKey('raw', uaPublic, { name: 'ECDH', namedCurve: 'P-256' }, false, []);
  const ecdh = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: uaKey }, asKeys.privateKey, 256));
  const ikm = await hkdf(auth, ecdh, concat(enc.encode('WebPush: info\0'), uaPublic, asPublic), 32);
  const salt = fixed ? unb64u(fixed.salt) : crypto.getRandomValues(new Uint8Array(16));
  const cek = await hkdf(salt, ikm, enc.encode('Content-Encoding: aes128gcm\0'), 16);
  const nonce = await hkdf(salt, ikm, enc.encode('Content-Encoding: nonce\0'), 12);
  const key = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['encrypt']);
  const data = typeof plaintext === 'string' ? enc.encode(plaintext) : plaintext;
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, key, concat(data, new Uint8Array([2]))));
  const header = concat(salt, new Uint8Array([0, 0, 16, 0]), new Uint8Array([asPublic.length]), asPublic);
  return concat(header, ct);
}

async function vapidAuth(endpoint, vapid) {
  const aud = new URL(endpoint).origin;
  const h = b64u(enc.encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })));
  const c = b64u(enc.encode(JSON.stringify({ aud, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: vapid.subject })));
  const pub = unb64u(vapid.publicKey);
  const key = await crypto.subtle.importKey('jwk', rawToJwk(pub, vapid.privateKey), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, enc.encode(h + '.' + c)));
  return 'vapid t=' + h + '.' + c + '.' + b64u(sig) + ', k=' + vapid.publicKey;
}

async function sendPush(sub, payload, vapid) {
  const body = await encryptPayload(JSON.stringify(payload), sub.p256dh, sub.auth);
  const res = await fetch(sub.endpoint, {
    method: 'POST',
    headers: { 'Authorization': await vapidAuth(sub.endpoint, vapid), 'Content-Encoding': 'aes128gcm', 'Content-Type': 'application/octet-stream', 'TTL': '86400', 'Urgency': 'high' },
    body,
  });
  return res.status;
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json' } });
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  if (url.searchParams.get('setup') === '1') return json(await generateVapidKeys());
  if (req.method !== 'POST') return json({ ok: true, service: 'padelent send-push' });
  let input;
  try { input = await req.json(); } catch { return json({ error: 'bad request' }, 400); }
  const { vapid, subs, payload } = input || {};
  if (!vapid || !vapid.publicKey || !vapid.privateKey || !Array.isArray(subs)) return json({ error: 'bad request' }, 400);
  const gone = [], failed = [];
  let sent = 0;
  await Promise.all(subs.slice(0, 1000).map(async (s) => {
    try {
      const st = await sendPush(s, payload || {}, vapid);
      if (st >= 200 && st < 300) sent++;
      else if (st === 404 || st === 410) gone.push(s.endpoint);
      else failed.push(st);
    } catch (e) { failed.push(String(e && e.message || e)); }
  }));
  return json({ sent, gone, failed });
});

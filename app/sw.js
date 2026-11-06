// Padelent service worker: shows phone notifications. It does not cache anything.
self.addEventListener('install', function () { self.skipWaiting(); });
self.addEventListener('activate', function (e) { e.waitUntil(self.clients.claim()); });

self.addEventListener('push', function (e) {
  var d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) { d = { body: e.data && e.data.text() }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Padelent', {
    body: d.body || '',
    icon: '/app/icon-180.png',
    badge: '/app/icon-180.png',
    tag: d.tag || undefined,
    renotify: !!d.tag,
    data: { url: d.url || '/app/' }
  }));
});

self.addEventListener('notificationclick', function (e) {
  e.notification.close();
  var url = new URL((e.notification.data && e.notification.data.url) || '/app/', self.location.origin).href;
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (list) {
    for (var i = 0; i < list.length; i++) {
      var c = list[i];
      if (c.url.indexOf(self.location.origin + '/app/') === 0 && 'focus' in c) {
        return c.focus().then(function (w) { return w && w.navigate ? w.navigate(url) : null; }).catch(function () {});
      }
    }
    return self.clients.openWindow(url);
  }));
});

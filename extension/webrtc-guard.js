// webrtc-guard.js — блокирует WebRTC на вкладках VPN-контейнера,
// чтобы ICE-кандидаты не слили реальный IP в обход Tor-прокси.
// Использует webNavigation + executeScript, поэтому загружается
// после proxy.js (нужен vpnContainerCookieStoreId).
//
// Как пришли к текущему подходу:
// 1) Изначально код блокировки выполнялся прямо в теле content
//    script'а через Object.defineProperty(window, ...). В Firefox
//    это не работало: content script и страница видят РАЗНЫЕ
//    версии window (Xray vision), изменения content script'а
//    невидимы для страницы — WebRTC оставался полностью открыт.
// 2) Затем код вынесли в отдельный файл и подключали как
//    <script src="moz-extension://...">, чтобы обойти Xray. Но это
//    требовало web_accessible_resources — а значит, ЛЮБОЙ сайт мог
//    зондом проверить наличие этого URL, обнаружить TabVPN и получить
//    стабильный internal UUID расширения как идентификатор для
//    слежки, переживающий смену Tor-цепочки (newCircuit). Отдельная
//    утечка, ничем не лучше исходной.
// 3) Правильное решение — window.wrappedJSObject: Firefox даёт
//    content script прямую ссылку на настоящий объект страницы.
//    Правки через неё сразу видны странице, без вставки <script>,
//    без CSP-проблем (CSP ограничивает то, что грузит/исполняет
//    сама страница, а не действия привилегированного content
//    script) и без единого публичного extension-ресурса.

async function injectWebrtcGuardIfVpnTab(tabId, frameId) {
  let tab;
  try {
    tab = await browser.tabs.get(tabId);
  } catch (err) {
    return; // вкладка уже закрылась
  }
  if (tab.cookieStoreId !== vpnContainerCookieStoreId) return;
  try {
    await browser.tabs.executeScript(tabId, {
      code: `
        (function () {
          const win = window.wrappedJSObject;
          function disable(name) {
            if (!(name in win)) return;
            try {
              win[name] = undefined;
            } catch (err) {
              // свойство не перезаписывается — ничего не делаем
            }
          }
          disable('RTCPeerConnection');
          disable('webkitRTCPeerConnection');
          disable('mozRTCPeerConnection');
          disable('RTCDataChannel');
        })();
      `,
      runAt: 'document_start',
      frameId,
    });
  } catch (err) {
    console.error('TabVPN: не удалось внедрить WebRTC-блокировку', err);
  }
}

browser.webNavigation.onCommitted.addListener((details) => {
  if (details.frameId !== 0) return; // только top-level фрейм
  // Пропускаем about:blank и другие служебные страницы, возникающие
  // при открытии новой вкладки до настоящей навигации — на них
  // executeScript падает с "Missing host permission for the tab",
  // это ожидаемо и не является реальной ошибкой.
  if (!details.url || !/^https?:\/\//.test(details.url)) return;
  injectWebrtcGuardIfVpnTab(details.tabId, details.frameId);
});

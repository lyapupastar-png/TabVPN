// webrtc-guard.js — блокирует WebRTC на вкладках VPN-контейнера,
// чтобы ICE-кандидаты не слили реальный IP в обход Tor-прокси
// (Задача 5 из PLAN.md). Использует webNavigation + executeScript,
// поэтому загружается после proxy.js (нужен vpnContainerCookieStoreId).

const WEBRTC_BLOCK_CODE = `
(function () {
  function disable(name) {
    if (!(name in window)) return;
    try {
      Object.defineProperty(window, name, {
        get() {
          throw new Error('TabVPN: WebRTC отключён в этом контейнере');
        },
        configurable: false,
      });
    } catch (err) {
      // свойство уже non-configurable — ничего не делаем
    }
  }
  disable('RTCPeerConnection');
  disable('webkitRTCPeerConnection');
  disable('mozRTCPeerConnection');
  disable('RTCDataChannel');
})();
`;

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
      code: WEBRTC_BLOCK_CODE,
      runAt: 'document_start',
      frameId,
    });
  } catch (err) {
    console.error('TabVPN: не удалось внедрить WebRTC-блокировку', err);
  }
}

browser.webNavigation.onCommitted.addListener((details) => {
  if (details.frameId !== 0) return; // только top-level фрейм
  injectWebrtcGuardIfVpnTab(details.tabId, details.frameId);
});

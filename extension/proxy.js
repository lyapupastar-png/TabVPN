// proxy.js — контейнер "VPN" и маршрутизация его трафика через Tor.
// Загружается первым в background-scripts, определяет глобальные
// переменные, которые использует contextmenu.js и background.js.

const VPN_CONTAINER_NAME = "VPN";

let vpnContainerCookieStoreId = null;
let torStatus = { ready: false, port: null };

async function ensureVpnContainer() {
  const existing = await browser.contextualIdentities.query({
    name: VPN_CONTAINER_NAME,
  });
  if (existing.length > 0) {
    vpnContainerCookieStoreId = existing[0].cookieStoreId;
    return;
  }
  const created = await browser.contextualIdentities.create({
    name: VPN_CONTAINER_NAME,
    color: "purple",
    icon: "fingerprint",
  });
  vpnContainerCookieStoreId = created.cookieStoreId;
}

function handleProxyRequest(requestInfo) {
  if (
    requestInfo.cookieStoreId === vpnContainerCookieStoreId &&
    torStatus.ready &&
    torStatus.port
  ) {
    return {
      type: "socks",
      host: "127.0.0.1",
      port: torStatus.port,
      proxyDNS: true,
    };
  }
  return { type: "direct" };
}

browser.proxy.onRequest.addListener(handleProxyRequest, { urls: ["<all_urls>"] });

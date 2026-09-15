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

// Изоляция цепочек по вкладкам: без этого все вкладки VPN-контейнера
// делят один и тот же пул цепочек на стороне Tor — смена IP для
// одной вкладки задевает остальные, а "плохая" цепочка на одном
// домене может переиспользоваться для него же снова и снова. Разные
// логин/пароль на SOCKS5 CONNECT заставляют Tor строить полностью
// отдельную изолированную цепочку под каждое значение
// (IsolateSOCKSAuth включён в Tor по умолчанию) — это единственный
// способ поменять IP одной вкладки, не трогая остальные.
const tabSocksTokens = new Map(); // tabId -> токен

function makeToken(tabId) {
  return "tab" + tabId + "-" + Math.random().toString(36).slice(2);
}

function getOrCreateTabToken(tabId) {
  let token = tabSocksTokens.get(tabId);
  if (!token) {
    token = makeToken(tabId);
    tabSocksTokens.set(tabId, token);
  }
  return token;
}

function rotateTabToken(tabId) {
  const token = makeToken(tabId);
  tabSocksTokens.set(tabId, token);
  return token;
}

browser.tabs.onRemoved.addListener((tabId) => {
  tabSocksTokens.delete(tabId);
});

function handleProxyRequest(requestInfo) {
  if (
    requestInfo.cookieStoreId === vpnContainerCookieStoreId &&
    torStatus.ready &&
    torStatus.port
  ) {
    const token = getOrCreateTabToken(requestInfo.tabId);
    return {
      type: "socks",
      host: "127.0.0.1",
      port: torStatus.port,
      proxyDNS: true,
      username: token,
      password: token,
    };
  }
  return { type: "direct" };
}

browser.proxy.onRequest.addListener(handleProxyRequest, { urls: ["<all_urls>"] });

// Настоящий Tor Browser всегда подменяет User-Agent на единое для
// всех пользователей значение ("Windows NT 10.0" независимо от
// реальной ОС) и Accept-Language на "en-US" — намеренно, чтобы не
// выделяться на фоне остальных Tor-пользователей своей "родной"
// связкой ОС+языка. TabVPN раньше пропускал через прокси настоящие
// заголовки обычного профиля Firefox — на exit-узле из другой страны
// сочетание "Tor-IP + macOS + ru/uk Accept-Language" нетипично для
// Tor-трафика и могло восприниматься антибот-системами сайтов как
// более подозрительное, чем однородный трафик Tor Browser (отдельная
// от конкретного IP причина более частых блокировок).
// TOR_BROWSER_UA стоит периодически сверять с текущей версией самого
// Tor Browser (torproject.org) — раз в несколько релизов достаточно,
// расхождение в 1-2 версии не критично для антифингерпринт-эффекта.
const TOR_BROWSER_UA = "Mozilla/5.0 (Windows NT 10.0; rv:128.0) Gecko/20100101 Firefox/128.0";
const TOR_BROWSER_ACCEPT_LANGUAGE = "en-US,en;q=0.5";

// ТЕСТ (2026-09-15): старая рабочая версия TabVPN не имитировала Tor
// Browser вообще. Гипотеза: сама имитация триггерит у Cloudflare
// более жёсткий Tor-специфичный сценарий проверки (PAT), который
// настоящий Tor Browser проходит, а обычный Firefox — нет. Флаг ниже
// выключает имитацию целиком (заголовки + navigator override) для
// практической проверки на hdrezka.tv.
const IMPERSONATE_TOR_BROWSER = false;

function handleVpnHeaders(details) {
  if (details.cookieStoreId !== vpnContainerCookieStoreId) return {};
  if (!IMPERSONATE_TOR_BROWSER) return {};
  const headers = details.requestHeaders.map((h) => {
    const lower = h.name.toLowerCase();
    if (lower === "user-agent") return { name: h.name, value: TOR_BROWSER_UA };
    if (lower === "accept-language") return { name: h.name, value: TOR_BROWSER_ACCEPT_LANGUAGE };
    return h;
  });
  return { requestHeaders: headers };
}

browser.webRequest.onBeforeSendHeaders.addListener(
  handleVpnHeaders,
  { urls: ["<all_urls>"] },
  ["blocking", "requestHeaders"]
);

// handleVpnHeaders выше подменяет UA/Accept-Language только в HTTP-
// заголовках. Свойства navigator.userAgent/platform/language,
// видимые самой странице через JS, остаются настоящими (реальная
// ОС/версия Firefox пользователя) — рассинхрон HTTP-заголовка и
// JS-значения сам по себе частый сигнал для антибот-систем, отдельно
// от Alt-Svc/onion-гипотезы (см. NEXT_TASK.md, 2026-09-14). Чиним
// через инъекцию <script> в мир страницы (tabs.executeScript выполняет
// код в изолированном мире контент-скрипта, а не в мире страницы —
// поэтому оборачиваем в создание script-тега, а не просто в code).
// Вызывается из background.js внутри уже существующего
// webNavigation.onBeforeNavigate (там же, где проверка isVpnTab) —
// как можно раньше, до document_start самой страницы. Не сработает
// на сайтах со строгим CSP (script-src без 'unsafe-inline') — это
// известное ограничение техники, не баг.
const TOR_BROWSER_APPVERSION = TOR_BROWSER_UA.replace("Mozilla/5.0 ", "");

function buildNavigatorOverrideSource() {
  return (
    "(function(){try{" +
    "Object.defineProperty(Navigator.prototype,'userAgent',{get:function(){return " +
    JSON.stringify(TOR_BROWSER_UA) +
    ";}});" +
    "Object.defineProperty(Navigator.prototype,'appVersion',{get:function(){return " +
    JSON.stringify(TOR_BROWSER_APPVERSION) +
    ";}});" +
    "Object.defineProperty(Navigator.prototype,'platform',{get:function(){return 'Win32';}});" +
    "Object.defineProperty(Navigator.prototype,'oscpu',{get:function(){return 'Windows NT 10.0';}});" +
    "Object.defineProperty(Navigator.prototype,'language',{get:function(){return 'en-US';}});" +
    "Object.defineProperty(Navigator.prototype,'languages',{get:function(){return Object.freeze(['en-US','en']);}});" +
    "}catch(e){}})();"
  );
}

function injectVpnFingerprintOverride(tabId) {
  if (!IMPERSONATE_TOR_BROWSER) return;
  const injectorCode =
    "(function(){try{" +
    "var s=document.createElement('script');" +
    "s.textContent=" + JSON.stringify(buildNavigatorOverrideSource()) + ";" +
    "(document.head||document.documentElement).appendChild(s);" +
    "s.remove();" +
    "}catch(e){}})();";
  browser.tabs
    .executeScript(tabId, { code: injectorCode, runAt: "document_start", allFrames: true })
    .catch(() => {});
}

// Гипотеза 2026-09-14 (четвёртый проход капчи, см. NEXT_TASK.md):
// диагностика в background.js поймала "Alternate Service Mapping
// found ... onion" в логе Firefox — Cloudflare отдаёт Alt-Svc на
// .onion-зеркало сайта клиентам, похожим на Tor Browser (наш
// TOR_BROWSER_UA выше как раз таким и притворяется). Настоящий Tor
// Browser умеет опознавать и корректно обслуживать переход на
// .onion через собственный Tor-стек; обычный Firefox с внешним
// SOCKS-Tor такого не умеет — похоже, именно попытка Firefox
// самостоятельно (opportunistically) поднять .onion-альтернативу
// после клика по капче и даёт видимость "капча появилась again"
// (на деле — новый, ещё не пройденный челлендж на .onion-версии
// сайта, а не повтор того же). Подтверждено пользователем отдельно:
// настоящий Tor Browser грузит hdrezka.tv без капчи вообще (и на
// Mac, и на Win) — значит дело не в Tor-сети и не в бане exit-узла,
// а именно в разнице поведения TabVPN vs настоящего Tor Browser.
// Вырезаем Alt-Svc/Onion-Location из ответов для VPN-контейнера,
// чтобы Firefox даже не пытался на них реагировать. НЕ ПРОВЕРЕНО
// ПРАКТИЧЕСКИ — это тест гипотезы, не подтверждённый фикс.
function handleVpnResponseHeaders(details) {
  if (details.cookieStoreId !== vpnContainerCookieStoreId) return {};
  const headers = details.responseHeaders.filter((h) => {
    const lower = h.name.toLowerCase();
    return lower !== "alt-svc" && lower !== "onion-location";
  });
  return { responseHeaders: headers };
}

browser.webRequest.onHeadersReceived.addListener(
  handleVpnResponseHeaders,
  { urls: ["<all_urls>"] },
  ["blocking", "responseHeaders"]
);

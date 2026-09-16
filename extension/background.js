// background.js — связь с native host, статус Tor, инициализация.

const NATIVE_HOST_ID = "com.tabvpn.host";
let nativePort = null;

function updateBadge() {
  browser.browserAction.setBadgeText({ text: "" });
  if (torStatus.ready) {
    browser.browserAction.setIcon({ path: "icons/earth-ok.svg" });
    browser.browserAction.setTitle({ title: "TabVPN — Tor готов" });
  } else {
    browser.browserAction.setIcon({ path: "icons/earth.svg" });
    browser.browserAction.setTitle({ title: "TabVPN — Tor запускается" });
  }
}

function handleNativeMessage(message) {
  if (!message || typeof message.type !== "string") return;
  if (message.type === "status") {
    torStatus.ready = !!message.ready;
    torStatus.port = message.port || null;
    updateBadge();
  } else if (message.type === "error") {
    browser.browserAction.setBadgeText({ text: "" });
    browser.browserAction.setIcon({ path: "icons/earth-err.svg" });
    browser.browserAction.setTitle({ title: "TabVPN: " + message.message });
    console.error("TabVPN native host error:", message.message);
  } else if (message.type === "newCircuitResult") {
    if (!message.ok) {
      console.error("TabVPN: не удалось сменить IP —", message.error);
    }
  }
}

// Раньше при разрыве native-порта ready просто сбрасывался в false
// и НИКТО не пытался переподключиться — если пайп с хостом отваливался
// (а по логам host.log он отваливался почти сразу после каждого
// коннекта), расширение навсегда застревало в состоянии "Tor не
// готов", прокси на VPN-контейнер переставал применяться, и вкладки
// с "Открыть с VPN" молча шли напрямую — именно это давало "нет
// разницы между обычной вкладкой и VPN".
let reconnectTimer = null;

function scheduleReconnect() {
  if (reconnectTimer) return;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connectNativeHost();
  }, 3000);
}

function connectNativeHost() {
  try {
    nativePort = browser.runtime.connectNative(NATIVE_HOST_ID);
  } catch (err) {
    console.error("TabVPN: не удалось подключиться к native host —", err);
    nativePort = null;
    updateBadge();
    scheduleReconnect();
    return;
  }
  nativePort.onMessage.addListener(handleNativeMessage);
  nativePort.onDisconnect.addListener((port) => {
    torStatus.ready = false;
    torStatus.port = null;
    nativePort = null;
    updateBadge();
    // Firefox кладёт причину разрыва Port'а в port.error, а НЕ в
    // browser.runtime.lastError (тот относится к callback-style API,
    // не к событию onDisconnect) — из-за этого раньше реальная причина
    // (например "no such native application") нигде не показывалась,
    // и в консоли повторялось одно и то же сообщение без деталей.
    const err = port && port.error;
    console.warn("TabVPN: native host отключился" + (err ? " — " + err.message : " (Firefox не дал деталей ошибки)") + ", переподключаюсь через 3с");
    scheduleReconnect();
  });
  nativePort.postMessage({ command: "status" });
}

// Разрыв native-порта не всегда сопровождается видимой ошибкой —
// периодически сверяем статус сами, чтобы бейдж и torStatus не могли
// надолго разойтись с реальным состоянием Tor.
setInterval(() => {
  if (nativePort) {
    try {
      nativePort.postMessage({ command: "status" });
    } catch (err) {
      console.warn("TabVPN: не удалось запросить status, порт мёртв —", err);
      nativePort = null;
      scheduleReconnect();
    }
  } else {
    connectNativeHost();
  }
}, 10000);

browser.browserAction.onClicked.addListener(async (tab) => {
  if (!vpnContainerCookieStoreId) return;
  // Меняем не глобальный NEWNYM, а SOCKS-токен конкретной вкладки —
  // это единственный способ дать одной вкладке новую, полностью
  // изолированную цепочку без влияния на остальные (см. proxy.js).
  if (tab && tab.cookieStoreId === vpnContainerCookieStoreId) {
    clearRetryState(tab.id); // ручной клик отменяет автоповтор той же вкладки
    clearCfChallenge(tab.id); // и принудительно выходит из окна капчи
    clearTabIndicator(tab.id);
    rotateTabToken(tab.id);
    browser.tabs.reload(tab.id);
  } else {
    const tabs = await browser.tabs.query({ cookieStoreId: vpnContainerCookieStoreId });
    for (const t of tabs) {
      clearRetryState(t.id);
      clearCfChallenge(t.id);
      clearTabIndicator(t.id);
      rotateTabToken(t.id);
      browser.tabs.reload(t.id);
    }
  }
});

// Автоповтор для ОДНОЙ вкладки при 403, обрыве соединения или
// "зависании" (нет ответа за HANG_TIMEOUT_MS). Безопасно после
// изоляции цепочек по токенам — смена токена одной вкладки не
// трогает остальные. Учтено:
//  - только main_frame (не саброесурсы вроде картинок/трекеров);
//  - только GET (не трогаем отправки форм — POST не повторяем);
//  - потолок попыток, чтобы не долбить сайт, блокирующий не из-за Tor;
//  - таймер зависания снят с ручного клика, чтобы не гонялись вместе;
//  - индикация только для конкретной вкладки (без подписи на странице).
const MAX_AUTO_RETRIES = 10;
const HANG_TIMEOUT_MS = 30000;
const retryState = new Map(); // tabId -> { attempts, hangTimer }

function clearRetryState(tabId) {
  const state = retryState.get(tabId);
  if (state && state.hangTimer) clearTimeout(state.hangTimer);
  retryState.delete(tabId);
}

function markTabFailed(tabId) {
  browser.browserAction.setIcon({ tabId, path: "icons/earth-err.svg" });
  browser.browserAction.setTitle({
    tabId,
    title: "TabVPN: не удалось открыть страницу (" + MAX_AUTO_RETRIES + " попыток)",
  });
}

function clearTabIndicator(tabId) {
  browser.browserAction.setIcon({ tabId, path: null });
  browser.browserAction.setTitle({ tabId, title: "" });
}

// Прохождение капчи Cloudflare — не одна страница, а короткая
// цепочка навигаций: статичная страница с галочкой → после клика
// редирект на длинный callback-URL (/cdn-cgi/challenge-platform/,
// стандартный путь Cloudflare для валидации) → и только потом чистый
// финальный URL с cf_clearance-cookie. Сбой (таймаут/сетевая ошибка/
// 403 без нужного заголовка) на ЛЮБОМ из промежуточных шагов через
// Tor раньше вызывал смену цепочки — новый IP без cf_clearance, и
// капча появлялась заново (см. NEXT_TASK.md, 2026-09-14, два прохода
// правки). Вместо того чтобы ловить каждый возможный триггер отдельно
// — помечаем вкладку целиком как "идёт капча" по URL-паттерну и
// держим это состояние поверх всех трёх механизмов ротации (403,
// ошибка, таймаут), пока не увидим настоящий финальный ответ. Потолок
// на случай реально зависшего процесса — не держать окно вечно.
const CF_CHALLENGE_URL_RE = /\/cdn-cgi\/challenge-platform\//i;
const CF_CHALLENGE_GRACE_MS = 90000;
const cfChallengeTabs = new Map(); // tabId -> дедлайн (timestamp)
// пятый проход диагностики (2026-09-14): момент ПЕРВОЙ пометки капчи
// на вкладке, отдельно от дедлайна выше (тот двигается вперёд при
// каждом новом вызове markCfChallenge) — нужен, чтобы посчитать,
// сколько реально прошло времени между началом challenge и отправкой
// pat-токена, для проверки гипотезы "токен просрочился через Tor".
const cfChallengeStartedAt = new Map(); // tabId -> timestamp

function markCfChallenge(tabId) {
  cfChallengeTabs.set(tabId, Date.now() + CF_CHALLENGE_GRACE_MS);
  if (!cfChallengeStartedAt.has(tabId)) cfChallengeStartedAt.set(tabId, Date.now());
}

function inCfChallenge(tabId) {
  const deadline = cfChallengeTabs.get(tabId);
  if (!deadline) return false;
  if (Date.now() > deadline) {
    cfChallengeTabs.delete(tabId);
    return false;
  }
  return true;
}

function clearCfChallenge(tabId) {
  cfChallengeTabs.delete(tabId);
  cfChallengeStartedAt.delete(tabId);
}

async function isVpnTab(tabId) {
  if (!vpnContainerCookieStoreId) return false;
  try {
    const tab = await browser.tabs.get(tabId);
    return tab.cookieStoreId === vpnContainerCookieStoreId;
  } catch (err) {
    return false; // вкладка уже закрылась
  }
}

function retryTab(tabId) {
  const state = retryState.get(tabId) || { attempts: 0, hangTimer: null };
  state.attempts += 1;
  if (state.attempts > MAX_AUTO_RETRIES) {
    clearRetryState(tabId);
    markTabFailed(tabId);
    console.warn("TabVPN: вкладка", tabId, "— исчерпаны автопопытки (" + MAX_AUTO_RETRIES + ")");
    return;
  }
  retryState.set(tabId, state);
  rotateTabToken(tabId);
  try {
    browser.tabs.reload(tabId);
  } catch (err) {
    clearRetryState(tabId);
  }
}

function armHangTimer(tabId) {
  const state = retryState.get(tabId) || { attempts: 0, hangTimer: null };
  if (state.hangTimer) clearTimeout(state.hangTimer);
  state.hangTimer = setTimeout(() => {
    console.warn("TabVPN: HANG TIMEOUT вкладка", tabId, "—", HANG_TIMEOUT_MS / 1000, "с без ответа, inCfChallenge:", inCfChallenge(tabId));
    retryTab(tabId);
  }, HANG_TIMEOUT_MS);
  retryState.set(tabId, state);
}

browser.webNavigation.onBeforeNavigate.addListener(async (details) => {
  if (details.frameId !== 0) return;
  if (!(await isVpnTab(details.tabId))) return;
  injectVpnFingerprintOverride(details.tabId); // navigator.userAgent/platform/language — см. proxy.js
  if (CF_CHALLENGE_URL_RE.test(details.url)) markCfChallenge(details.tabId);
  if (inCfChallenge(details.tabId)) return; // не взводим таймер зависания в окне капчи
  armHangTimer(details.tabId);
});

browser.webRequest.onCompleted.addListener(
  (details) => {
    if (details.type !== "main_frame") return;
    if (details.cookieStoreId !== vpnContainerCookieStoreId) return;
    const state = retryState.get(details.tabId);
    if (state && state.hangTimer) clearTimeout(state.hangTimer);

    const cfMitigated = (details.responseHeaders || []).find(
      (h) => h.name.toLowerCase() === "cf-mitigated"
    );

    if (cfMitigated && /challenge/i.test(cfMitigated.value)) {
      // Сама интерстишиал-страница с галочкой — штатный 403.
      markCfChallenge(details.tabId);
      clearRetryState(details.tabId);
      clearTabIndicator(details.tabId);
      return;
    }
    if (CF_CHALLENGE_URL_RE.test(details.url)) {
      // Промежуточный callback challenge-platform отработал (любым
      // статусом) — остаёмся в окне капчи до финальной страницы.
      markCfChallenge(details.tabId);
      clearRetryState(details.tabId);
      clearTabIndicator(details.tabId);
      return;
    }
    if (inCfChallenge(details.tabId)) {
      // Финальная навигация после капчи. Не 403 — считаем пройденной
      // и снимаем окно; 403 здесь же — тоже НЕ ротируем цепочку,
      // чтобы не терять уже почти полученный cf_clearance раньше
      // времени (окно само истечёт по CF_CHALLENGE_GRACE_MS).
      if (details.statusCode !== 403) clearCfChallenge(details.tabId);
      clearRetryState(details.tabId);
      clearTabIndicator(details.tabId);
      return;
    }
    if (details.statusCode === 403 && details.method === "GET") {
      retryTab(details.tabId);
    } else {
      clearRetryState(details.tabId);
      clearTabIndicator(details.tabId);
    }
  },
  { urls: ["<all_urls>"] },
  ["responseHeaders"]
);

browser.webRequest.onErrorOccurred.addListener(
  (details) => {
    if (details.type !== "main_frame") return;
    if (details.cookieStoreId !== vpnContainerCookieStoreId) return;
    const state = retryState.get(details.tabId);
    if (state && state.hangTimer) clearTimeout(state.hangTimer);
    if (inCfChallenge(details.tabId) || CF_CHALLENGE_URL_RE.test(details.url)) {
      // Сетевой сбой прямо во время прохождения капчи — не рвём
      // цепочку, иначе теряем шанс на cf_clearance для уже решённой
      // капчи; тихо считаем это частью процесса, окно само истечёт.
      return;
    }
    if (details.method === "GET") {
      retryTab(details.tabId);
    } else {
      clearRetryState(details.tabId);
    }
  },
  { urls: ["<all_urls>"] }
);

browser.tabs.onRemoved.addListener((tabId) => {
  clearRetryState(tabId);
  clearCfChallenge(tabId);
});

async function init() {
  await ensureVpnContainer();
  connectNativeHost();
  updateBadge();
}

init();

// background.js — связь с native host, статус Tor, инициализация.

const NATIVE_HOST_ID = "com.tabvpn.host";
let nativePort = null;

function updateBadge() {
  if (torStatus.ready) {
    browser.browserAction.setBadgeText({ text: "OK" });
    browser.browserAction.setBadgeBackgroundColor({ color: "#2e7d32" });
    browser.browserAction.setTitle({ title: "TabVPN — Tor готов" });
  } else {
    browser.browserAction.setBadgeText({ text: "…" });
    browser.browserAction.setBadgeBackgroundColor({ color: "#9e9e9e" });
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
    browser.browserAction.setBadgeText({ text: "ERR" });
    browser.browserAction.setBadgeBackgroundColor({ color: "#c62828" });
    browser.browserAction.setTitle({ title: "TabVPN: " + message.message });
    console.error("TabVPN native host error:", message.message);
  } else if (message.type === "newCircuitResult") {
    if (!message.ok) {
      console.error("TabVPN: не удалось сменить IP —", message.error);
      return;
    }
    reloadVpnTabs();
  }
}

// После смены цепочки Tor (newCircuit) старые соединения ещё привязаны
// к прежнему exit-узлу — перезагружаем вкладки VPN-контейнера, чтобы
// они реально пошли через новый IP (Задача 6 из PLAN.md).
async function reloadVpnTabs() {
  if (!vpnContainerCookieStoreId) return;
  const tabs = await browser.tabs.query({ cookieStoreId: vpnContainerCookieStoreId });
  for (const tab of tabs) {
    browser.tabs.reload(tab.id);
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

browser.browserAction.onClicked.addListener(() => {
  if (!nativePort) {
    console.warn("TabVPN: native host не подключён — переподключаюсь перед newCircuit");
    connectNativeHost();
  }
  try {
    nativePort.postMessage({ command: "newCircuit" });
  } catch (err) {
    console.error("TabVPN: не удалось отправить newCircuit —", err);
  }
});

async function init() {
  await ensureVpnContainer();
  connectNativeHost();
  updateBadge();
}

init();

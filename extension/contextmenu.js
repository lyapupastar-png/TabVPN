// contextmenu.js — пункт меню "Открыть с VPN" и обработчик клика.

browser.contextMenus.create(
  {
    id: "open-with-vpn",
    title: "Открыть с VPN",
    contexts: ["link"],
  },
  () => {
    // Если пункт с таким id уже существует (например, из-за
    // повторной загрузки временного дополнения без полной
    // перезагрузки фона), Firefox не бросает исключение, а
    // молча пишет ошибку в runtime.lastError — логируем её,
    // чтобы не гадать, почему меню "не работает".
    if (browser.runtime.lastError) {
      console.error("TabVPN: contextMenus.create —", browser.runtime.lastError.message);
    }
  }
);

browser.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId !== "open-with-vpn") return;
  console.log("TabVPN: клик по 'Открыть с VPN'", {
    linkUrl: info.linkUrl,
    cookieStoreId: vpnContainerCookieStoreId,
    sourceTabIncognito: tab && tab.incognito,
  });

  if (!info.linkUrl) {
    console.error("TabVPN: у пункта меню нет info.linkUrl — не по чему открывать");
    return;
  }

  // Контейнеры (contextualIdentities) недоступны в приватных окнах:
  // попытка передать cookieStoreId из приватного окна отклоняется
  // Firefox с ошибкой, которую этот обработчик раньше не ловил —
  // именно из-за этого клик выглядел так, будто "ничего не происходит".
  if (tab && tab.incognito) {
    console.warn("TabVPN: приватное окно — контейнеры недоступны, открываю без VPN-контейнера");
    try {
      // Без windowId/cookieStoreId новая вкладка сама наследует
      // текущее (приватное) окно — отдельный флаг тут не нужен
      // и, более того, tabs.create его не поддерживает.
      await browser.tabs.create({ url: info.linkUrl });
    } catch (err) {
      console.error("TabVPN: не удалось открыть вкладку в приватном окне —", err);
    }
    return;
  }

  if (!vpnContainerCookieStoreId) {
    // Контейнер ещё не готов (ensureVpnContainer из proxy.js не
    // успел отработать) — просто открываем без спец-контейнера,
    // чем молча ничего не делать.
    console.warn("TabVPN: vpnContainerCookieStoreId ещё не готов, открываю без контейнера");
    try {
      await browser.tabs.create({ url: info.linkUrl });
    } catch (err) {
      console.error("TabVPN: не удалось открыть вкладку —", err);
    }
    return;
  }

  try {
    await browser.tabs.create({
      url: info.linkUrl,
      cookieStoreId: vpnContainerCookieStoreId,
    });
  } catch (err) {
    // Самая вероятная причина попадания сюда: cookieStoreId
    // ссылается на контейнер, которого больше нет (удалён вручную
    // в настройках Firefox), — tabs.create падает с ошибкой, а
    // промис раньше нигде не обрабатывался, поэтому ничего не
    // открывалось и никакой ошибки не было видно.
    console.error("TabVPN: не удалось открыть вкладку в VPN-контейнере —", err, "— пробую без контейнера");
    vpnContainerCookieStoreId = null;
    try {
      await browser.tabs.create({ url: info.linkUrl });
      await ensureVpnContainer(); // пересоздать/перепривязать контейнер на будущее
    } catch (err2) {
      console.error("TabVPN: не удалось открыть вкладку даже без контейнера —", err2);
    }
  }
});

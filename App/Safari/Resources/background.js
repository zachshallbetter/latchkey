// Passes the content script's requests to Latchkey's native side, adding the page's origin as Safari reports it.
// Nothing here keeps a value: it goes straight through to the app, which asks before saving or filling, and decides
// which sites an item may be filled on from the origin given here, not from anything the page says. It also keeps the
// toolbar badge (how many keys the page shows) and the "Save Selection to Latchkey" menu item.
var APP = "io.snackstud.latchkey";

// First, so nothing below can stop saving from working.
browser.runtime.onMessage.addListener(function (message, sender) {
  if (!sender.tab || !sender.tab.url) return undefined;
  if (message.op === "count") {
    var n = Math.max(0, Math.min(99, message.count | 0));
    try {
      browser.action.setBadgeText({ tabId: sender.tab.id, text: n ? String(n) : "" });
      if (browser.action.setBadgeBackgroundColor) browser.action.setBadgeBackgroundColor({ tabId: sender.tab.id, color: "#0a63d1" });
    } catch (e) {}
    return undefined;
  }
  if (["places", "save", "fillable", "fill"].indexOf(message.op) < 0) return undefined;
  // Filling only ever goes to the page itself, never a frame inside it.
  if ((message.op === "fillable" || message.op === "fill") && sender.frameId > 0) return undefined;
  var origin;
  try { origin = new URL(sender.tab.url).origin; } catch (e) { return undefined; }
  return Promise.resolve(browser.runtime.sendNativeMessage(APP, Object.assign({}, message, { page: origin })))
    .catch(function () { return { ok: false, error: "Couldn't reach Latchkey. Open the app and try again." }; });
});

var menus = browser.menus || browser.contextMenus;
function setupMenu() {
  if (!menus) return;
  try {
    Promise.resolve(menus.removeAll()).catch(function () {}).then(function () {
      try { menus.create({ id: "lk-save-selection", title: "Save Selection to Latchkey", contexts: ["selection"] }); } catch (e) {}
    });
  } catch (e) {}
}
if (menus) {
  browser.runtime.onInstalled.addListener(setupMenu);
  if (browser.runtime.onStartup) browser.runtime.onStartup.addListener(setupMenu);
  setupMenu();
  menus.onClicked.addListener(function (info, tab) {
    if (info.menuItemId === "lk-save-selection" && tab && tab.id != null) {
      Promise.resolve(browser.tabs.sendMessage(tab.id, { op: "save-selection" }, { frameId: 0 })).catch(function () {});
    }
  });
}

// Passes the content script's requests to Pistachio's native side, adding the page's origin as Safari reports it.
// Nothing here keeps a value: it goes straight through to the app, which asks before saving or filling, and decides
// which sites an item may be filled on from the origin given here, not from anything the page says. It also keeps the
// toolbar badge (how many keys the page shows) and the "Save Selection to Pistachio" menu item.
var APP = "io.snackstud.latchkey";
var selectionErrors = new Map();
var SELECTION_ERROR = "Couldn’t open Save to Pistachio. Reload this page, allow Pistachio access to this site, then select the text and try again.";
function selectionState(tabId, error) {
  if (error) selectionErrors.set(tabId, error); else selectionErrors.delete(tabId);
  // Only static recovery text is retained; never retain or log the selected value.
  try {
    browser.action.setBadgeText({ tabId: tabId, text: error ? "!" : "" });
    browser.action.setTitle({ tabId: tabId, title: error || "Pistachio" });
  } catch (_) {}
}

// First, so nothing below can stop saving from working.
browser.runtime.onMessage.addListener(function (message, sender) {
  if (message.op === "selection-status") return Promise.resolve({ error: selectionErrors.get(message.tabId) || "" });
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
    .catch(function () { return { ok: false, error: "Couldn't reach Pistachio. Open the app and try again." }; });
});

var menus = browser.menus || browser.contextMenus;
function setupMenu() {
  if (!menus) return;
  try {
    Promise.resolve(menus.removeAll()).catch(function () {}).then(function () {
      try { menus.create({ id: "lk-save-selection", title: "Save Selection to Pistachio", contexts: ["selection"] }); } catch (e) {}
    });
  } catch (e) {}
}
if (menus) {
  browser.runtime.onInstalled.addListener(setupMenu);
  if (browser.runtime.onStartup) browser.runtime.onStartup.addListener(setupMenu);
  setupMenu();
  menus.onClicked.addListener(function (info, tab) {
    if (info.menuItemId === "lk-save-selection" && tab && tab.id != null) {
      if (info.frameId > 0 || typeof info.selectionText !== "string" || !info.selectionText.trim() || info.selectionText.length > 16 * 1024) {
        selectionState(tab.id, "Select up to 16 KiB of text in the main page, then try Save Selection again.");
        return;
      }
      var message = { op: "save-selection", selectionText: info.selectionText };
      function send() { return browser.tabs.sendMessage(tab.id, message, { frameId: 0 }); }
      Promise.resolve().then(send).catch(function () {
        // Existing tabs may have no listener after installation/reload. activeTab was granted by this menu click.
        if (!browser.scripting || typeof PistachioBrowserConfig === "undefined") throw new Error("Reload required");
        return browser.scripting.executeScript({
          target: { tabId: tab.id, frameIds: [0] },
          files: ["browser-config.js", "browser-api.js", "detector.js", "content.js"]
        }).then(send);
      }).then(function (opened) {
        selectionState(tab.id, opened ? "" : SELECTION_ERROR);
      }).catch(function () { selectionState(tab.id, SELECTION_ERROR); });
    }
  });
}

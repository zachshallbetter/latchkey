// Passes the content script's requests to Latchkey's native side, adding the page's origin as Safari reports it.
// Nothing here keeps a value: it goes straight through to the app, which asks before saving.
browser.runtime.onMessage.addListener(function (message, sender) {
  if (!sender.tab || !sender.tab.url) return undefined;
  var origin;
  try { origin = new URL(sender.tab.url).origin; } catch (e) { return undefined; }
  if (message.op !== "places" && message.op !== "save") return undefined;
  return browser.runtime.sendNativeMessage("io.snackstud.latchkey", Object.assign({}, message, { page: origin }))
    .catch(function () { return { ok: false, error: "Couldn't reach Latchkey. Open the app and try again." }; });
});

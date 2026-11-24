// Small browser API adapter used only by Chrome/Firefox packages; Safari keeps its native API unchanged.
(function () {
  "use strict";
  const config = globalThis.PistachioBrowserConfig;
  const api = config.target === "chrome" ? globalThis.chrome : globalThis.browser;
  const chromeRuntime = config.target === "chrome" ? api.runtime : null;
  const failure = "Pistachio couldn't connect. Set up the browser connection and open the Mac app.";
  function call(owner, name, args) {
    if (!chromeRuntime) return owner[name](...args);
    return new Promise((resolve, reject) => {
      owner[name](...args, result => {
        // Consume lastError inside its callback; never forward raw native errors or payloads to page UI.
        if (chromeRuntime.lastError) reject(new Error("Browser request failed"));
        else resolve(result);
      });
    });
  }
  const incoming = chromeRuntime ? {
    addListener(listener) {
      api.runtime.onMessage.addListener((message, sender, respond) => {
        let result;
        try { result = listener(message, sender); }
        catch (_) { respond({ ok: false, error: "Browser request failed" }); return false; }
        if (result && typeof result.then === "function") {
          Promise.resolve(result).then(respond, () => respond({ ok: false, error: "Browser request failed" }));
          return true; // Keep Chrome's response channel alive on versions without Promise listener support.
        }
        return result;
      });
    }
  } : api.runtime.onMessage;
  const menus = api.menus || api.contextMenus;
  globalThis.PistachioBrowserAPI = {
    runtime: {
      onMessage: incoming,
      onInstalled: api.runtime.onInstalled,
      onStartup: api.runtime.onStartup,
      sendMessage: (...args) => call(api.runtime, "sendMessage", args),
      sendNativeMessage: (_host, message) => call(api.runtime, "sendNativeMessage", [
        config.host, { version: 1, message }
      ]).catch(() => ({ ok: false, error: failure }))
    },
    tabs: {
      query: (...args) => call(api.tabs, "query", args),
      sendMessage: (...args) => call(api.tabs, "sendMessage", args)
    },
    scripting: api.scripting && { executeScript: options => call(api.scripting, "executeScript", [options]) },
    action: api.action,
    menus: menus && {
      removeAll: () => call(menus, "removeAll", []),
      create: (...args) => menus.create(...args),
      onClicked: menus.onClicked
    }
  };
})();

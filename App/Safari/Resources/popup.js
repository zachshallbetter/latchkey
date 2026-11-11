// Shows whether the extension can reach the Latchkey app, and the keys spotted on this page (previews only).
(function () {
  var el = document.getElementById("status");
  browser.runtime.sendNativeMessage("io.snackstud.latchkey", { op: "status" }).then(function (r) {
    if (r && r.ok) { el.className = "status ok"; el.textContent = "Connected to Latchkey."; }
    else { el.className = "status no"; el.textContent = (r && r.error) || "Can't reach Latchkey. Open the app."; }
  }, function () {
    el.className = "status no"; el.textContent = "Can't reach Latchkey. Open the app.";
  });

  var list = document.getElementById("found"), none = document.getElementById("none");
  browser.tabs.query({ active: true, currentWindow: true }).then(function (tabs) {
    var tab = tabs[0];
    if (!tab) { none.hidden = false; return; }
    // Fields that expect a key, token or certificate, by their labels; nothing here reads what's in them.
    browser.tabs.sendMessage(tab.id, { op: "fields" }, { frameId: 0 }).then(function (fields) {
      if (!fields || !fields.length) return;
      var ul = document.getElementById("fields");
      fields.forEach(function (f) {
        var li = document.createElement("li"), t = document.createElement("span"), l = document.createElement("span");
        t.textContent = f.type; l.className = "l"; l.textContent = f.label;
        li.append(t, l); ul.append(li);
      });
      document.getElementById("fields-box").hidden = false;
    }).catch(function () {});
    return browser.tabs.sendMessage(tab.id, { op: "detections" }, { frameId: 0 }).then(function (found) {
      if (!found || !found.length) { none.hidden = false; return; }
      found.forEach(function (d) {
        var li = document.createElement("li"), b = document.createElement("button"), w = document.createElement("span");
        var t = document.createElement("span"), c = document.createElement("code"), tag = document.createElement("span");
        b.type = "button"; w.className = "w"; tag.className = "tag";
        t.textContent = d.type; c.textContent = d.preview;
        tag.textContent = d.isPublic ? "not secret" : d.confidence === "high" ? "strong match" : "possible secret";
        w.append(t, c); b.append(w, tag); li.append(b); list.append(li);
        b.addEventListener("click", function () {
          browser.tabs.sendMessage(tab.id, { op: "open", id: d.id }, { frameId: 0 }).then(function () { window.close(); });
        });
      });
    });
  }).catch(function () { none.hidden = false; });
})();

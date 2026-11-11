// Shows whether the extension can reach the Latchkey app.
(function () {
  var el = document.getElementById("status");
  browser.runtime.sendNativeMessage("io.snackstud.latchkey", { op: "status" }).then(function (r) {
    if (r && r.ok) { el.className = "status ok"; el.textContent = "Connected to Latchkey."; }
    else { el.className = "status no"; el.textContent = (r && r.error) || "Can't reach Latchkey. Open the app."; }
  }, function () {
    el.className = "status no"; el.textContent = "Can't reach Latchkey. Open the app.";
  });
})();

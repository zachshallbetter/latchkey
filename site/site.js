// Copy buttons for code blocks. Reads only the block's own text.
(function () {
  document.querySelectorAll("button.copy").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var code = btn.closest("figure").querySelector("code");
      var text = code ? code.textContent : "";
      function done(ok) {
        btn.textContent = ok ? "Copied" : "Press ⌘C";
        if (ok) btn.setAttribute("data-done", "");
        setTimeout(function () { btn.textContent = "Copy"; btn.removeAttribute("data-done"); }, 1600);
      }
      function select() {
        var r = document.createRange(); r.selectNodeContents(code);
        var s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
      }
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(function () { done(true); }, function () { select(); done(false); });
      } else { select(); done(false); }
    });
  });
})();

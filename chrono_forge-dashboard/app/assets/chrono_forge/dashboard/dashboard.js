(function () {
  "use strict";

  // Interactive behaviors are delegated to `document` and attached ONCE. Per-row
  // listeners are lost whenever the DOM is replaced — the back/forward cache,
  // a Hotwire/Turbo body swap, or the polling innerHTML refresh — which is why
  // row-click stopped working after navigating back. A single document-level
  // listener (document is never swapped) keeps matching current and future rows.
  if (!window.__chronoForgeDashboard) {
    window.__chronoForgeDashboard = true;

    document.addEventListener("click", function (e) {
      // Timestamp display toggle (relative vs absolute), persisted in a cookie.
      var timeSet = e.target.closest("[data-time-set]");
      if (timeSet) {
        document.cookie = "cf_time_format=" + timeSet.getAttribute("data-time-set") +
          ";path=/;max-age=31536000;samesite=lax";
        window.location.reload();
        return;
      }
      // Collapsible context tree
      var key = e.target.closest(".cf-context__key");
      if (key && key.closest("[data-collapsible]")) {
        var li = key.closest("li");
        if (li) li.classList.toggle("cf-collapsed");
        return;
      }
      // Whole-row navigation, except when the click landed on an interactive child.
      var row = e.target.closest("tr[data-href]");
      if (row && !e.target.closest("a, button, input, form, summary")) {
        window.location = row.getAttribute("data-href");
      }
    });

    // Auto-submit a filter control (e.g. the state select) on change.
    document.addEventListener("change", function (e) {
      var el = e.target.closest("[data-autosubmit]");
      if (el && el.form) el.form.requestSubmit();
    });

    // Confirm destructive actions: any form with data-confirm.
    document.addEventListener("submit", function (e) {
      var form = e.target.closest("form[data-confirm]");
      if (form && !window.confirm(form.getAttribute("data-confirm"))) e.preventDefault();
    });
  }

  // Auto-dismiss floating flash toasts after a few seconds (fade, then remove).
  document.querySelectorAll("[data-flash]").forEach(function (el, i) {
    setTimeout(function () {
      el.classList.add("opacity-0");
      setTimeout(function () { el.remove(); }, 300);
    }, 4000 + i * 150);
  });

  // Polling refresh of the list/stats region. Keep a single timer and re-resolve
  // the region each tick so it survives a swapped body.
  if (window.__chronoForgePoll) clearInterval(window.__chronoForgePoll);
  var body = document.body, interval = parseInt(body.getAttribute("data-poll-interval") || "0", 10) * 1000;
  if (interval > 0 && document.querySelector("[data-poll-region]") && !body.hasAttribute("data-poll-paused")) {
    window.__chronoForgePoll = setInterval(function () {
      var region = document.querySelector("[data-poll-region]");
      if (!region) return;
      fetch(window.location.href, { headers: { "X-Requested-With": "XMLHttpRequest" } })
        .then(function (r) { return r.text(); })
        .then(function (html) {
          var doc = new DOMParser().parseFromString(html, "text/html");
          var fresh = doc.querySelector("[data-poll-region]");
          if (fresh) region.innerHTML = fresh.innerHTML;
        }).catch(function () {});
    }, interval);
  }
})();

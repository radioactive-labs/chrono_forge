(function () {
  "use strict";

  // Interactive behaviors are delegated to `document` and attached ONCE. Per-row
  // listeners are lost whenever the DOM is replaced — the back/forward cache,
  // a Hotwire/Turbo body swap, or the polling morph refresh — which is why
  // row-click stopped working after navigating back. A single document-level
  // listener (document is never swapped) keeps matching current and future rows.
  // The polling refresh below morphs the region's contents, so descendants are
  // replaced there too — another reason delegation lives on `document`.
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
      // Auto-refresh interval control: persist and reload so the server re-renders
      // the body's data-poll-interval.
      var poll = e.target.closest("[data-poll-select]");
      if (poll) {
        document.cookie = "cf_poll_interval=" + poll.value + ";path=/;max-age=31536000;samesite=lax";
        window.location.reload();
        return;
      }
      var el = e.target.closest("[data-autosubmit]");
      if (el && el.form) {
        // A checkbox paired with a same-name hidden field (the "unchecked
        // submits 0" trick) would otherwise put `name=0&name=1` in the query
        // string when checked. Disable the hidden twin while checked so the URL
        // carries a single value.
        if (el.type === "checkbox") {
          el.form.querySelectorAll('input[type="hidden"][name="' + el.name + '"]').forEach(function (h) {
            h.disabled = el.checked;
          });
        }
        el.form.requestSubmit();
      }
    });

    // Confirm destructive actions: any form with data-confirm.
    document.addEventListener("submit", function (e) {
      var form = e.target.closest("form[data-confirm]");
      if (form && !window.confirm(form.getAttribute("data-confirm"))) e.preventDefault();
    });

    // Leave the filter inputs untouched during the polling morph refresh. Skipping
    // the element (rather than letting idiomorph reconcile it) keeps it in place —
    // so a value the user is typing, its caret, and focus all survive a tick
    // instead of being reset to the last-submitted server value.
    document.addEventListener("turbo:before-morph-element", function (e) {
      if (e.target.hasAttribute && e.target.hasAttribute("data-cf-poll-preserve")) e.preventDefault();
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
  //
  // The refresh is a Turbo morph stream, not an innerHTML swap: idiomorph mutates
  // the existing nodes in place instead of recreating them, so horizontal scroll,
  // focus, caret, and in-progress filter text all survive the update for free —
  // no manual preservation. `update` with method="morph" morphs the region's
  // contents while leaving the <main id> wrapper (and its data-poll-region hook)
  // untouched.
  if (window.__chronoForgePoll) clearInterval(window.__chronoForgePoll);
  var body = document.body, interval = parseInt(body.getAttribute("data-poll-interval") || "0", 10) * 1000;
  if (interval > 0 && document.getElementById("cf-poll-region") && !body.hasAttribute("data-poll-paused")) {
    window.__chronoForgePoll = setInterval(function () {
      if (!document.getElementById("cf-poll-region")) return;
      fetch(window.location.href, { headers: { "X-Requested-With": "XMLHttpRequest" } })
        .then(function (r) { return r.text(); })
        .then(function (html) {
          var doc = new DOMParser().parseFromString(html, "text/html");
          var fresh = doc.getElementById("cf-poll-region");
          if (!fresh || !window.Turbo) return;
          Turbo.renderStreamMessage(
            '<turbo-stream action="update" method="morph" target="cf-poll-region">' +
            "<template>" + fresh.innerHTML + "</template></turbo-stream>"
          );
        }).catch(function () {});
    }, interval);
  }
})();

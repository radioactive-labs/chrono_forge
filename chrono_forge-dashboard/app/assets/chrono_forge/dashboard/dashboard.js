(function () {
  "use strict";

  // Turbo Drive owns navigation and form submits, so the page is never fully
  // reloaded on a normal click. Two consequences shape this file:
  //
  //   1. Interactive behaviors are delegated to `document` and attached ONCE.
  //      Per-element listeners would be lost on every body swap; `document` is
  //      never swapped, so one delegated listener keeps matching current and
  //      future rows.
  //   2. Per-page setup (the poll timer, flash auto-dismiss) must re-run after
  //      every visit, so it lives in a `turbo:load` handler rather than at the
  //      top level — top-level code runs only when the script first executes.
  if (!window.__chronoForgeDashboard) {
    window.__chronoForgeDashboard = true;

    document.addEventListener("click", function (e) {
      // Timestamp display toggle (relative vs absolute), persisted in a cookie.
      // Re-visit the current URL so the server re-renders every timestamp.
      var timeSet = e.target.closest("[data-time-set]");
      if (timeSet) {
        document.cookie = "cf_time_format=" + timeSet.getAttribute("data-time-set") +
          ";path=/;max-age=31536000;samesite=lax";
        Turbo.visit(window.location.href, { action: "replace" });
        return;
      }
      // Collapsible context tree
      var key = e.target.closest(".cf-context__key");
      if (key && key.closest("[data-collapsible]")) {
        var li = key.closest("li");
        if (li) li.classList.toggle("cf-collapsed");
        return;
      }
      // Whole-row navigation, except when the click landed on an interactive
      // child. Turbo.visit keeps it an in-app visit (history + no full reload).
      var row = e.target.closest("tr[data-href]");
      if (row && !e.target.closest("a, button, input, form, summary")) {
        Turbo.visit(row.getAttribute("data-href"));
      }
    });

    document.addEventListener("change", function (e) {
      // Auto-refresh interval control: persist and re-visit so the server
      // re-renders the body's data-poll-interval (picked up in setupPage).
      var poll = e.target.closest("[data-poll-select]");
      if (poll) {
        document.cookie = "cf_poll_interval=" + poll.value + ";path=/;max-age=31536000;samesite=lax";
        Turbo.visit(window.location.href, { action: "replace" });
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

    // Confirm destructive actions: any form with data-confirm. preventDefault
    // stops both the native submit and Turbo's.
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

    // Runs on the initial load and after every Turbo visit render.
    document.addEventListener("turbo:load", setupPage);
  }

  // Per-page setup: (re)arm the flash toasts and the polling timer for whatever
  // page Turbo just rendered.
  function setupPage() {
    // Auto-dismiss floating flash toasts after a few seconds (fade, then remove).
    document.querySelectorAll("[data-flash]").forEach(function (el, i) {
      setTimeout(function () {
        el.classList.add("opacity-0");
        setTimeout(function () { el.remove(); }, 300);
      }, 4000 + i * 150);
    });

    // Polling refresh of the list/stats region. Keep a single timer; clear any
    // previous one so a navigation doesn't leave two running. Gate on the
    // [data-poll-region] attribute, not the #cf-poll-region id: the id is always
    // on <main> (it's the morph target), but the attribute is present only on
    // pages that opt into polling — the definition graph opts out so its live
    // Cytoscape canvas isn't morphed away.
    if (window.__chronoForgePoll) clearInterval(window.__chronoForgePoll);
    var body = document.body, interval = parseInt(body.getAttribute("data-poll-interval") || "0", 10) * 1000;
    if (interval > 0 && document.querySelector("[data-poll-region]") && !body.hasAttribute("data-poll-paused")) {
      window.__chronoForgePoll = setInterval(pollTick, interval);
    }
  }

  // One polling tick: fetch the current page and morph the list/stats region.
  //
  // The refresh is a Turbo morph stream, not an innerHTML swap: idiomorph mutates
  // the existing nodes in place instead of recreating them, so horizontal scroll,
  // focus, caret, and in-progress filter text all survive the update for free —
  // no manual preservation. `update` with method="morph" morphs the region's
  // contents while leaving the <main id> wrapper (and its data-poll-region hook)
  // untouched. Scoped to the region (not a whole-page refresh) so the header and
  // flash toasts are left alone.
  function pollTick() {
    if (!document.querySelector("[data-poll-region]")) return;
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
  }
})();

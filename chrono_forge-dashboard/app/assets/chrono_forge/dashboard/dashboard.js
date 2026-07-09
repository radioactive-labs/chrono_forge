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
          if (!fresh) return;
          // Preserve horizontal scroll of any scroll containers across the swap,
          // so polling doesn't yank a table back while it's being scrolled.
          var scrolls = Array.prototype.map.call(
            region.querySelectorAll(".overflow-x-auto"), function (el) { return el.scrollLeft; });

          // Preserve in-progress text in the filter boxes. The swap replaces the
          // inputs with server-rendered ones reflecting only the LAST SUBMITTED
          // query, so without this every poll tick wipes whatever is being typed
          // and drops focus. Capture each named text field's value, plus the caret
          // of the focused one, and reapply them after the swap.
          var isTextEntry = function (el) {
            if (!el) return false;
            if (el.tagName === "TEXTAREA") return true;
            if (el.tagName !== "INPUT") return false;
            return /^(text|search|email|url|tel|number|password)$/i.test(el.type || "text");
          };
          var values = {};
          region.querySelectorAll("input, textarea").forEach(function (el) {
            if (el.name && isTextEntry(el)) values[el.name] = el.value;
          });
          var active = document.activeElement;
          var activeName = (active && region.contains(active) && isTextEntry(active) && active.name) ? active.name : null;
          var caretStart = null, caretEnd = null;
          if (activeName) {
            try { caretStart = active.selectionStart; caretEnd = active.selectionEnd; } catch (e) {}
          }

          region.innerHTML = fresh.innerHTML;

          region.querySelectorAll(".overflow-x-auto").forEach(function (el, i) {
            if (scrolls[i]) el.scrollLeft = scrolls[i];
          });
          // Reapply preserved field values, then restore focus + caret.
          region.querySelectorAll("input, textarea").forEach(function (el) {
            if (el.name && isTextEntry(el) && Object.prototype.hasOwnProperty.call(values, el.name)) {
              el.value = values[el.name];
            }
          });
          if (activeName) {
            var refocus = region.querySelector("[name='" + activeName + "']");
            if (refocus) {
              refocus.focus();
              try { refocus.setSelectionRange(caretStart, caretEnd); } catch (e) {}
            }
          }
        }).catch(function () {});
    }, interval);
  }
})();

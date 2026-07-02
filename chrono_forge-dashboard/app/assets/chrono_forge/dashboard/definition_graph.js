// Renders the workflow definition DAG with Cytoscape + dagre. Reads the graph as
// JSON from #cf-graph[data-graph] (structured elements — no text grammar) and
// paints kind (node shape) + run status (fill/border). Interactive: pan/zoom,
// and tapping a node/edge shows its details and highlights its neighborhood.
(function () {
  var el = document.getElementById("cf-graph");
  if (!el || typeof cytoscape === "undefined") return;
  if (window.cytoscapeDagre) {
    try { cytoscape.use(window.cytoscapeDagre); } catch (e) { /* already registered */ }
  }

  var graph;
  try { graph = JSON.parse(el.getAttribute("data-graph")); } catch (e) { return; }

  // Escape before writing into innerHTML: labels, step names and guard text are
  // author-controlled source strings (step-name validation only forbids "$"), and
  // guards legitimately contain "<"/">", so they must not be treated as markup.
  var ESC = {"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"};
  function esc(s) { return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) { return ESC[c]; }); }

  // Node shape per durable kind (a legend in the view maps these back to names).
  var SHAPE = {
    execute: "round-rectangle", wait: "round-rectangle", wait_until: "round-rectangle",
    continue_if: "round-rectangle", branch: "round-rectangle", merge: "round-rectangle",
    repeat: "round-rectangle", join: "ellipse", dynamic: "round-rectangle",
    endpoint: "round-tag"
  };
  // [fill, border, text] per run status. not_reached is intentionally muted so the
  // path a run HASN'T reached recedes behind the path it has.
  var COLOR = {
    done: ["#ecfdf5", "#10b981", "#065f46"],
    active: ["#eff6ff", "#3b82f6", "#1e40af"],
    pending: ["#fafafa", "#d4d4d8", "#52525b"],
    not_reached: ["#ffffff", "#e4e4e7", "#a1a1aa"],
    failed: ["#fef2f2", "#ef4444", "#991b1b"],
    stalled: ["#fff7ed", "#f59e0b", "#9a3412"],
    unmapped: ["#fafaf9", "#d6d3d1", "#78716c"]
  };

  // Lead with the step's own name; the DSL word (kind) is carried by the shape +
  // the small kind line, so "durably_execute send_payment_reminder" reads as the
  // bold "send_payment_reminder" over a muted "execute".
  var KIND_WORD = {
    execute: "execute", wait: "wait", wait_until: "wait until", continue_if: "continue if",
    branch: "branch", merge: "merge", repeat: "repeat", dynamic: "dynamic", join: "join"
  };
  graph.nodes.forEach(function (n) {
    var kind = (n.classes.match(/kind-(\w+)/) || [])[1] || "";
    if (kind === "endpoint") { n.data.display = n.data.label; return; }
    var lbl = n.data.label || "";
    var name = lbl.indexOf(" ") > -1 ? lbl.slice(lbl.indexOf(" ") + 1) : lbl;
    // A repeat carries how many times it has run so far; show it inline (×N).
    if (n.data.repetitions) name += "  ×" + n.data.repetitions;
    n.data.display = (KIND_WORD[kind] ? KIND_WORD[kind].toUpperCase() + "\n" : "") + name;
  });

  var style = [
    {
      selector: "node",
      style: {
        "label": "data(display)", "text-wrap": "wrap", "text-max-width": "150px",
        "text-valign": "center", "text-halign": "center", "text-justification": "center",
        "font-family": "ui-sans-serif, system-ui, sans-serif", "font-size": "11px",
        "line-height": 1.35, "width": "170px", "height": "label",
        "padding": "12px", "shape": "round-rectangle", "corner-radius": "10px",
        "border-width": 1.5, "background-color": "#fff", "border-color": "#e4e4e7",
        "color": "#3f3f46", "text-outline-width": 0
      }
    },
    {selector: "edge", style: {
      // Guard sits near the TARGET (not mid-edge), so several edges leaving the
      // same node don't stack their labels on top of each other near the source.
      "target-label": "data(label)", "target-text-offset": "42px",
      "font-size": "9px", "font-family": "ui-sans-serif, system-ui, sans-serif",
      "color": "#64748b", "curve-style": "taxi", "taxi-direction": "downward",
      "taxi-turn": "40%", "taxi-turn-min-distance": "8px",
      "width": 1.5, "line-color": "#cbd5e1", "target-arrow-shape": "triangle",
      "target-arrow-color": "#94a3b8", "arrow-scale": 0.9,
      "text-background-color": "#fff", "text-background-opacity": 1,
      "text-background-padding": "3px", "text-background-shape": "round-rectangle",
      "text-border-color": "#e2e8f0", "text-border-width": 1, "text-border-opacity": 1,
      "text-max-width": "150px", "text-wrap": "ellipsis", "text-events": "yes"
    }},
    {selector: "edge.kind-terminal", style: {
      "line-style": "dashed", "line-color": "#f87171", "target-arrow-color": "#ef4444", "color": "#b91c1c"
    }},
    {selector: "node.dim", style: {"opacity": 0.2}},
    {selector: "edge.dim", style: {"opacity": 0.12}},
    {selector: "node.focus", style: {"border-width": 3}},
    {selector: "node.hover", style: {"border-width": 2.5}}
  ];
  Object.keys(SHAPE).forEach(function (k) {
    style.push({selector: "node.kind-" + k, style: {"shape": SHAPE[k]}});
  });
  Object.keys(COLOR).forEach(function (s) {
    style.push({selector: "node.status-" + s, style: {
      "background-color": COLOR[s][0], "border-color": COLOR[s][1], "color": COLOR[s][2]
    }});
  });
  style.push({selector: "node.kind-endpoint", style: {
    "background-color": "#18181b", "border-color": "#18181b", "color": "#fff",
    "width": "label", "font-size": "10px", "font-weight": "600", "padding": "8px"
  }});

  var cy = cytoscape({
    container: el,
    elements: graph,
    style: style,
    layout: {
      name: "dagre", rankDir: "TB", nodeSep: 42, rankSep: 70, edgeSep: 18,
      ranker: "network-simplex", padding: 30
    },
    minZoom: 0.25, maxZoom: 2.5, wheelSensitivity: 0.25, autoungrabify: true
  });
  cy.ready(function () { cy.fit(cy.elements(), 36); });

  var detail = document.getElementById("cf-graph-detail");
  function hint() {
    if (detail) detail.innerHTML = '<span class="text-zinc-400">Tap a node or edge to inspect it. Scroll to zoom, drag to pan.</span>';
  }
  function clearFocus() { cy.elements().removeClass("dim focus"); hint(); }

  cy.on("mouseover", "node", function (e) { e.target.addClass("hover"); });
  cy.on("mouseout", "node", function (e) { e.target.removeClass("hover"); });

  cy.on("tap", "node", function (evt) {
    var n = evt.target, hood = n.closedNeighborhood();
    cy.elements().addClass("dim");
    hood.removeClass("dim");
    cy.nodes().removeClass("focus");
    n.addClass("focus");
    if (detail) {
      var d = n.data(), cls = n.classes() || [];
      var kind = (cls.join(" ").match(/kind-(\w+)/) || [])[1] || "";
      var status = (cls.join(" ").match(/status-(\w+)/) || [])[1] || "";
      // Run aggregates: a repeat's execution count, and a fan-out's per-state
      // child tally ("2 completed · 1 failed") — rendered only when present.
      var extra = "";
      if (d.repetitions) extra += '<div class="mt-0.5 text-zinc-500">' + esc(d.repetitions) + " repetition" + (d.repetitions === 1 ? "" : "s") + "</div>";
      if (d.counts) {
        var parts = Object.keys(d.counts).map(function (k) { return esc(d.counts[k]) + " " + esc(k); });
        if (parts.length) extra += '<div class="mt-0.5 text-zinc-500">' + parts.join(" &middot; ") + "</div>";
      }
      detail.innerHTML =
        '<div class="font-medium text-zinc-800">' + esc(d.label || d.id) + "</div>" +
        '<div class="text-zinc-500">' + esc(kind) + (status ? ' &middot; <span class="font-medium">' + esc(status.replace("_", " ")) + "</span>" : "") + "</div>" +
        (d.step_name ? '<div class="mt-0.5 font-mono text-[11px] text-zinc-500">' + esc(d.step_name) + "</div>" : "") +
        extra;
    }
  });
  cy.on("tap", "edge", function (evt) {
    var g = evt.target.data("label");
    if (detail) {
      detail.innerHTML = g && g.length
        ? '<div class="text-zinc-500">guard</div><div class="font-mono text-[11px] text-zinc-700">' + esc(g) + "</div>"
        : '<span class="text-zinc-400">unconditional edge</span>';
    }
  });
  cy.on("tap", function (evt) { if (evt.target === cy) clearFocus(); });
  hint();
})();

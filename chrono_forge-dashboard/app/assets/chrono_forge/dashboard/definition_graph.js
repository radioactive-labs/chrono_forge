// Renders the workflow definition DAG with Cytoscape + dagre layout. Reads the
// graph as JSON from #cf-graph[data-graph] (structured elements, no text grammar)
// and paints kind (shape) + run status (color) per node. Interactive: pan/zoom,
// and tapping a node shows its details and highlights its neighborhood.
(function () {
  var el = document.getElementById("cf-graph");
  if (!el || typeof cytoscape === "undefined") return;
  if (window.cytoscapeDagre) {
    try { cytoscape.use(window.cytoscapeDagre); } catch (e) { /* already registered */ }
  }

  var graph;
  try { graph = JSON.parse(el.getAttribute("data-graph")); } catch (e) { return; }

  // Node shape per durable kind (echoes the old Mermaid vocabulary).
  var SHAPE = {
    execute: "round-rectangle", wait: "barrel", wait_until: "hexagon",
    continue_if: "diamond", branch: "rhomboid", merge: "tag",
    repeat: "cut-rectangle", join: "ellipse", dynamic: "round-rectangle",
    endpoint: "round-tag"
  };
  // Fill / stroke per run status.
  var COLOR = {
    done: ["#dcfce7", "#16a34a"], active: ["#dbeafe", "#2563eb"],
    pending: ["#f4f4f5", "#a1a1aa"], not_reached: ["#ffffff", "#d4d4d8"],
    failed: ["#fee2e2", "#dc2626"], stalled: ["#fed7aa", "#d97706"],
    unmapped: ["#f5f5f4", "#a8a29e"]
  };

  var style = [
    {
      selector: "node",
      style: {
        "label": "data(label)", "font-size": "10px", "text-wrap": "wrap",
        "text-max-width": "140px", "text-valign": "center", "text-halign": "center",
        "width": "label", "height": "label", "padding": "8px",
        "border-width": 1.5, "background-color": "#fff", "border-color": "#d4d4d8",
        "color": "#27272a"
      }
    },
    {selector: "edge", style: {
      "label": "data(label)", "font-size": "8px", "color": "#71717a",
      "curve-style": "bezier", "width": 1.2, "line-color": "#a1a1aa",
      "target-arrow-shape": "triangle", "target-arrow-color": "#a1a1aa",
      "arrow-scale": 0.8, "text-background-color": "#fff",
      "text-background-opacity": 1, "text-background-padding": "2px",
      // Long guard text is truncated on the edge (full text shows on tap) so
      // labels of edges leaving the same node don't overlap.
      "text-max-width": "110px", "text-wrap": "ellipsis", "text-events": "yes"
    }},
    {selector: "edge.kind-terminal", style: {"line-style": "dashed", "line-color": "#dc2626", "target-arrow-color": "#dc2626"}},
    {selector: "node.dim", style: {"opacity": 0.25}},
    {selector: "edge.dim", style: {"opacity": 0.15}},
    {selector: "node.focus", style: {"border-width": 3}}
  ];
  Object.keys(SHAPE).forEach(function (k) {
    style.push({selector: "node.kind-" + k, style: {"shape": SHAPE[k]}});
  });
  Object.keys(COLOR).forEach(function (s) {
    style.push({selector: "node.status-" + s, style: {
      "background-color": COLOR[s][0], "border-color": COLOR[s][1]
    }});
  });
  // Endpoints (start/halt) read as small neutral pills.
  style.push({selector: "node.kind-endpoint", style: {
    "background-color": "#27272a", "border-color": "#27272a", "color": "#fff", "font-size": "9px"
  }});

  var cy = cytoscape({
    container: el,
    elements: graph,
    style: style,
    layout: {name: "dagre", rankDir: "TB", nodeSep: 28, rankSep: 42, edgeSep: 10},
    minZoom: 0.2, maxZoom: 2.5, wheelSensitivity: 0.3
  });

  var detail = document.getElementById("cf-graph-detail");
  function clearFocus() {
    cy.elements().removeClass("dim focus");
    if (detail) detail.innerHTML = '<span class="text-zinc-400">Tap a node or edge to inspect it.</span>';
  }
  cy.on("tap", "node", function (evt) {
    var n = evt.target;
    var hood = n.closedNeighborhood();
    cy.elements().addClass("dim");
    hood.removeClass("dim");
    cy.nodes().removeClass("focus");
    n.addClass("focus");
    if (detail) {
      var d = n.data(), cls = (n.classes() || []).join(" ");
      var kind = (cls.match(/kind-(\w+)/) || [])[1] || "";
      var status = (cls.match(/status-(\w+)/) || [])[1] || "";
      detail.innerHTML =
        '<div class="font-medium text-zinc-800">' + (d.label || d.id) + "</div>" +
        '<div class="text-zinc-500">kind: ' + kind + (status ? " &middot; status: " + status : "") + "</div>" +
        (d.step_name ? '<div class="font-mono text-[11px] text-zinc-500">' + d.step_name + "</div>" : "");
    }
  });
  cy.on("tap", "edge", function (evt) {
    var g = evt.target.data("label");
    if (detail) {
      detail.innerHTML = g && g.length
        ? '<div class="text-zinc-500">guard:</div><div class="font-mono text-[11px] text-zinc-700">' + g + "</div>"
        : '<span class="text-zinc-400">unconditional edge</span>';
    }
  });
  cy.on("tap", function (evt) { if (evt.target === cy) clearFocus(); });
  clearFocus();
})();

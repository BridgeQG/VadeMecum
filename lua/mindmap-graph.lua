-- Functions

local function parse_dsl_string(str)
    local name, attr_str = str:match("^(.-)%s*%{(.+)%}%s*$")
    if not name then
        name = str
        attr_str = ""
    end
    name = name:match("^%s*(.-)%s*$")

    local attrs = {}
    if attr_str ~= "" then
        for k, v in attr_str:gmatch("(%w[%w%-]+)%s*:%s*([^,]+)") do
            attrs[k] = v:match("^%s*['\"]?(.-)['\"]?%s*$")
        end
    end
    return name, attrs
end

local function parse_file_metadata(filepath)
    local f = io.open(filepath, "r")
    if not f then return nil, nil end
    local content = f:read("*a")
    f:close()

    local meta = {}
    local yaml_block = content:match("^%-%-%-\n(.-)\n%-%-%-")

    if yaml_block then
        -- Read the YAML block line by line to avoid missing the last line
        for line in yaml_block:gmatch("[^\r\n]+") do
            if line:match("^title:") then
                meta.title = line:match("^title:%s*['\"]?(.-)['\"]?%s*$")
            elseif line:match("^mindmap%-shape:") then
                meta.shape = line:match("shape:%s*['\"]?(.-)['\"]?%s*$")
            elseif line:match("^mindmap%-status:") then
                meta.status = line:match("status:%s*['\"]?(.-)['\"]?%s*$")
            elseif line:match("^mindmap%-color:") then
                meta.color = line:match("color:%s*['\"]?(.-)['\"]?%s*$")
            end
        end
    end
    return meta, content
end

local function extract_internal_links(content)
    local links = {}

    local function process_target(link_target)
        if not link_target:match("^http") and not link_target:match("^#") then
            local base = link_target:match("([^/]+)%.html$") or link_target:match("([^/]+)%.qmd$")
            if base then table.insert(links, base) end
        end
    end

    -- Standard Markdown links: [text](target)
    for link_target in string.gmatch(content, "%[.-%]%(([^%)]+)%)") do
        process_target(link_target)
    end

    -- LaTeX href links: \href{target}{text}
    for link_target in string.gmatch(content, "\\href{([^}]+)}") do
        process_target(link_target)
    end

    return links
end

-- HTML renderer

local function generate_graph_html(nodes_db, edges_db)
    local function escape_js(str) return str and str:gsub("'", "\\'") or "null" end

    local nodes_js_arr = {}
    for id, attrs in pairs(nodes_db) do
        -- First-level topics are the pages directly in 1st-level-topics/ (second-level ones are in the subfolders 1st-level-topics/2nd-level-NAME/)
        local is_first = attrs.url and attrs.url:match("^1st%-level%-topics/[^/]+%.html$") ~= nil
        table.insert(nodes_js_arr, string.format(
            "{ id: '%s', url: %s, color: %s, shape: %s, level1: %s, status: %s }",
            escape_js(id),
            attrs.url and string.format("'%s'", escape_js(attrs.url)) or "null",
            attrs.color and string.format("'%s'", escape_js(attrs.color)) or "null",
            attrs.shape and string.format("'%s'", escape_js(attrs.shape)) or "'rounded'",
            is_first and "true" or "false",
            attrs.status and string.format("'%s'", escape_js(attrs.status)) or "null"
        ))
    end

    local links_js_arr = {}
    for _, edge in pairs(edges_db) do
        table.insert(links_js_arr, string.format("{ source: '%s', target: '%s' }", escape_js(edge.src), escape_js(edge.tgt)))
    end

    local graph_id = "graph_" .. tostring(math.random(100000, 999999))

    local html_code = [[
  <div id="wrapper_]] .. graph_id .. [[" style="position: relative; width: 100%; height: max(600px, calc(100vh - 220px)); border: 1px solid #ddd; background: #ffffff; border-radius: 8px; overflow: hidden; margin-bottom: 1.5em;">
      <div id="]] .. graph_id .. [[" style="width: 100%; height: 100%;"></div>
      <button id="btn_]] .. graph_id .. [[" title="Toggle Fullscreen" style="position: absolute; bottom: 15px; right: 15px; z-index: 1000; width: 36px; height: 36px; padding: 0; background: rgba(255, 255, 255, 0.9); border: 1px solid #ccc; border-radius: 6px; cursor: pointer; font-size: 20px; color: #333; box-shadow: 0 2px 5px rgba(0,0,0,0.2); display: flex; align-items: center; justify-content: center; transition: background 0.2s; line-height: 1;">⛶</button>
      <button id="heat_]] .. graph_id .. [[" title="Shuffle: shake the map so it can find a new arrangement" style="position: absolute; bottom: 15px; right: 59px; z-index: 1000; width: 36px; height: 36px; padding: 0; background: rgba(255, 255, 255, 0.9); border: 1px solid #ccc; border-radius: 6px; cursor: pointer; font-size: 20px; color: #333; box-shadow: 0 2px 5px rgba(0,0,0,0.2); display: flex; align-items: center; justify-content: center; line-height: 1;"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="8" y="4" width="8" height="16" rx="2"/><path d="M5 8q-2 4 0 8M2.5 6q-3 6 0 12M19 8q2 4 0 8M21.5 6q3 6 0 12"/></svg></button>
  </div>

  <script src="https://unpkg.com/force-graph"></script>
  <script>
    (function initGraph() {
      if (typeof ForceGraph === 'undefined') { setTimeout(initGraph, 50); return; }

      const graphData = {
        nodes: [ ]] .. table.concat(nodes_js_arr, ",\n          ") .. [[ ],
        links: [ ]] .. table.concat(links_js_arr, ",\n          ") .. [[ ]
      };

      // ---------------------------------------------------------------- parameters
      // Size of first-level balloons (rounded squares): minimum side = BASE + PER_LINK * linked pages.
      const L1_BASE_SIDE = 56;
      const L1_PER_LINK = 7;
      // Same bold font for every balloon; sizes are fixed in graph units (they scale with zoom)
      const FONT_SIZE = 12;
      const L2_WRAP_WIDTH = 110;
      // Forces
      const REPULSION = 60000;    // border-to-border repulsion between any two balloons
      const REPULSION_MAX = 12;   // upper limit of the repulsion force (keeps touching balloons from vibrating)
      // First-level <-> first-level: Van der Waals-like (Lennard-Jones-like) force on the border-to-border
      // distance: repulsive closer than L1_R0, attractive beyond it, with a long tail (falls off as 1/d^2)
      const L1_R0 = 170;          // distance (border to border) at which the force changes sign
      const L1_EPS = 40;          // strength
      const BOX_GAP = 10;         // minimum gap kept between boxes
      const LINK_GAP = 12;        // preferred gap (border to border) between a topic and its first-level parent
      const LINK_OWN = 0.5;       // spring strength of first-level <-> second-level links (they shape the map)
      const LINK_TOP = 0.03;      // ... of first-level <-> first-level links
      const LINK_CROSS = 0.02;    // ... of all other links (second-level <-> second-level, ...)
      const GRAVITY = 0.04;       // pull towards the centre
      // Dissipation and thermal agitation (annealing)
      const WARM_TICKS = 300;     // initial relaxation, with low friction, done before the first frame
      const DAMPING = 0.85;       // friction afterwards: 0 = none, 1 = frozen (library default 0.4)
      const MAX_SPEED = 6;        // speed limit per tick
      const ALPHA_FLOOR = 0.2;    // the simulation never stops: forces never drop below this level
      const T_HIGH = 1.5;         // short agitation after a balloon has been moved
      const T_SHUFFLE = 2;        // agitation after the shuffle kick
      const T_OFF = 0.03;         // below this the agitation is switched off completely
      const COOL_TICKS = 120;     // time constant of the cooling (about 60 ticks per second)
      const NOISE_CORR = 0.96;    // memory of the random force from one tick to the next (higher = smoother)
      // Shuffle button
      const SHAKE_CANDIDATES = 12;// arrangements tried offline
      const SHAKE_BUDGET_MS = 900;// never spend more than this on the search (after the first four)
      const SHAKE_KICK = 0.45;    // ... for half of them the current map is displaced randomly by this (std. dev., fraction of the map size)
      const SHAKE_JOLT = 0.06;    // visible random jolt of every balloon when the button is pressed (fraction of the map size)
      const SHAKE_TICKS = 110;    // balloons are carried to the new arrangement for this many ticks ...
      const SHAKE_PULL = 0.3;     // ... with this pull (per unit distance)
      // Mouse pointer: attracts the balloon under it and pushes the neighbouring ones away
      const MOUSE_ATTRACT = 0.35;  // pull of the balloon under the pointer towards the pointer (per unit distance)
      const MOUSE_ATTRACT_MAX = 5; // ... capped to this speed increment per tick
      const MOUSE_RADIUS = 60;     // balloons whose border is closer than this to the pointer are pushed away (screen pixels)
      const MOUSE_PUSH = 8;        // push strength at the border of the balloon under the pointer
      // Offline search for a good starting arrangement
      const RESTARTS = 12;           // number of random starts tried
      const POLISH_DAMPING = 0.5;    // friction during that polishing (lower than the live one: slow modes relax faster)
      const POLISH_ITERS = 3000;     // final relaxation of the chosen arrangement (stops early once at rest)
      const RELAX_ITERS = 350;       // relaxation steps for each
      const RESTART_BUDGET_MS = 1500; // never spend more than this (after the first three)

      // ---------------------------------------------------------------- structure of the map
      // First-level topics are the nodes flagged level1. Every other page is linked to 0-3 of them.
      const byId = {};
      graphData.nodes.forEach(n => { byId[n.id] = n; });
      const hasTops = graphData.nodes.some(n => n.level1);
      const parentsOf = {};   // page id -> ids of the first-level topics it is linked with
      const childCount = {};  // first-level id -> number of pages linked with it
      const nbrs = {};        // id -> Set of neighbour ids (for highlighting)
      const linkDeg = {};     // id -> number of links
      graphData.links.forEach(l => {
          const a = byId[l.source], b = byId[l.target];
          if (!a || !b) { l.kind = 'cross'; return; }
          if (!nbrs[a.id]) nbrs[a.id] = new Set();
          if (!nbrs[b.id]) nbrs[b.id] = new Set();
          nbrs[a.id].add(b.id); nbrs[b.id].add(a.id);
          linkDeg[a.id] = (linkDeg[a.id] || 0) + 1; linkDeg[b.id] = (linkDeg[b.id] || 0) + 1;
          if (!hasTops) { l.kind = 'own'; return; }   // manual graphs: every link shapes the map
          if (a.level1 && b.level1) { l.kind = 'top'; return; }
          if (!a.level1 && !b.level1) { l.kind = 'cross'; return; }
          l.kind = 'own';
          const p = a.level1 ? a : b, c = a.level1 ? b : a;
          if (!parentsOf[c.id]) parentsOf[c.id] = [];
          if (parentsOf[c.id].indexOf(p.id) < 0) {
              parentsOf[c.id].push(p.id);
              childCount[p.id] = (childCount[p.id] || 0) + 1;
          }
      });

      const wrapper = document.getElementById('wrapper_]] .. graph_id .. [[');
      const container = document.getElementById(']] .. graph_id .. [[');
      const fsBtn = document.getElementById('btn_]] .. graph_id .. [[');
      const heatBtn = document.getElementById('heat_]] .. graph_id .. [[');
      if (!wrapper || !container || !fsBtn || !heatBtn) return;

      // Fullscreen Toggle Logic now targets the WRAPPER
      fsBtn.addEventListener('click', () => {
          if (!document.fullscreenElement) {
              wrapper.requestFullscreen().catch(err => console.log(err));
          } else {
              document.exitFullscreen();
          }
      });

      document.addEventListener('fullscreenchange', () => {
          if (document.fullscreenElement === wrapper) {
              fsBtn.innerHTML = '✖'; // Just an X when in fullscreen
              wrapper.style.borderRadius = '0px';
          } else {
              fsBtn.innerHTML = '⛶'; // Back to square when minimized
              wrapper.style.borderRadius = '8px';
          }
      });

      // text and border colours for the "mindmap-status" front-matter field
      const STATUS_STYLE = {
        'authors-unassigned': { text: '#c00000', border: '#d00000' },
        'work-in-progress':   { text: '#00703c', border: '#008a45' },
        'written':            { text: '#0b2f8a', border: '#0b2f8a' }
      };
      function getContrastColor(hexColor) {
          if (!hexColor) return '#000000';
          let hex = hexColor.replace('#', '');
          if (hex.length === 3) hex = hex[0]+hex[0]+hex[1]+hex[1]+hex[2]+hex[2];
          const r = parseInt(hex.substr(0, 2), 16);
          const g = parseInt(hex.substr(2, 2), 16);
          const b = parseInt(hex.substr(4, 2), 16);
          const yiq = ((r * 299) + (g * 587) + (b * 114)) / 1000;
          return (yiq >= 128) ? '#000000' : '#ffffff';
      }

      function drawShape(ctx, shape, x, y, w, h) {
          ctx.beginPath();
          if (shape === 'circle') {
              ctx.arc(x, y, Math.max(w, h)/2, 0, 2 * Math.PI);
          } else if (shape === 'square') {
              ctx.rect(x - w/2, y - h/2, w, h);
          } else {
              if (ctx.roundRect) ctx.roundRect(x - w/2, y - h/2, w, h, 8); else ctx.rect(x - w/2, y - h/2, w, h);
          }
          ctx.closePath();
      }

      // ---------------------------------------------------------------- size of the balloons
      // Lines of text and box size of every node, in graph units. Used for drawing, for the
      // forces, for the hover area and for click detection.
      const measureCtx = document.createElement('canvas').getContext('2d');
      measureCtx.font = `bold ${FONT_SIZE}px Sans-Serif`;

      function wrapText(text, maxWidth) {
          const words = text.split(' ');
          const lines = []; let curLine = words[0];
          for (let i = 1; i < words.length; i++) {
              if (measureCtx.measureText(curLine + " " + words[i]).width < maxWidth) curLine += " " + words[i];
              else { lines.push(curLine); curLine = words[i]; }
          }
          lines.push(curLine);
          return lines;
      }

      function layoutNode(node) {
          const lineHeight = FONT_SIZE * 1.2;
          const padding = FONT_SIZE * 1.1;
          const boxFor = lines => ({
              lines,
              w: Math.max(...lines.map(l => measureCtx.measureText(l).width)) + padding,
              h: lines.length * lineHeight + padding
          });

          let box;
          if (node.level1) {
              // First-level topics: rounded square. Try several wrapping widths and keep the one
              // giving the smallest square, so the text fills the box. The square then grows with
              // the number of pages linked with the topic.
              node.shape = 'rounded';
              let best = null;
              for (let maxW = 50; maxW <= 240; maxW += 5) {
                  const b = boxFor(wrapText(node.id, maxW));
                  const side = Math.max(b.w, b.h);
                  if (!best || side < best.side - 0.5) best = { b, side };
              }
              const minSide = L1_BASE_SIDE + L1_PER_LINK * (childCount[node.id] || 0);
              const side = Math.max(best.side, minSide);
              box = { lines: best.b.lines, w: side, h: side };
          } else {
              box = boxFor(wrapText(node.id, L2_WRAP_WIDTH));
              if (node.shape === 'circle') { const d = Math.max(box.w, box.h); box.w = d; box.h = d; }
          }
          box.lineHeight = lineHeight;
          node.__g = box;
          return box;
      }
      graphData.nodes.forEach(layoutNode);

      // Is the graph-space point (px, py) inside the balloon of this node?
      function insideNode(node, px, py) {
          const g = node.__g;
          if (!g || node.x === undefined) return false;
          const dx = px - node.x, dy = py - node.y;
          if (node.shape === 'circle') return dx*dx + dy*dy <= (g.w/2) * (g.w/2);
          return Math.abs(dx) <= g.w/2 && Math.abs(dy) <= g.h/2;
      }

      // ---------------------------------------------------------------- forces
      // Repulsion computed from the gap between the actual borders of the two balloons
      // (not between their centres); it falls off with the square of that gap.
      function fCharge(alpha0) {
          const alpha = Math.max(alpha0, ALPHA_FLOOR);
          const ns = graphData.nodes;
          for (let i = 0; i < ns.length; i++) {
              for (let j = i + 1; j < ns.length; j++) {
                  const a = ns[i], b = ns[j];
                  let dx = b.x - a.x, dy = b.y - a.y;
                  if (dx === 0 && dy === 0) { dx = Math.random() - 0.5; dy = Math.random() - 0.5; }
                  const gapX = Math.max(0, Math.abs(dx) - (a.__g.w + b.__g.w) / 2);
                  const gapY = Math.max(0, Math.abs(dy) - (a.__g.h + b.__g.h) / 2);
                  const gap = Math.hypot(gapX, gapY);
                  const len = Math.hypot(dx, dy);
                  let f;
                  if (a.level1 && b.level1) {
                      const x = L1_R0 / (gap + BOX_GAP);
                      f = Math.min(REPULSION_MAX, L1_EPS * alpha * (x * x * x - x * x));   // > 0 repulsive, < 0 attractive
                  } else {
                      // capped at close range: an unbounded repulsion is so stiff that touching balloons chatter
                      f = Math.min(REPULSION_MAX, REPULSION * alpha / ((gap + BOX_GAP) * (gap + BOX_GAP)));
                  }
                  const fx = f * dx / len, fy = f * dy / len;
                  a.vx -= fx; a.vy -= fy; b.vx += fx; b.vy += fy;
              }
          }
      }

      // Links are springs that want the two balloons a fixed gap apart, measured border to border.
      // First-level <-> second-level links are strong: a page linked to two or three topics ends up
      // between them, and the pages of one topic gather in a cloud around it.
      const springLinks = graphData.links
          .map(l => ({ a: byId[l.source], b: byId[l.target], kind: l.kind }))
          .filter(s => s.a && s.b);
      const linkRest = s => (Math.max(s.a.__g.w, s.a.__g.h) + Math.max(s.b.__g.w, s.b.__g.h)) / 2
          + (s.kind === 'own' ? LINK_GAP : 3 * LINK_GAP);
      const linkStrength = s => s.kind === 'own' ? LINK_OWN : s.kind === 'top' ? LINK_TOP : LINK_CROSS;
      function fSprings(alpha0) {
          const k = Math.max(alpha0, ALPHA_FLOOR);
          springLinks.forEach(s => {
              const dx = s.b.x - s.a.x, dy = s.b.y - s.a.y;
              const len = Math.hypot(dx, dy) || 1e-6;
              const f = (len - linkRest(s)) / len * k * linkStrength(s);
              // equal and opposite on both ends (the map never drifts as a whole)
              s.b.vx -= dx * f * 0.5; s.b.vy -= dy * f * 0.5;
              s.a.vx += dx * f * 0.5; s.a.vy += dy * f * 0.5;
          });
      }

      // Pull towards the centre, weaker along the longer side of the window
      function fGravity(alpha0) {
          const alpha = Math.max(alpha0, ALPHA_FLOOR);
          const aspect = Math.max(0.3, Math.min(3, wrapper.offsetWidth / Math.max(1, wrapper.offsetHeight)));
          const gx = GRAVITY / Math.max(1, aspect), gy = GRAVITY * Math.max(1, aspect);
          graphData.nodes.forEach(n => { n.vx -= n.x * gx * alpha; n.vy -= n.y * gy * alpha; });
      }

      // Boxes never overlap
      function fCollide() {
          const ns = graphData.nodes;
          for (let i = 0; i < ns.length; i++) {
              for (let j = i + 1; j < ns.length; j++) {
                  const a = ns[i], b = ns[j];
                  const dx = b.x - a.x, dy = b.y - a.y;
                  const ox = (a.__g.w + b.__g.w) / 2 + BOX_GAP - Math.abs(dx);
                  const oy = (a.__g.h + b.__g.h) / 2 + BOX_GAP - Math.abs(dy);
                  if (ox > 0 && oy > 0) {
                      if (ox < oy) { const s = (dx >= 0 ? 1 : -1) * ox * 0.8; a.vx -= s; b.vx += s; }
                      else { const s = (dy >= 0 ? 1 : -1) * oy * 0.8; a.vy -= s; b.vy += s; }
                  }
              }
          }
      }

      // ---------------------------------------------------------------- starting positions
      // First-level topics are dropped at random but spread uniformly over the window area (a random
      // sequential placement that keeps a minimum distance between them). Pages linked to a single
      // first-level topic start in a ring around it, pages linked to several start between their
      // topics, and the others anywhere.
      function placeNodes() {
          const W = Math.max(300, wrapper.offsetWidth), H = Math.max(300, wrapper.offsetHeight);
          const aspect = Math.max(0.6, Math.min(2.2, W / H));
          const R = 130 + 30 * Math.sqrt(graphData.nodes.length);
          const rx = R * Math.sqrt(aspect), ry = R / Math.sqrt(aspect);
          const tops = graphData.nodes.filter(n => n.level1);
          tops.forEach(t => { t.__ringPhase = Math.random() * 2 * Math.PI; });
          let dmin = 0.75 * Math.sqrt((4 * rx * ry) / Math.max(1, tops.length));
          const placed = [];
          tops.forEach(n => {
              let x, y, tries = 0;
              do {
                  x = (Math.random() * 2 - 1) * rx; y = (Math.random() * 2 - 1) * ry;
                  if (++tries % 40 === 0) dmin *= 0.9;   // too crowded: relax the requirement
              } while (placed.some(q => Math.hypot(q.x - x, q.y - y) < dmin) && tries < 2000);
              n.x = x; n.y = y; placed.push(n);
          });
          const seen = {};   // first-level id -> number of single-parent pages already placed
          const kids = {};
          graphData.nodes.forEach(n => {
              const ps = parentsOf[n.id];
              if (!n.level1 && ps && ps.length === 1) { const pid = ps[0]; kids[pid] = (kids[pid] || 0) + 1; }
          });
          graphData.nodes.forEach(n => {
              n.vx = 0; n.vy = 0;
              if (n.level1) return;
              const ps = parentsOf[n.id];
              if (ps && ps.length === 1) {
                  const pid1 = ps[0], p = byId[pid1];
                  const k = seen[p.id] = (seen[p.id] || 0) + 1;
                  const ang = 2 * Math.PI * (k / kids[p.id]) + (Math.random() - 0.5) * 0.8 + p.__ringPhase;
                  const rad = Math.max(p.__g.w, p.__g.h) / 2 + 50 + Math.random() * 70;
                  n.x = p.x + rad * Math.cos(ang); n.y = p.y + rad * Math.sin(ang);
              } else if (ps && ps.length) {
                  let sx = 0, sy = 0;
                  ps.forEach(id => { sx += byId[id].x; sy += byId[id].y; });
                  n.x = sx / ps.length + (Math.random() - 0.5) * 40;
                  n.y = sy / ps.length + (Math.random() - 0.5) * 40;
              } else {
                  n.x = (Math.random() * 2 - 1) * rx; n.y = (Math.random() * 2 - 1) * ry;
              }
          });
      }

      // The same forces as the live simulation, run offline (no drawing, no noise)
      // warmFrac: fraction of the iterations done with low friction before the final friction is used
      function relax(iters, warmFrac) {
          if (warmFrac === undefined) warmFrac = 0.6;
          let alpha = 1;
          for (let i = 0; i < iters; i++) {
              alpha *= 0.97;
              fCharge(alpha); fSprings(alpha); fGravity(alpha); fCollide();
              const keep = 1 - (i < iters * warmFrac ? 0.4 : (warmFrac === 0 ? POLISH_DAMPING : DAMPING));
              let vmax = 0;
              graphData.nodes.forEach(n => {
                  n.vx *= keep; n.vy *= keep;
                  const v = Math.hypot(n.vx, n.vy);
                  if (v > 60) { n.vx *= 60 / v; n.vy *= 60 / v; }
                  vmax = Math.max(vmax, v);
                  n.x += n.vx; n.y += n.vy;
              });
              if (warmFrac === 0 && vmax < 0.001) break;   // settled
          }
          graphData.nodes.forEach(n => { n.vx = 0; n.vy = 0; });
      }
      // Long relaxation with the final friction only: the soft, slow modes of the map are brought to
      // rest here, offline, so that the live map starts (and ends a shuffle) at rest.
      function polish() { relax(POLISH_ITERS, 0); }

      // Quality of an arrangement: crossing first-level links count most, then how far the links
      // are from their preferred length.
      function layoutCost() {
          const own = springLinks.filter(s => s.kind === 'own');
          const ccw = (ax, ay, bx, by, cx, cy) => (cy - ay) * (bx - ax) > (by - ay) * (cx - ax);
          let crossings = 0, stretch = 0;
          for (let i = 0; i < own.length; i++) {
              const p = own[i];
              stretch += Math.abs(Math.hypot(p.b.x - p.a.x, p.b.y - p.a.y) - linkRest(p));
              for (let j = i + 1; j < own.length; j++) {
                  const q = own[j];
                  if (p.a === q.a || p.a === q.b || p.b === q.a || p.b === q.b) continue;
                  if (ccw(p.a.x, p.a.y, q.a.x, q.a.y, q.b.x, q.b.y) !== ccw(p.b.x, p.b.y, q.a.x, q.a.y, q.b.x, q.b.y) &&
                      ccw(p.a.x, p.a.y, p.b.x, p.b.y, q.a.x, q.a.y) !== ccw(p.a.x, p.a.y, p.b.x, p.b.y, q.b.x, q.b.y)) crossings++;
              }
          }
          return crossings * 10000 + stretch;
      }

      // Try several starting arrangements offline and keep the best one: the first view is then
      // already a good arrangement, and the live simulation only has to keep it that way.
      (function solveInitial() {
          const t0 = performance.now();
          let best = null;
          for (let k = 0; k < RESTARTS && (k < 3 || performance.now() - t0 < RESTART_BUDGET_MS); k++) {
              placeNodes(k > 0);
              relax(RELAX_ITERS);
              const c = layoutCost();
              if (!best || c < best.c) best = { c, pos: graphData.nodes.map(n => [n.x, n.y]) };
          }
          graphData.nodes.forEach((n, i) => { n.x = best.pos[i][0]; n.y = best.pos[i][1]; n.vx = 0; n.vy = 0; });
          polish();
      })();

      // ---------------------------------------------------------------- the graph
      let hot = null;   // balloon being hovered or dragged: its links are highlighted
      let dragging = false;
      const isHotLink = l => hot && (l.source === hot || l.target === hot);

      const Graph = ForceGraph()(container)
        .graphData(graphData)
        // links: the structural ones (first-level <-> others) are darker, the rest is faint;
        // all links of the balloon under the pointer are highlighted and the rest is dimmed
        .linkColor(l => hot
            ? (isHotLink(l) ? (l.kind === 'top' ? '#e0457f' : '#111111') : (l.kind === 'top' ? 'rgba(236,98,146,0.15)' : 'rgba(0,0,0,0.06)'))
            : (l.kind === 'own' ? 'rgba(60,60,60,0.65)' : l.kind === 'top' ? 'rgba(236,98,146,0.85)' : 'rgba(0,0,0,0.13)'))
        .linkWidth(l => isHotLink(l) ? 2.6 : (l.kind === 'own' ? 1.6 : l.kind === 'top' ? 1.6 : 0.8))
        .linkDirectionalParticles(l => isHotLink(l) ? 3 : 0)
        .linkDirectionalParticleWidth(3.5)
        // lets zoomToFit take the real size of the balloons into account
        .nodeVal(n => { const r = Math.max(n.__g.w, n.__g.h) * 0.7 / 4; return r * r; })
        .nodeCanvasObject((node, ctx, globalScale) => {
          const g = node.__g;

          const bgColor = node.color || '#84cfff';
          // "mindmap-status" in the front matter sets the text and border colour
          const st = STATUS_STYLE[node.status];
          const fgColor = st ? st.text : getContrastColor(bgColor);
          const dim = hot && node !== hot && !(nbrs[hot.id] && nbrs[hot.id].has(node.id));

          ctx.globalAlpha = dim ? 0.3 : 1;
          ctx.fillStyle = bgColor;
          ctx.strokeStyle = st ? st.border : '#333333';
          ctx.lineWidth = (st ? 2.5 : 1.5) / Math.max(globalScale, 1);

          drawShape(ctx, node.shape, node.x, node.y, g.w, g.h);
          ctx.fill(); ctx.stroke();

          ctx.font = `bold ${FONT_SIZE}px Sans-Serif`;
          ctx.textAlign = 'center'; ctx.textBaseline = 'middle'; ctx.fillStyle = fgColor;
          const startY = node.y - (g.lines.length * g.lineHeight)/2 + g.lineHeight/2;
          g.lines.forEach((line, i) => ctx.fillText(line, node.x, startY + i * g.lineHeight));
          ctx.globalAlpha = 1;
        })
        // The hover area is exactly the drawn balloon (used for the pointer cursor)
        .nodePointerAreaPaint((node, color, ctx) => {
          const g = node.__g;
          ctx.fillStyle = color;
          drawShape(ctx, node.shape, node.x, node.y, g.w, g.h);
          ctx.fill();
        })
        .onNodeHover(node => { if (!dragging) hot = node; container.style.cursor = node && node.url ? 'pointer' : null; })
        .onNodeDrag(node => { dragging = true; hot = node; })
        .onNodeDragEnd(() => { dragging = false; heat(T_HIGH); });

      // ---------------------------------------------------------------- forces
      let tick = 0, heatStart = 0, heatPeak = 0, currentT = 0;
      function heat(peak) { heatStart = Math.max(tick, WARM_TICKS); heatPeak = peak; }
      function gauss() {
          let u = 0, v = 0;
          while (!u) u = Math.random();
          while (!v) v = Math.random();
          return Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
      }

      // Brownian agitation: only a transient (after load, after a balloon was moved, after shuffle).
      // It cools exponentially and is switched off completely, so a settled map stays still.
      Graph.d3Force('thermal', () => {
          tick++;
          if (tick === WARM_TICKS) Graph.d3VelocityDecay(DAMPING);
          currentT = tick < WARM_TICKS ? 0 : heatPeak * Math.exp(-(tick - heatStart) / COOL_TICKS);
          if (currentT < T_OFF) {
              currentT = 0;
              if (tick >= WARM_TICKS && heatPeak > 0) { heatPeak = 0; graphData.nodes.forEach(n => { n.__nx = 0; n.__ny = 0; }); }
              return;
          }
          // the random force of each balloon changes slowly (correlated noise): smooth wandering, no vibration
          const c = NOISE_CORR, q = Math.sqrt(1 - c * c) * currentT;
          graphData.nodes.forEach(n => {
              n.__nx = c * (n.__nx || 0) + q * gauss();
              n.__ny = c * (n.__ny || 0) + q * gauss();
              n.vx += n.__nx; n.vy += n.__ny;
          });
      });

      // Mouse pointer force (mouse only, not on touch screens, not while panning):
      // the balloon under the pointer is pulled towards it (so it is "trapped" and easy to hit),
      // and the balloons whose border is within MOUSE_RADIUS of the pointer are pushed away from it.
      let mouse = null;   // pointer position in screen coordinates inside the map, or null
      let panning = false;
      container.addEventListener('pointermove', ev => {
          if (ev.pointerType !== 'mouse') { mouse = null; return; }
          const r = container.getBoundingClientRect();
          mouse = { x: ev.clientX - r.left, y: ev.clientY - r.top };
      }, true);
      container.addEventListener('pointerleave', () => { mouse = null; }, true);
      container.addEventListener('pointerdown', () => { if (!hot) panning = true; }, true);
      window.addEventListener('pointerup', () => { panning = false; }, true);
      Graph.d3Force('mouse', () => {
          if (!mouse || panning || tick < WARM_TICKS) return;
          const p = Graph.screen2GraphCoords(mouse.x, mouse.y);
          const nodes = graphData.nodes;
          // radius and strength are meant in screen terms: they grow when the map is zoomed out
          const s = 1 / Math.max(Graph.zoom(), 0.1), R = MOUSE_RADIUS * s;
          let under = null;
          for (let i = nodes.length - 1; i >= 0; i--) if (insideNode(nodes[i], p.x, p.y)) { under = nodes[i]; break; }
          nodes.forEach(n => {
              if (n.fx != null) return;   // balloon being dragged
              if (n === under) {
                  let dx = p.x - n.x, dy = p.y - n.y;
                  const d = Math.hypot(dx, dy), f = Math.min(MOUSE_ATTRACT * d, MOUSE_ATTRACT_MAX * s);
                  if (d > 0) { n.vx += dx / d * f; n.vy += dy / d * f; }
                  return;
              }
              // distance from the pointer to the border of the balloon (0 inside)
              const ex = Math.max(Math.abs(p.x - n.x) - n.__g.w / 2, 0);
              const ey = Math.max(Math.abs(p.y - n.y) - n.__g.h / 2, 0);
              const gap = Math.hypot(ex, ey);
              if (gap >= R) return;
              let dx = n.x - p.x, dy = n.y - p.y;
              let d = Math.hypot(dx, dy);
              if (d === 0) { dx = Math.random() - 0.5; dy = Math.random() - 0.5; d = Math.hypot(dx, dy); }
              const f = MOUSE_PUSH * s * (1 - gap / R) * (under ? 1 : 0.5);
              n.vx += dx / d * f; n.vy += dy / d * f;
          });
      });

      // Shuffle: a violent shake. Throwing the balloons about at random and letting them fall back
      // would almost always end in a worse arrangement, so the shake works in two steps: several
      // completely different arrangements are relaxed offline (half of them from a fresh random start,
      // half from a violent kick of the current map) and the best one that differs clearly from the
      // current map is chosen; then the balloons are thrown about and carried there.
      let shakeTarget = null, shakeUntil = 0;
      function shake() {
          const nodes = graphData.nodes;
          const cur = nodes.map(n => [n.x, n.y]);
          let x0 = Infinity, x1 = -Infinity, y0 = Infinity, y1 = -Infinity;
          cur.forEach(p => { x0 = Math.min(x0, p[0]); x1 = Math.max(x1, p[0]); y0 = Math.min(y0, p[1]); y1 = Math.max(y1, p[1]); });
          const size = Math.max(x1 - x0, y1 - y0, 300);
          const meanDisp = pos => pos.reduce((s, p, i) => s + Math.hypot(p[0] - cur[i][0], p[1] - cur[i][1]), 0) / pos.length;
          const t0 = performance.now();
          let best = null;
          for (let k = 0; k < SHAKE_CANDIDATES && (k < 4 || performance.now() - t0 < SHAKE_BUDGET_MS); k++) {
              if (k % 2 === 0) placeNodes(true);
              else nodes.forEach((n, i) => { n.x = cur[i][0] + gauss() * SHAKE_KICK * size; n.y = cur[i][1] + gauss() * SHAKE_KICK * size; });
              nodes.forEach(n => { n.vx = 0; n.vy = 0; });
              relax(RELAX_ITERS);
              const pos = nodes.map(n => [n.x, n.y]);
              if (meanDisp(pos) < 0.1 * size) continue;   // too close to where it already is
              const c = layoutCost();
              if (!best || c < best.c) best = { c, pos };
          }
          if (best) { nodes.forEach((n, i) => { n.x = best.pos[i][0]; n.y = best.pos[i][1]; }); polish(); best.pos = nodes.map(n => [n.x, n.y]); }
          nodes.forEach((n, i) => {
              n.x = cur[i][0] + gauss() * SHAKE_JOLT * size; n.y = cur[i][1] + gauss() * SHAKE_JOLT * size;
              n.vx = 0; n.vy = 0;
          });
          if (best) { shakeTarget = best.pos; shakeUntil = tick + SHAKE_TICKS; }
          heat(T_SHUFFLE);
      }
      Graph.d3Force('shakeTo', () => {
          if (!shakeTarget) return;
          if (tick > shakeUntil) { shakeTarget = null; return; }
          graphData.nodes.forEach((n, i) => {
              n.vx += (shakeTarget[i][0] - n.x) * SHAKE_PULL; n.vy += (shakeTarget[i][1] - n.y) * SHAKE_PULL;
          });
      });

      // The shape-giving forces are defined above (the library's own link force is switched off)
      Graph.d3Force('link').strength(0);
      Graph.d3Force('center', null);
      // The live forces ignore the library's cooling parameter (alpha, which starts at 1 and would shake
      // the carefully relaxed starting arrangement): they always act at the floor level.
      Graph.d3Force('charge', () => fCharge(0));
      Graph.d3Force('springs', () => fSprings(0));
      Graph.d3Force('gravity', () => fGravity(0));
      Graph.d3Force('boxCollide', fCollide);

      // No balloon moves faster than MAX_SPEED (plus what the current agitation allows)
      Graph.d3Force('speedLimit', () => {
          if (tick < WARM_TICKS) return;
          const lim = MAX_SPEED + 3 * currentT;
          graphData.nodes.forEach(n => {
              const v = Math.hypot(n.vx, n.vy);
              if (v > lim) { n.vx *= lim / v; n.vy *= lim / v; }
          });
      });

      // Relaxation before the first frame with low friction, then heavy damping; never fully cool down
      Graph.d3VelocityDecay(0.4).d3AlphaDecay(0.04).d3AlphaMin(0);
      Graph.warmupTicks(WARM_TICKS).cooldownTime(Infinity).cooldownTicks(Infinity);
      Graph.minZoom(0.2);   // (no agitation at load: the starting arrangement is already at rest)

      // Zoom so that the whole map fills the window. The map keeps being re-fitted while it settles,
      // until you zoom or pan yourself; the shuffle button switches this on again.
      let autoFit = true;
      let firstTick = true;
      Graph.onEngineTick(() => { if (firstTick) { firstTick = false; Graph.zoomToFit(0, 25); } });
      setInterval(() => { if (autoFit && !dragging) Graph.zoomToFit(600, 25); }, 700);
      container.addEventListener('wheel', () => { autoFit = false; }, { passive: true });
      container.addEventListener('pointerdown', () => { if (!hot) panStart = true; }, true);
      container.addEventListener('pointermove', () => { if (panStart) { autoFit = false; } }, true);
      container.addEventListener('pointerup', () => { panStart = false; }, true);
      container.addEventListener('touchstart', ev => { if (ev.touches.length > 1) autoFit = false; }, { passive: true });
      let panStart = false;
      heatBtn.addEventListener('click', () => { shake(); autoFit = true; });
      new ResizeObserver(() => { Graph.width(wrapper.offsetWidth); Graph.height(wrapper.offsetHeight); }).observe(wrapper);

      // Click / tap: open the page of the balloon under the pointer in a new tab.
      // Hit-testing is done here (instead of relying on hover) so that taps work on touch screens.
      // The topmost balloon wins, so only the exposed part of an overlapped balloon counts.
      let downPos = null;
      container.addEventListener('pointerdown', ev => { downPos = { x: ev.clientX, y: ev.clientY }; }, true);
      container.addEventListener('click', ev => {
          // Ignore drags (panning the map or moving a balloon)
          const moved = downPos && Math.hypot(ev.clientX - downPos.x, ev.clientY - downPos.y) > 6;
          downPos = null;
          if (moved) return;
          const rect = container.getBoundingClientRect();
          const p = Graph.screen2GraphCoords(ev.clientX - rect.left, ev.clientY - rect.top);
          const nodes = graphData.nodes;
          for (let i = nodes.length - 1; i >= 0; i--) {
              if (insideNode(nodes[i], p.x, p.y)) {
                  if (nodes[i].url) window.open(nodes[i].url, '_blank');
                  return;
              }
          }
      });

      if (window.__BQG_DEBUG) window.__bqg = { Graph, graphData, heat, shake, parentsOf, childCount, getTick: () => tick, getT: () => currentT, layoutCost, setMouse: m => { mouse = m; }, getMouse: () => mouse, polish };
    })();
  </script>
    ]]
    return pandoc.RawBlock("html", html_code)
end

-- Graph processors

local function process_manual_graph(raw_text)
    local nodes_db = {}
    local edges_db = {}

    local function register_node(id, attrs)
        if not id or id == "" then return end
        if not nodes_db[id] then nodes_db[id] = {} end
        for k, v in pairs(attrs) do
            if not nodes_db[id][k] and v ~= "" then nodes_db[id][k] = v end
        end
    end

    local function add_edge(src, tgt)
        if not src or not tgt or src == "" or tgt == "" then return end
        local key = src .. "->" .. tgt
        if not edges_db[key] then edges_db[key] = { src = src, tgt = tgt } end
    end

    for line in string.gmatch(raw_text, "[^\r\n]+") do
        local src_str, tgt_str = string.match(line, "(.-)%s*->%s*(.*)")
        if src_str and tgt_str then
            local src_name, src_attrs = parse_dsl_string(src_str)
            local tgt_name, tgt_attrs = parse_dsl_string(tgt_str)
            register_node(src_name, src_attrs)
            register_node(tgt_name, tgt_attrs)
            add_edge(src_name, tgt_name)
        else
            local name, attrs = parse_dsl_string(line)
            if name and name ~= "" then register_node(name, attrs) end
        end
    end

    return generate_graph_html(nodes_db, edges_db)
end

local function process_auto_folder(folder_path)
    local nodes_db = {}
    local edges_db = {}
    local scanned_files = {}
    local file_to_id = {}

    local function register_node(id, attrs)
        if not id or id == "" then return end
        if not nodes_db[id] then nodes_db[id] = {} end
        for k, v in pairs(attrs) do
            if not nodes_db[id][k] and v ~= "" then nodes_db[id][k] = v end
        end
    end

    local function add_edge(src, tgt)
        if not src or not tgt or src == "" or tgt == "" then return end
        local key = src .. "->" .. tgt
        if not edges_db[key] then edges_db[key] = { src = src, tgt = tgt } end
    end

    local project_root = os.getenv("QUARTO_PROJECT_DIR") or "."
    local os_target_dir = project_root .. "/" .. folder_path

    local cmd = 'find "' .. os_target_dir .. '" -type f -name "*.qmd" 2>/dev/null'
    local handle = io.popen(cmd)
    if not handle then return generate_graph_html(nodes_db, edges_db) end
    local result = handle:read("*a")
    handle:close()

    for filepath in string.gmatch(result, "[^\r\n]+") do
        local meta, content = parse_file_metadata(filepath)
        if content then
            local filename = filepath:match("([^/]+)$")

            -- Use filename as fallback
            -- local node_id = meta.title or filename

            -- Only process files that have a title
            local node_id = meta.title

            if node_id and node_id ~= "" then
                local rel_path = filepath
                if project_root ~= "." then
                    local safe_root = project_root:gsub("([%-%.%+%[%]%(%)%$%^%%%?%*])", "%%%1")
                    rel_path = filepath:gsub("^" .. safe_root .. "/?", "")
                else
                    rel_path = filepath:gsub("^%./", "")
                end
                local url = rel_path:gsub("%.qmd$", ".html")

                register_node(node_id, { url = url, shape = meta.shape, color = meta.color, status = meta.status })

                local base_filename = filename:gsub("%.qmd$", "")
                file_to_id[base_filename] = node_id
                table.insert(scanned_files, { id = node_id, content = content })
            end
        end
    end

    for _, file_data in ipairs(scanned_files) do
        local links = extract_internal_links(file_data.content)
        for _, target_base in ipairs(links) do
            local target_id = file_to_id[target_base]
            if target_id then add_edge(file_data.id, target_id) end
        end
    end

    return generate_graph_html(nodes_db, edges_db)
end

-- Main functions

return {

    -- Manual graph
    CodeBlock = function(el)
        if el.classes:includes("mindmap-graph") then
            return process_manual_graph(el.text)
        end
    end,

    -- Automatic graph generation from folder
    Para = function(el)
        local full_text = pandoc.utils.stringify(el)
        local folder_path = full_text:match("^!mindmap%-graph%-auto:%s*(.+)$")
        if folder_path then
            return process_auto_folder(folder_path)
        end
    end

}

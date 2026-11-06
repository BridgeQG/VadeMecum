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
        -- First-level topics live in doc/, second-level ones in doc/2ndlevel/
        local is_first = attrs.url and not attrs.url:find("2ndlevel/", 1, true)
        table.insert(nodes_js_arr, string.format(
            "{ id: '%s', url: %s, color: %s, shape: %s, level1: %s }",
            escape_js(id),
            attrs.url and string.format("'%s'", escape_js(attrs.url)) or "null",
            attrs.color and string.format("'%s'", escape_js(attrs.color)) or "null",
            attrs.shape and string.format("'%s'", escape_js(attrs.shape)) or "'rounded'",
            is_first and "true" or "false"
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
  </div>

  <script src="https://unpkg.com/force-graph"></script>
  <script>
    (function initGraph() {
      if (typeof ForceGraph === 'undefined') { setTimeout(initGraph, 50); return; }

      const graphData = {
        nodes: [ ]] .. table.concat(nodes_js_arr, ",\n          ") .. [[ ],
        links: [ ]] .. table.concat(links_js_arr, ",\n          ") .. [[ ]
      };

      // Number of links leaving each node (computed before force-graph rewrites the links).
      // For a first-level page this is the number of topics it links to.
      const outDegree = {};
      graphData.links.forEach(l => { outDegree[l.source] = (outDegree[l.source] || 0) + 1; });

      // Size of first-level balloons (rounded squares): minimum side = BASE + PER_LINK * links.
      // Tune these numbers to make them bigger/smaller or the differences stronger.
      const L1_BASE_SIDE = 56;
      const L1_PER_LINK = 7;
      // Same bold font for every balloon; sizes are fixed in graph units (they scale with zoom)
      const FONT_SIZE = 12;
      const L2_WRAP_WIDTH = 110;
      // Forces: border-to-border repulsion, minimum gap between boxes, pull towards the centre
      const REPULSION = 60000;  // strength of the border-to-border repulsion
      const LINK_GAP = 40;      // preferred gap between the borders of linked balloons
      const BOX_GAP = 10;
      const GRAVITY = 0.04;

      const wrapper = document.getElementById('wrapper_]] .. graph_id .. [[');
      const container = document.getElementById(']] .. graph_id .. [[');
      const fsBtn = document.getElementById('btn_]] .. graph_id .. [[');
      if (!wrapper || !container || !fsBtn) return;

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

      // Computes (and stores on the node) the lines of text and the size of the balloon,
      // in graph units. Used for drawing, for the hover area and for click detection.
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
              // the number of topics the page links to.
              node.shape = 'rounded';
              let best = null;
              for (let maxW = 50; maxW <= 240; maxW += 5) {
                  const b = boxFor(wrapText(node.id, maxW));
                  const side = Math.max(b.w, b.h);
                  if (!best || side < best.side - 0.5) best = { b, side };
              }
              const minSide = L1_BASE_SIDE + L1_PER_LINK * (outDegree[node.id] || 0);
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

      const Graph = ForceGraph()(container)
        .graphData(graphData)
        .linkDirectionalParticles(2)
        .linkColor(() => '#cccccc')
        .nodeCanvasObject((node, ctx, globalScale) => {
          const g = node.__g;

          const bgColor = node.color || '#84cfff';
          const fgColor = getContrastColor(bgColor);

          ctx.fillStyle = bgColor;
          ctx.strokeStyle = '#333333';
          ctx.lineWidth = 1.5 / Math.max(globalScale, 1);

          drawShape(ctx, node.shape, node.x, node.y, g.w, g.h);
          ctx.fill(); ctx.stroke();

          ctx.font = `bold ${FONT_SIZE}px Sans-Serif`;
          ctx.textAlign = 'center'; ctx.textBaseline = 'middle'; ctx.fillStyle = fgColor;
          const startY = node.y - (g.lines.length * g.lineHeight)/2 + g.lineHeight/2;
          g.lines.forEach((line, i) => ctx.fillText(line, node.x, startY + i * g.lineHeight));
        })
        // The hover area is exactly the drawn balloon (used for the pointer cursor)
        .nodePointerAreaPaint((node, color, ctx) => {
          const g = node.__g;
          ctx.fillStyle = color;
          drawShape(ctx, node.shape, node.x, node.y, g.w, g.h);
          ctx.fill();
        })
        .onNodeHover(node => container.style.cursor = node && node.url ? 'pointer' : null);

        // Layout forces: strong repulsion, no overlapping boxes, and a pull towards the centre that is
        // weaker along the longer side of the window, so the map spreads over the whole area.
        // Repulsion is computed from the gap between the actual borders of the two balloons
        // (not between their centres), and falls off with the square of that gap.
        Graph.d3Force('charge', alpha => {
            const ns = graphData.nodes;
            for (let i = 0; i < ns.length; i++) {
                for (let j = i + 1; j < ns.length; j++) {
                    const a = ns[i], b = ns[j];
                    let dx = b.x - a.x, dy = b.y - a.y;
                    const gapX = Math.max(0, Math.abs(dx) - (a.__g.w + b.__g.w) / 2);
                    const gapY = Math.max(0, Math.abs(dy) - (a.__g.h + b.__g.h) / 2);
                    const gap = Math.hypot(gapX, gapY);
                    const len = Math.hypot(dx, dy) || 1;
                    if (len === 1 && dx === 0 && dy === 0) { dx = Math.random() - 0.5; dy = Math.random() - 0.5; }
                    const f = REPULSION * alpha / ((gap + BOX_GAP) * (gap + BOX_GAP));
                    const fx = f * dx / len, fy = f * dy / len;
                    a.vx -= fx; a.vy -= fy; b.vx += fx; b.vy += fy;
                }
            }
        });
        // Links want their two balloons to be a fixed gap apart, measured border to border
        Graph.d3Force('link').distance(l => {
            const a = l.source.__g, b = l.target.__g;
            return (Math.max(a.w, a.h) + Math.max(b.w, b.h)) / 2 + LINK_GAP;
        });
        Graph.d3Force('center', null);
        Graph.d3Force('gravity', alpha => {
            const aspect = Math.max(0.3, Math.min(3, wrapper.offsetWidth / Math.max(1, wrapper.offsetHeight)));
            const gx = GRAVITY / Math.max(1, aspect), gy = GRAVITY * Math.max(1, aspect);
            graphData.nodes.forEach(n => { n.vx -= n.x * gx * alpha; n.vy -= n.y * gy * alpha; });
        });
        Graph.d3Force('boxCollide', alpha => {
            const ns = graphData.nodes;
            for (let i = 0; i < ns.length; i++) {
                for (let j = i + 1; j < ns.length; j++) {
                    const a = ns[i], b = ns[j];
                    const dx = b.x - a.x, dy = b.y - a.y;
                    const ox = (a.__g.w + b.__g.w) / 2 + BOX_GAP - Math.abs(dx);
                    const oy = (a.__g.h + b.__g.h) / 2 + BOX_GAP - Math.abs(dy);
                    if (ox > 0 && oy > 0) {
                        if (ox < oy) { const s = (dx >= 0 ? 1 : -1) * ox * 0.25; a.vx -= s; b.vx += s; }
                        else { const s = (dy >= 0 ? 1 : -1) * oy * 0.25; a.vy -= s; b.vy += s; }
                    }
                }
            }
        });
        Graph.warmupTicks(200).cooldownTime(4000);

        // Zoom so that the whole map fills the window (once the layout settles, and on resize)
        let fitTimer = null;
        const fitMap = () => { clearTimeout(fitTimer); fitTimer = setTimeout(() => Graph.zoomToFit(400, 25), 150); };
        Graph.onEngineStop(fitMap);
        Graph.minZoom(0.2);

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

        // ResizeObserver now watches the WRAPPER to rescale the graph
        new ResizeObserver(() => { Graph.width(wrapper.offsetWidth); Graph.height(wrapper.offsetHeight); fitMap(); }).observe(wrapper);
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

                register_node(node_id, { url = url, shape = meta.shape, color = meta.color })

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

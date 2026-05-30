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
        table.insert(nodes_js_arr, string.format(
            "{ id: '%s', url: %s, color: %s, shape: %s }",
            escape_js(id),
            attrs.url and string.format("'%s'", escape_js(attrs.url)) or "null",
            attrs.color and string.format("'%s'", escape_js(attrs.color)) or "null",
            attrs.shape and string.format("'%s'", escape_js(attrs.shape)) or "'rounded'"
        ))
    end

    local links_js_arr = {}
    for _, edge in pairs(edges_db) do
        table.insert(links_js_arr, string.format("{ source: '%s', target: '%s' }", escape_js(edge.src), escape_js(edge.tgt)))
    end

    local graph_id = "graph_" .. tostring(math.random(100000, 999999))
    
    local html_code = [[
  <div id="]] .. graph_id .. [[" style="width: 100%; height: 600px; border: 1px solid #ddd; background: #ffffff; border-radius: 8px; overflow: hidden; position: relative; margin-bottom: 1.5em;"></div>
  
  <script src="https://unpkg.com/force-graph"></script>
  <script>
    (function initGraph() {
      if (typeof ForceGraph === 'undefined') { setTimeout(initGraph, 50); return; }
  
      const graphData = {
        nodes: [ ]] .. table.concat(nodes_js_arr, ",\n          ") .. [[ ],
        links: [ ]] .. table.concat(links_js_arr, ",\n          ") .. [[ ]
      };
  
      const container = document.getElementById(']] .. graph_id .. [[');
      if (!container) return;
  
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
          } else if (shape === 'diamond') {
              ctx.moveTo(x, y - h/2); ctx.lineTo(x + w/2, y); ctx.lineTo(x, y + h/2); ctx.lineTo(x - w/2, y);
          } else if (shape === 'triangle') {
              ctx.moveTo(x, y - h/2); ctx.lineTo(x + w/2, y + h/2); ctx.lineTo(x - w/2, y + h/2);
          } else if (shape === 'star') {
              const spikes = 5; const outerRadius = Math.max(w, h)/2; const innerRadius = outerRadius / 2;
              let rot = Math.PI / 2 * 3; let step = Math.PI / spikes;
              ctx.moveTo(x, y - outerRadius);
              for (let i = 0; i < spikes; i++) {
                  ctx.lineTo(x + Math.cos(rot) * outerRadius, y + Math.sin(rot) * outerRadius); rot += step;
                  ctx.lineTo(x + Math.cos(rot) * innerRadius, y + Math.sin(rot) * innerRadius); rot += step;
              }
          } else {
              if (ctx.roundRect) ctx.roundRect(x - w/2, y - h/2, w, h, 8); else ctx.rect(x - w/2, y - h/2, w, h);
          }
          ctx.closePath();
      }
  
      const Graph = ForceGraph()(container)
        .graphData(graphData)
        .linkDirectionalParticles(2)
        .linkColor(() => '#cccccc')
        .nodeCanvasObject((node, ctx, globalScale) => {
          const fontSize = 10 / globalScale;
          ctx.font = `bold ${fontSize}px Sans-Serif`;
          
          const label = node.id;
          const maxTextWidth = 100 / globalScale;
          const words = label.split(' ');
          let lines = []; let curLine = words[0];
          for (let i = 1; i < words.length; i++) {
              if (ctx.measureText(curLine + " " + words[i]).width < maxTextWidth) curLine += " " + words[i];
              else { lines.push(curLine); curLine = words[i]; }
          }
          lines.push(curLine);
  
          const lineHeight = fontSize * 1.2;
          const textWidth = Math.max(...lines.map(l => ctx.measureText(l).width));
          const padding = fontSize * 1.0;
          const boxW = textWidth + padding;
          const boxH = lines.length * lineHeight + padding;
          
          const bgColor = node.color || '#84cfff';
          const fgColor = getContrastColor(bgColor);
  
          ctx.fillStyle = bgColor;
          ctx.strokeStyle = '#333333';
          ctx.lineWidth = 1.5 / globalScale;
  
          drawShape(ctx, node.shape, node.x, node.y, boxW, boxH);
          ctx.fill(); ctx.stroke();
  
          ctx.textAlign = 'center'; ctx.textBaseline = 'middle'; ctx.fillStyle = fgColor;
          const startY = node.y - (lines.length * lineHeight)/2 + lineHeight/2;
          lines.forEach((line, i) => ctx.fillText(line, node.x, startY + i * lineHeight));
        })
        .onNodeClick(node => { if(node.url) window.location.href = node.url; })
        .onNodeHover(node => container.style.cursor = node && node.url ? 'pointer' : null);
        
        Graph.d3Force('charge').strength(-600);
        Graph.d3Force('link').distance(150);
  
        new ResizeObserver(() => { Graph.width(container.offsetWidth); Graph.height(container.offsetHeight); }).observe(container);
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
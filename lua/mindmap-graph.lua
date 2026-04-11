function CodeBlock(el)
  if el.classes:includes("mindmap-graph") then
    
    local raw_text = el.text
    
    local edges = {}
    local nodes_set = {}
    local node_urls = {}
    local node_colors = {}
    local node_shapes = {}
    local node_groups = {} 

    local function parse_node_str(str)
        local name, attr_str = str:match("^(.-)%s*%{(.+)%}%s*$")
        if not name then
            name = str
            attr_str = ""
        end
        name = name:match("^%s*(.-)%s*$")
        
        local attrs = {}
        if attr_str ~= "" then
            for k, v in attr_str:gmatch("(%w+)%s*:%s*([^,]+)") do
                attrs[k] = v:match("^%s*(.-)%s*$")
            end
        end
        return name, attrs
    end

    local function register_node(id, attrs)
        if not id or id == "" then return end
        nodes_set[id] = true
        if attrs.url then node_urls[id] = attrs.url end
        if attrs.color then node_colors[id] = attrs.color end
        if attrs.shape then node_shapes[id] = attrs.shape end
        if attrs.group then node_groups[id] = attrs.group end
    end

    local function add_edge(src, tgt)
        table.insert(edges, {src = src, tgt = tgt})
    end

    -- Path Context
    local pwd_handle = io.popen("pwd")
    local current_dir = pwd_handle and pwd_handle:read("*l") or "Unknown"
    if pwd_handle then pwd_handle:close() end
    local project_root = os.getenv("QUARTO_PROJECT_DIR") or current_dir

    local subpath = ""
    if #current_dir > #project_root then
        subpath = current_dir:sub(#project_root + 2)
    end
    local depth_rel = 0
    if #subpath > 0 then
        local _, slashes = subpath:gsub("/", "")
        depth_rel = slashes + 1
    end
    local rel_prefix = string.rep("../", depth_rel)

    -- Recursive Folder Processor
    local function process_auto_dir(parent_name, folder_path, recursive, current_tgt_attrs)
        local os_target_dir = project_root .. "/" .. folder_path
        local cmd = 'ls -p "' .. os_target_dir .. '" 2>/dev/null'
        local handle = io.popen(cmd)
        if not handle then return false end
        
        local result = handle:read("*a")
        handle:close()
        
        local found_anything = false
        for item in string.gmatch(result, "[^\r\n]+") do
            if item:match("%.qmd$") then
                found_anything = true
                -- Process QMD file
                local filename = item
                local filepath = os_target_dir .. "/" .. filename
                local title = filename
                local f = io.open(filepath, "r")
                if f then
                    local content = f:read("*a")
                    f:close()
                    local t = string.match(content, "title:%s*'([^']+)'") 
                           or string.match(content, 'title:%s*"([^"]+)"') 
                           or string.match(content, "title:%s*([^\n\r]+)")
                    if t then title = t:match("^%s*(.-)%s*$") end
                end
                
                local auto_url = rel_prefix .. folder_path .. "/" .. filename:gsub("%.qmd$", ".html")
                register_node(title, { url = auto_url, color = current_tgt_attrs.color, shape = current_tgt_attrs.shape })
                add_edge(parent_name, title)
                
            elseif item:match("/$") and recursive then
                local subfolder_name = item:gsub("/$", "")
                
                if not subfolder_name:match("^%.") and 
                   not subfolder_name:match("_files$") and 
                   not subfolder_name:match("_cache$") then
                   
                    found_anything = true
                    local subfolder_path = folder_path .. "/" .. subfolder_name
                    
                    -- Create a circle node for the folder as a branch point
                    local folder_label = subfolder_name:gsub("^%a", string.upper)
                    register_node(folder_label, { shape = 'circle' }) 
                    add_edge(parent_name, folder_label)
                    
                    -- Recurse into it
                    process_auto_dir(folder_label, subfolder_path, true, current_tgt_attrs)
                end
            end
        end
        return found_anything
    end

    -- Parser Loop
    for line in string.gmatch(raw_text, "[^\r\n]+") do
      local src_str, tgt_str = string.match(line, "(.-)%s*->%s*(.*)")
      
      if src_str and tgt_str then
        local src_name, src_attrs = parse_node_str(src_str)
        local tgt_name, tgt_attrs = parse_node_str(tgt_str)
        register_node(src_name, src_attrs)

        if string.match(tgt_name, "^auto:") then
          local folder = tgt_name:match("^auto:(.*)"):gsub("/$", "")
          local is_recursive = (tgt_attrs.recursive == "true")
          
          local success = process_auto_dir(src_name, folder, is_recursive, tgt_attrs)
          
          if not success then
            local err_node = "[Empty/Missing: " .. folder .. "]"
            register_node(err_node, { group = 3 }) 
            add_edge(src_name, err_node)
          end
        else
          register_node(tgt_name, tgt_attrs)
          add_edge(src_name, tgt_name)
        end
      else
        local name, attrs = parse_node_str(line)
        if name and name ~= "" then register_node(name, attrs) end
      end
    end
    
    -- Graph Metadata Generation
    local in_degree = {}
    local out_edges = {}
    for node in pairs(nodes_set) do
        in_degree[node] = 0
        out_edges[node] = {}
    end
    for _, edge in ipairs(edges) do
        table.insert(out_edges[edge.src], edge.tgt)
        in_degree[edge.tgt] = in_degree[edge.tgt] + 1
    end

    local node_depths = {}
    local queue = {}
    for node, deg in pairs(in_degree) do
        if deg == 0 then
            table.insert(queue, node)
            node_depths[node] = 0
        end
    end
    if #queue == 0 and next(nodes_set) then
        local first_node = next(nodes_set)
        table.insert(queue, first_node)
        node_depths[first_node] = 0
    end

    local head = 1
    while head <= #queue do
        local curr = queue[head]
        head = head + 1
        local current_depth = node_depths[curr]
        for _, neighbor in ipairs(out_edges[curr]) do
            if not node_depths[neighbor] then
                node_depths[neighbor] = current_depth + 1
                table.insert(queue, neighbor)
            end
        end
    end

    local function escape_js(str)
      if not str then return "Unknown" end
      return str:gsub("'", "\\'")
    end

    local nodes_js_arr = {}
    for node in pairs(nodes_set) do
        local url_str = node_urls[node] and string.format("'%s'", escape_js(node_urls[node])) or "null"
        local color_str = node_colors[node] and string.format("'%s'", escape_js(node_colors[node])) or "null"
        local shape_str = node_shapes[node] and string.format("'%s'", escape_js(node_shapes[node])) or "'rounded'"
        local dpt = node_depths[node] or 0 
        
        table.insert(nodes_js_arr, string.format("{ id: '%s', url: %s, depth: %d, color: %s, shape: %s }", 
            escape_js(node), url_str, dpt, color_str, shape_str))
    end

    local links_js_arr = {}
    for _, edge in ipairs(edges) do
        table.insert(links_js_arr, string.format("{ source: '%s', target: '%s' }", escape_js(edge.src), escape_js(edge.tgt)))
    end

    local nodes_js = table.concat(nodes_js_arr, ",\n        ")
    local links_js = table.concat(links_js_arr, ",\n        ")
    local graph_id = "graph_" .. tostring(math.random(100000, 999999))
    
    local html_code = [[
<div id="]] .. graph_id .. [[" style="width: 100%; height: 600px; border: 1px solid #ddd; background: #ffffff; border-radius: 8px; overflow: hidden; position: relative;"></div>

<script src="https://unpkg.com/force-graph"></script>
<script>
  (function initGraph() {
    if (typeof ForceGraph === 'undefined') {
      setTimeout(initGraph, 50);
      return;
    }

    const graphData = {
      nodes: [ ]] .. nodes_js .. [[ ],
      links: [ ]] .. links_js .. [[ ]
    };

    const container = document.getElementById(']] .. graph_id .. [[');
    if (!container) return;

    // --- 1. ASYMPTOTIC COLOR CASCADE LOGIC ---
    
    function lightenColorCascade(hexColor) {
        if (!hexColor) return '#ffffff';
        let hex = hexColor.replace('#', '');
        if (hex.length === 3) hex = hex[0]+hex[0]+hex[1]+hex[1]+hex[2]+hex[2];
        const r = parseInt(hex.substr(0, 2), 16) / 255;
        const g = parseInt(hex.substr(2, 2), 16) / 255;
        const b = parseInt(hex.substr(4, 2), 16) / 255;
        
        let max = Math.max(r, g, b), min = Math.min(r, g, b);
        let h, s, l = (max + min) / 2;

        if (max === min) { h = s = 0; } else {
            let d = max - min;
            s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
            switch (max) {
                case r: h = (g - b) / d + (g < b ? 6 : 0); break;
                case g: h = (b - r) / d + 2; break;
                case b: h = (r - g) / d + 4; break;
            }
            h /= 6;
        }

        l = l + (0.98 - l) * 0.40;
        s = s * 0.85; 

        let outR, outG, outB;
        if (s === 0) { outR = outG = outB = l; } else {
            const hue2rgb = (p, q, t) => {
                if (t < 0) t += 1; if (t > 1) t -= 1;
                if (t < 1/6) return p + (q - p) * 6 * t;
                if (t < 1/2) return q;
                if (t < 2/3) return p + (q - p) * (2/3 - t) * 6;
                return p;
            };
            let q = l < 0.5 ? l * (1 + s) : l + s - l * s;
            let p = 2 * l - q;
            outR = hue2rgb(p, q, h + 1/3);
            outG = hue2rgb(p, q, h);
            outB = hue2rgb(p, q, h - 1/3);
        }

        return '#' + 
            Math.round(outR * 255).toString(16).padStart(2, '0') + 
            Math.round(outG * 255).toString(16).padStart(2, '0') + 
            Math.round(outB * 255).toString(16).padStart(2, '0');
    }

    const nodesMap = new Map();
    const childrenMap = new Map();
    const inDegreeMap = new Map();

    graphData.nodes.forEach(n => {
        nodesMap.set(n.id, n);
        childrenMap.set(n.id, []);
        inDegreeMap.set(n.id, 0);
    });

    graphData.links.forEach(l => {
        if (childrenMap.has(l.source) && inDegreeMap.has(l.target)) {
            childrenMap.get(l.source).push(l.target);
            inDegreeMap.set(l.target, inDegreeMap.get(l.target) + 1);
        }
    });

    // --- GLOBAL DEFAULT COLOR ---
    const GLOBAL_ROOT_COLOR = '#84cfff';
    
    let queue = [];
    let visited = new Set();

    nodesMap.forEach((node, id) => {
        if (inDegreeMap.get(id) === 0) {
            queue.push({ id, parentColor: GLOBAL_ROOT_COLOR, isRoot: true });
            visited.add(id);
        }
    });

    while (queue.length > 0) {
        const { id, parentColor, isRoot } = queue.shift();
        const node = nodesMap.get(id);

        node._resolvedColor = (isRoot) ? (node.color || GLOBAL_ROOT_COLOR) : (node.color || parentColor);
        const lightenedForChildren = lightenColorCascade(node._resolvedColor);

        childrenMap.get(id).forEach(childId => {
            if (!visited.has(childId)) {
                visited.add(childId);
                queue.push({ id: childId, parentColor: lightenedForChildren, isRoot: false });
            }
        });
    }

    // --- 2. CONTRAST THEME GENERATOR ---
    
    function getThemeColors(hexColor) {
        let hex = hexColor.replace('#', '');
        if (hex.length === 3) hex = hex[0]+hex[0]+hex[1]+hex[1]+hex[2]+hex[2];
        const r = parseInt(hex.substr(0, 2), 16) / 255;
        const g = parseInt(hex.substr(2, 2), 16) / 255;
        const b = parseInt(hex.substr(4, 2), 16) / 255;
        
        // Convert to HSL to preserve the exact hue and saturation
        let max = Math.max(r, g, b), min = Math.min(r, g, b);
        let h, s, l = (max + min) / 2;

        if (max === min) { h = s = 0; } else {
            let d = max - min;
            s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
            switch (max) {
                case r: h = (g - b) / d + (g < b ? 6 : 0); break;
                case g: h = (b - r) / d + 2; break;
                case b: h = (r - g) / d + 4; break;
            }
            h /= 6;
        }

        // Dynamically shift lightness for the text color
        // If background is light, make text very dark. If dark, make text very light.
        let textL = l > 0.5 ? Math.max(0.15, l - 0.65) : Math.min(0.95, l + 0.65);

        // Convert back to RGB for the canvas
        let outR, outG, outB;
        if (s === 0) { outR = outG = outB = textL; } else {
            const hue2rgb = (p, q, t) => {
                if (t < 0) t += 1; if (t > 1) t -= 1;
                if (t < 1/6) return p + (q - p) * 6 * t;
                if (t < 1/2) return q;
                if (t < 2/3) return p + (q - p) * (2/3 - t) * 6;
                return p;
            };
            let q = textL < 0.5 ? textL * (1 + s) : textL + s - textL * s;
            let p = 2 * textL - q;
            outR = hue2rgb(p, q, h + 1/3);
            outG = hue2rgb(p, q, h);
            outB = hue2rgb(p, q, h - 1/3);
        }

        let dynamicFg = '#' + 
            Math.round(outR * 255).toString(16).padStart(2, '0') + 
            Math.round(outG * 255).toString(16).padStart(2, '0') + 
            Math.round(outB * 255).toString(16).padStart(2, '0');

        return { bg: hexColor, fg: dynamicFg };
    }

    // --- 3. RENDER ---

    const Graph = ForceGraph()(container)
      .graphData(graphData)
      .linkDirectionalParticles(2)
      .linkColor(() => '#cccccc')
      .nodeCanvasObject((node, ctx, globalScale) => {
        const cappedDepth = Math.min(node.depth || 0, 4); 
        const fontSize = (16 - (cappedDepth * 2)) / globalScale;
        ctx.font = `bold ${fontSize}px Sans-Serif`;
        
        const label = node.id;
        const maxTextWidth = (130 - (cappedDepth * 8)) / globalScale; 
        const words = label.split(' ');
        let lines = [];
        let curLine = words[0];
        for (let i = 1; i < words.length; i++) {
            if (ctx.measureText(curLine + " " + words[i]).width < maxTextWidth) curLine += " " + words[i];
            else { lines.push(curLine); curLine = words[i]; }
        }
        lines.push(curLine);

        const lineHeight = fontSize * 1.2;
        const textWidth = Math.max(...lines.map(l => ctx.measureText(l).width));
        const padding = fontSize * 1.5;
        const boxW = textWidth + padding;
        const boxH = lines.length * lineHeight + padding;
        const theme = getThemeColors(node._resolvedColor);

        ctx.fillStyle = theme.bg;
        ctx.strokeStyle = theme.fg;
        ctx.lineWidth = 1.5 / globalScale;

        ctx.beginPath();
        const r = 8 / globalScale;
        if (node.shape === 'circle') ctx.arc(node.x, node.y, Math.max(boxW, boxH)/2, 0, 2*Math.PI);
        else if (ctx.roundRect) ctx.roundRect(node.x - boxW/2, node.y - boxH/2, boxW, boxH, r);
        else ctx.rect(node.x - boxW/2, node.y - boxH/2, boxW, boxH);
        ctx.fill();
        ctx.stroke();

        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillStyle = theme.fg;
        const startY = node.y - (lines.length * lineHeight)/2 + lineHeight/2;
        lines.forEach((line, i) => ctx.fillText(line, node.x, startY + i * lineHeight));
        
        node.__rect = { boxW, boxH };
      })
      .onNodeClick(node => { if(node.url) window.location.href = node.url; })
      .onNodeHover(node => container.style.cursor = node && node.url ? 'pointer' : null);

      new ResizeObserver(() => {
        Graph.width(container.offsetWidth);
        Graph.height(container.offsetHeight);
      }).observe(container);

  })();
</script>
    ]]
    
    return pandoc.RawBlock("html", html_code)
  end
end
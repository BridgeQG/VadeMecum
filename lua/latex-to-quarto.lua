-- latex-to-quarto.lua

local function normalize_label(lbl)
  -- Safely swap colons for hyphens and normalize table prefixes
  return lbl:gsub(":", "-")
            :gsub("^tab%-", "tbl-")
            :gsub("^table%-", "tbl-")
end

-- 1. INTERCEPT OPAQUE RAW BLOCKS
function RawBlock(el)
  if el.format == 'tex' or el.format == 'latex' then
    local text = el.text

    -- A. Extract Equations & format as Quarto $$ ... $$ {#id}
    if text:match("\\begin{equation}") or text:match("\\begin{align}") then
      local label = text:match("\\label{([^}]+)}")
      local clean_math = text:gsub("\\label{[^}]+}", "")
      
      -- Strip wrappers (Quarto uses $$ for equations)
      clean_math = clean_math:gsub("\\begin{equation%*?}%s*", "")
                             :gsub("\\end{equation%*?}%s*", "")
      -- Convert align to aligned (required for MathJax inside $$)
      clean_math = clean_math:gsub("\\begin{align%*?}", "\\begin{aligned}")
                             :gsub("\\end{align%*?}", "\\end{aligned}")
                             
      local md_str = "$$\n" .. clean_math .. "\n$$"
      if label then
        local q_label = normalize_label(label)
        if not q_label:match("^eq%-") then q_label = "eq-" .. q_label end
        md_str = md_str .. " {#" .. q_label .. "}"
      end
      
      -- Parse the constructed Markdown string directly into AST blocks
      local doc = pandoc.read(md_str, 'markdown')
      return doc.blocks
    end

    -- B. Extract Figures & format as Quarto ![caption](path){#id width=...}
    if text:match("\\begin{figure}") then
      local caption = text:match("\\caption{([^}]+)}") or ""
      local label = text:match("\\label{([^}]+)}") or ""
      
      -- Safely extract path and optional arguments
      local args, path = text:match("\\includegraphics%[([^%]]+)%]{([^}]+)}")
      if not path then
        path = text:match("\\includegraphics{([^}]+)}")
        args = ""
      end

      local q_label = normalize_label(label)
      if q_label ~= "" and not q_label:match("^fig%-") then 
         q_label = "fig-" .. q_label 
      end
      
      local q_args = ""
      if args and args ~= "" then
        q_args = args:gsub("([%w_]+)=([^,%s]+)", '%1="%2"')
      end

      local md_str = "![" .. caption .. "](" .. path .. ")"
      if q_label ~= "" or q_args ~= "" then
         md_str = md_str .. "{#" .. q_label .. " " .. q_args .. "}"
      end

      local doc = pandoc.read(md_str, 'markdown')
      return doc.blocks
    end

    -- C. Fallback for Sections and other structural LaTeX
    local clean_tex = text:gsub("\\label{([^}]+)}", function(lbl)
      return "\\label{" .. normalize_label(lbl) .. "}"
    end)
    local doc = pandoc.read(clean_tex, 'latex')
    return doc.blocks
  end
  return el
end

-- 2. INTERCEPT INLINE COMMANDS
function RawInline(el)
  if el.format == 'tex' or el.format == 'latex' then
    local text = el.text

    -- Intercept \eqref{}
    local eqref_lbl = text:match("^\\eqref{([^}]+)}%s*$")
    if eqref_lbl then
      local q_label = normalize_label(eqref_lbl)
      if not q_label:match("^eq%-") then q_label = "eq-" .. q_label end
      local doc = pandoc.read("([-@" .. q_label .. "])", 'markdown')
      return doc.blocks[1].content
    end

    -- Intercept \ref{}
    local ref_lbl = text:match("^\\ref{([^}]+)}%s*$")
    if ref_lbl then
      local q_label = normalize_label(ref_lbl)
      local doc = pandoc.read("[-@" .. q_label .. "]", 'markdown')
      return doc.blocks[1].content
    end

    -- Intercept \cite{}
    local cite_lbl = text:match("^\\cite{([^}]+)}%s*$")
    if cite_lbl then
      local q_cites = cite_lbl:gsub("%s+", ""):gsub(",", "; @")
      local doc = pandoc.read("[@" .. q_cites .. "]", 'markdown')
      return doc.blocks[1].content
    end

    -- Fallback for inline LaTeX
    local doc = pandoc.read(text, 'latex')
    if doc.blocks and #doc.blocks > 0 and doc.blocks[1].t == "Para" then
      return doc.blocks[1].content
    end
  end
  return el
end
-- Helper: Convert colons to hyphens and handle table prefixes
local function normalize_label(lbl)
  return lbl:gsub(":", "-")
            :gsub("^tab%-", "tbl-")
            :gsub("^table%-", "tbl-")
end

-- 1. EQUATIONS: Extract label and append it exactly as Quarto AST expects
function Math(el)
  if el.mathtype == 'DisplayMath' then
    local label = el.text:match("\\label{([^}]+)}")
    
    if label then
      -- Remove the \label{} command from the math content
      local clean_math = el.text:gsub("\\label{[^}]+}%s*", "")
      
      -- Clean the label
      local q_label = normalize_label(label)
      if not q_label:match("^eq%-") then 
        q_label = "eq-" .. q_label 
      end
      
      -- Return a list of AST nodes: [Math, Space, String]
      -- This exactly mimics native Quarto markdown behavior: $$ math $$ {#eq-label}
      return {
        pandoc.Math('DisplayMath', clean_math),
        pandoc.Space(),
        pandoc.Str("{#" .. q_label .. "}")
      }
    end
  end
  return el
end

-- 2. INLINE COMMANDS: Convert references and citations to native AST Cite nodes
function RawInline(el)
  if el.format == 'tex' or el.format == 'latex' then
    local text = el.text

    -- Intercept \eqref{} -> Renders as (1)
    local eqref_lbl = text:match("^\\eqref{([^}]+)}%s*$")
    if eqref_lbl then
      local q_label = normalize_label(eqref_lbl)
      if not q_label:match("^eq%-") then q_label = "eq-" .. q_label end
      local doc = pandoc.read("([-@" .. q_label .. "])", 'markdown')
      return doc.blocks[1].content
    end

    -- Intercept \ref{} -> Renders as 1
    local ref_lbl = text:match("^\\ref{([^}]+)}%s*$")
    if ref_lbl then
      local q_label = normalize_label(ref_lbl)
      local doc = pandoc.read("[-@" .. q_label .. "]", 'markdown')
      return doc.blocks[1].content
    end

    -- Intercept \cite{} -> Renders standard Quarto citations
    local cite_lbl = text:match("^\\cite{([^}]+)}%s*$")
    if cite_lbl then
      local q_cites = cite_lbl:gsub("%s+", ""):gsub(",", "; @")
      local doc = pandoc.read("[@" .. q_cites .. "]", 'markdown')
      return doc.blocks[1].content
    end

    -- Pass all other inline LaTeX through Pandoc's native reader
    local doc = pandoc.read(text, 'latex')
    if doc.blocks and #doc.blocks > 0 and doc.blocks[1].t == "Para" then
      return doc.blocks[1].content
    end
  end
  return el
end

-- 3. LATEX BLOCKS (Figures, Tables, Sections): Unified fallback
function RawBlock(el)
  if el.format == 'tex' or el.format == 'latex' then
    
    -- Replace ALL \label{name:target} with \label{name-target} inside the block
    local clean_tex = el.text:gsub("\\label{([^}]+)}", function(lbl)
      return "\\label{" .. normalize_label(lbl) .. "}"
    end)
    
    -- Hand the clean LaTeX block over to Pandoc to do the heavy lifting
    local doc = pandoc.read(clean_tex, 'latex')
    return doc.blocks
  end
  return el
end
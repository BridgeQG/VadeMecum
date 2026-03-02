-- Helper: Standardize labels
local function normalize_label(lbl)
  if not lbl then return "" end
  return lbl:gsub(":", "-"):gsub("^tab%-", "tbl-"):gsub("^table%-", "tbl-")
end

-- =====================================================================
-- THE UNIVERSAL TRANSLATOR: Converts LaTeX strings to Quarto strings
-- =====================================================================
local function translate_to_quarto(text)
  
  -- 1. Equations
  if text:match("\\begin{equation}") or text:match("\\begin{align}") then
    local label = text:match("\\label{([^}]+)}")
    local math = text:gsub("\\begin{equation%*?}", ""):gsub("\\end{equation%*?}", "")
                     :gsub("\\begin{align%*?}", "\\begin{aligned}"):gsub("\\end{align%*?}", "\\end{aligned}")
                     :gsub("\\label{[^}]+}", "")
    math = math:gsub("^%s+", ""):gsub("%s+$", "")
    
    local md = "$$\n" .. math .. "\n$$"
    if label then
      local q_label = normalize_label(label)
      if not q_label:match("^eq%-") then q_label = "eq-" .. q_label end
      md = md .. " {#" .. q_label .. "}"
    end
    return md, "markdown" -- Tell Pandoc to read this as Markdown
  end

  -- 2. Figures
  if text:match("\\begin{figure}") then
    local caption = text:match("\\caption{([^}]+)}") or ""
    local label = text:match("\\label{([^}]+)}")
    local args, path = text:match("\\includegraphics%[([^%]]+)%]{([^}]+)}")
    if not path then path = text:match("\\includegraphics{([^}]+)}"); args = "" end

    if path then
      local q_label = ""
      if label then
        q_label = normalize_label(label)
        if not q_label:match("^fig%-") then q_label = "fig-" .. q_label end
      end
      local q_args = ""
      if args and args ~= "" then q_args = args:gsub("([%w_]+)=([^,%s]+)", '%1="%2"') end

      local md = "![" .. caption .. "](" .. path .. ")"
      if q_label ~= "" or q_args ~= "" then md = md .. "{#" .. q_label .. " " .. q_args .. "}" end
      return md, "markdown"
    end
  end

  -- 3. Cross-References & Citations
  local eqref = text:match("^\\eqref{([^}]+)}")
  if eqref then 
    local q_label = normalize_label(eqref)
    if not q_label:match("^eq%-") then q_label = "eq-" .. q_label end
    return "([-@" .. q_label .. "])", "markdown" 
  end

  local ref = text:match("^\\ref{([^}]+)}")
  if ref then return "[-@" .. normalize_label(ref) .. "]", "markdown" end

  local cite = text:match("^\\cite{([^}]+)}")
  if cite then return "[@" .. cite:gsub("%s+", ""):gsub(",", "; @") .. "]", "markdown" end

  -- 4. Sections
  local sec = text:match("^\\section{([^}]+)}")
  if sec then return "# " .. sec, "markdown" end
  local subsec = text:match("^\\subsection{([^}]+)}")
  if subsec then return "## " .. subsec, "markdown" end
  local subsubsec = text:match("^\\subsubsection{([^}]+)}")
  if subsubsec then return "### " .. subsubsec, "markdown" end

  -- 5. THE CATCH-ALL FALLBACK (Tables, Lists, \textbf, etc.)
  -- If it's none of the above, just fix the label and leave it as LaTeX!
  local clean_text = text:gsub("\\label{([^}]+)}", function(lbl)
    return "\\label{" .. normalize_label(lbl) .. "}"
  end)
  return clean_text, "latex" -- Tell Pandoc to read this using its native LaTeX parser
end


-- =====================================================================
-- THE DELIVERY DRIVERS: Inject the translated code back into the AST
-- =====================================================================

-- Handles text squished inside paragraphs
function RawInline(el)
  if el.format == "tex" or el.format == "latex" then
    local converted_text, format_type = translate_to_quarto(el.text)
    local doc = pandoc.read(converted_text, format_type)
    
    -- Extract just the inline pieces from the parsed paragraph
    if doc.blocks[1] and doc.blocks[1].content then
      return doc.blocks[1].content
    end
  end
end

-- Handles text sitting on its own lines
function RawBlock(el)
  if el.format == "tex" or el.format == "latex" then
    local converted_text, format_type = translate_to_quarto(el.text)
    local doc = pandoc.read(converted_text, format_type)
    
    -- Return the full parsed blocks
    return doc.blocks
  end
end
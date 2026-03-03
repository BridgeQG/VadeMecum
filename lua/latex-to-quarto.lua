-- =======================================================================
-- 1. CONFIGURATION TABLES
-- =======================================================================

-- List of inline translation rules. 

local inline_rules = {
    -- Text formatting
    { pattern = "\\textbf{([^}]+)}", replace = "**%1**" },
    { pattern = "\\textit{([^}]+)}", replace = "*%1*" },
    
    -- Links
    { pattern = "\\href{([^}]+)}{([^}]+)}", replace = "[%2](%1)" },
    
    -- Citations (Handles multiple comma-separated citations)
    { pattern = "\\cite{([^}]+)}", replace = function(cites)
        local cite_str = ""
        for ref in string.gmatch(cites, "[^,%s]+") do
            if cite_str == "" then cite_str = "[@" .. ref
            else cite_str = cite_str .. "; @" .. ref end
        end
        return cite_str .. "]"
    end},
    
    -- Cross-references
    { pattern = "\\ref{([^}]+)}", replace = function(ref)
        ref = string.gsub(ref, "^eq:", "eq-")
        ref = string.gsub(ref, "^sec:", "sec-")
        return "[-@" .. ref .. "]"
    end},
    { pattern = "\\eqref{([^}]+)}", replace = function(eqref)
        eqref = string.gsub(eqref, "^eq:", "eq-")
        return "([-@" .. eqref .. "])"
    end}
}

-- =======================================================================
-- 2. HELPER FUNCTIONS
-- =======================================================================

-- Map LaTeX section commands to Markdown header levels (1 = #, 2 = ##, etc.)
local section_rules = {
    section = 1,
    subsection = 2,
    subsubsection = 3
}

-- String trimmer (remove empty spaces, tabs or invisible newlines)
local function trim(s)
  return s:match("^%s*(.-)%s*$")
end

-- Extracts the label from INSIDE the math and prepares it for the OUTSIDE
local function convert_math_label(math_text)
    local label = string.match(math_text, "\\label{([^}]+)}")
    if label then
        local new_math = string.gsub(math_text, "\\label{[^}]+}", "")
        local qmd_label = string.gsub(label, "^eq:", "eq-")
        return trim(new_math), qmd_label
    end
    return trim(math_text), nil
end

-- =======================================================================
-- 3. THE PROCESSING ENGINE 
-- =======================================================================

function Pandoc(doc)
    local new_blocks = {}

    for _, block in ipairs(doc.blocks) do
        if block.t == "Para" or block.t == "Plain" then
            local current_inlines = {}
            
            local function flush_inlines()
                if #current_inlines > 0 then
                    table.insert(new_blocks, pandoc.Para(current_inlines))
                    current_inlines = {}
                end
            end

            for _, inline in ipairs(block.content) do
                
                -- A. ENVIRONMENTS / EQUATIONS
                if inline.t == "Math" and inline.mathtype == "DisplayMath" then
                    flush_inlines()
                    local text, label = convert_math_label(inline.text)
                    local md = label and ("$$\n" .. text .. "\n$$ {#" .. label .. "}") or ("$$\n" .. text .. "\n$$")
                    table.insert(new_blocks, pandoc.RawBlock("markdown", md))
                    
                -- B. INLINE TEX COMMANDS
                elseif inline.t == "RawInline" and (inline.format == "tex" or inline.format == "latex") then
                    local text = inline.text
                    local handled = false
                    
                    -- Check if it is a Section header
                    for cmd, level in pairs(section_rules) do
                        local match = string.match(text, "\\" .. cmd .. "{([^}]+)}")
                        if match then
                            flush_inlines()
                            table.insert(new_blocks, pandoc.Header(level, {pandoc.Str(match)}))
                            handled = true
                            break
                        end
                    end

                    -- If not a section, run it through the inline replacement rules
                    if not handled then
                        local original_text = text
                        
                        for _, rule in ipairs(inline_rules) do
                            text = string.gsub(text, rule.pattern, rule.replace)
                        end
                        
                        if text ~= original_text then
                            table.insert(current_inlines, pandoc.RawInline("markdown", text))
                        else
                            table.insert(current_inlines, inline)
                        end
                    end
                else
                    table.insert(current_inlines, inline)
                end
            end
            flush_inlines()
            
        -- C. FALLBACK FOR RAW BLOCKS
        elseif block.t == "RawBlock" and (block.format == "tex" or block.format == "latex") then
            local eq_text = string.match(block.text, "\\begin{equation}(.-)\\end{equation}")
            if eq_text then
                local text, label = convert_math_label(eq_text)
                local md = label and ("$$\n" .. text .. "\n$$ {#" .. label .. "}") or ("$$\n" .. text .. "\n$$")
                table.insert(new_blocks, pandoc.RawBlock("markdown", md))
            else
                table.insert(new_blocks, block)
            end
        else
            table.insert(new_blocks, block)
        end
    end

    return pandoc.Pandoc(new_blocks, doc.meta)
end
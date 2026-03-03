-- ==========
-- RULES
-- ==========

-- LaTeX inline command's replacement rules
local inline_rules = {
    -- Bold text
    { pattern = "\\textbf{([^}]+)}", replace = "**%1**" },
    -- Italic text
    { pattern = "\\textit{([^}]+)}", replace = "*%1*" },
    -- Hyperlink
    { pattern = "\\href{([^}]+)}{([^}]+)}", replace = "[%2](%1)" },
    -- Citations
    { pattern = "\\cite{([^}]+)}", replace = function(cites)
        local cite_str = ""
        for ref in string.gmatch(cites, "[^,%s]+") do
            if cite_str == "" then cite_str = "[@" .. ref
            else cite_str = cite_str .. "; @" .. ref end
        end
        return cite_str .. "]"
    end},
    -- References
    { pattern = "\\ref{([^}]+)}", replace = function(ref)
        ref = string.gsub(ref, "^eq:", "eq-")
        ref = string.gsub(ref, "^sec:", "sec-")
        return "[-@" .. ref .. "]"
    end},
    -- Equation references
    { pattern = "\\eqref{([^}]+)}", replace = function(eqref)
        eqref = string.gsub(eqref, "^eq:", "eq-")
        return "([-@" .. eqref .. "])"
    end}
}

-- LaTeX environment's replacement rules
local environment_rules = {
    
    -- Equation environment
    equation = function(content, label)
        local md = "$$\n" .. content .. "\n$$"
        if label then
            local q_label = string.gsub(label, "^eq:", "eq-")
            if not string.match(q_label, "^eq%-") then q_label = "eq-" .. q_label end
            md = md .. " {#" .. q_label .. "}"
        end
        return md
    end,
    
    -- Split environment
    split = function(content, label)
        -- Keeps the 'split' inner environment
        local md = "$$\n\\begin{split}\n" .. content .. "\n\\end{split}\n$$"
        if label then
            local q_label = string.gsub(label, "^eq:", "eq-")
            if not string.match(q_label, "^eq%-") then q_label = "eq-" .. q_label end
            md = md .. " {#" .. q_label .. "}"
        end
        return md
    end,

    -- Align environment (not supported, translated to aligned)
    align = function(content, label)
        local md = "$$\n\\begin{aligned}\n" .. content .. "\n\\end{aligned}\n$$"
        if label then
            local q_label = string.gsub(label, "^eq:", "eq-")
            if not string.match(q_label, "^eq%-") then q_label = "eq-" .. q_label end
            md = md .. " {#" .. q_label .. "}"
        end
        return md
    end,

    -- Gather environment (not supported, translated to gathered)
    gather = function(content, label)
        local md = "$$\n\\begin{gathered}\n" .. content .. "\n\\end{gathered}\n$$"
        if label then
            local q_label = string.gsub(label, "^eq:", "eq-")
            if not string.match(q_label, "^eq%-") then q_label = "eq-" .. q_label end
            md = md .. " {#" .. q_label .. "}"
        end
        return md
    end
}

-- Header hierarchy
local section_rules = {
    section = 1,
    subsection = 2,
    subsubsection = 3
}

-- ==========
-- Functions
-- ==========

-- Translator function
local function apply_rules(text)
    local original_text = text

    -- Process LaTeX environments into quarto blocks
    for env_name, env_func in pairs(environment_rules) do
        local env_pattern = "\\begin{" .. env_name .. "%*?}(.-)\\end{" .. env_name .. "%*?}"
        local content = string.match(text, env_pattern)
        
        if content then
            local label = string.match(content, "\\label{([^}]+)}")
            if label then
                content = string.gsub(content, "\\label{[^}]+}", "")
            end
            
            content = content:match("^%s*(.-)%s*$")
            
            local md = env_func(content, label)
            return md, "block"
        end
    end

    -- Process LaTeX sections into quarto blocks
    for cmd, level in pairs(section_rules) do
        local sec_pattern = "\\" .. cmd .. "{([^}]+)}"
        local title = string.match(text, sec_pattern)
        if title then
            local prefix = string.rep("#", level)
            return "\n" .. prefix .. " " .. title .. "\n", "block"
        end
    end

    -- Process LaTeX inline commands into quarto inline commands
    for _, rule in ipairs(inline_rules) do
        text = string.gsub(text, rule.pattern, rule.replace)
    end
    
    if text ~= original_text then
        return text, "inline"
    end

    return nil, nil
end

-- Main function
function Blocks(blocks)
    local new_blocks = pandoc.List()
    
    for _, block in ipairs(blocks) do
        if block.t == "Para" or block.t == "Plain" then
            local current_inlines = pandoc.List()
            
            local function flush_inlines()
                if #current_inlines > 0 then
                    new_blocks:insert(pandoc.Para(current_inlines))
                    current_inlines = pandoc.List()
                end
            end

            for _, el in ipairs(block.content) do
                if el.t == "RawInline" and (el.format == "tex" or el.format == "latex") then
                    local md, result_type = apply_rules(el.text)
                    
                    if result_type == "block" then
                        flush_inlines()
                        
                        local doc = pandoc.read(md, "markdown")
                        for _, b in ipairs(doc.blocks) do
                            new_blocks:insert(b)
                        end
                        
                    elseif result_type == "inline" then
                        local doc = pandoc.read(md, "markdown")
                        if doc.blocks[1] and doc.blocks[1].content then
                            for _, inline_el in ipairs(doc.blocks[1].content) do
                                current_inlines:insert(inline_el)
                            end
                        end
                    else
                        current_inlines:insert(el)
                    end
                else
                    current_inlines:insert(el)
                end
            end
            flush_inlines()
            
        elseif block.t == "RawBlock" and (block.format == "tex" or block.format == "latex") then
            local md, result_type = apply_rules(block.text)
            if md then
                local doc = pandoc.read(md, "markdown")
                for _, b in ipairs(doc.blocks) do
                    new_blocks:insert(b)
                end
            else
                new_blocks:insert(block)
            end
        else
            new_blocks:insert(block)
        end
    end
    
    return new_blocks
end
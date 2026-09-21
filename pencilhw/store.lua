--[[--
Stroke persistence for pencil-handwriting.

Strokes are grouped by page and serialized into the document's sidecar
directory (the same directory KOReader creates for reading position and
highlights), using a plain Lua table:

    return {
      version = 2,
      doc = { name = "book.pdf", kind = "pdf", pages = 320, bytes = 12345678 },
      pages = {
        [12] = {
          { tool="pen", space="page", width=3, color="black", points={x1,y1,x2,y2,...} },
          { tool="eraser", space="page", points={...} },
        },
      },
    }

`doc` is the document's fingerprint, written so an export tool can tell "these
strokes belong to this file" from "these strokes belong to another file that
happens to use the same kind of page numbers". The same data is dumped to
`pencil_handwriting.json` on demand (see exportJSON), which is what export
scripts and the pencil-ink web service read.
--]]

local logger = require("logger")
local util = require("util")
local Config = require("pencilhw/config")

local StrokeStore = {}
StrokeStore.__index = StrokeStore

function StrokeStore:new(sidecar_dir)
    return setmetatable({
        sidecar_dir = sidecar_dir,
        pages = {},
        -- Fingerprint of the document these strokes belong to (see
        -- Config.DOC_FINGERPRINT). Filled in by main.lua once the document is
        -- open, written on every save, and used by the export tools to refuse
        -- to mix up two different books.
        doc_meta = nil,
        -- Save outcome, surfaced in the diagnostics readout: a silent failure
        -- here is indistinguishable from "the plugin does not persist".
        last_save_error = nil,
        saved_count = nil,
        last_export_error = nil,
    }, self)
end

function StrokeStore:setDocumentMeta(meta)
    self.doc_meta = (type(meta) == "table") and meta or nil
end

-- One line for the diagnostics: what the file will claim about the document.
function StrokeStore:describeDocMeta()
    local m = self.doc_meta
    if type(m) ~= "table" or (m.name == nil and m.pages == nil and m.bytes == nil) then
        return "document fingerprint: none"
    end
    return string.format("document fingerprint: %s, %s, %s pages, %s bytes",
        tostring(m.name or "-"), tostring(m.kind or "-"),
        tostring(m.pages or "-"), tostring(m.bytes or "-"))
end

function StrokeStore:sidecarPath()
    if not self.sidecar_dir then return nil end
    return self.sidecar_dir .. "/" .. Config.SIDECAR_FILENAME
end

function StrokeStore:load()
    local path = self:sidecarPath()
    if not path then
        self.last_save_error = "no sidecar directory"
        return false
    end

    local f = io.open(path, "r")
    if not f then return false end
    f:close()

    local ok, data = pcall(dofile, path)
    if not ok or type(data) ~= "table" then
        logger.warn("PencilHW: failed to load strokes from", path)
        self.last_save_error = "unreadable sidecar"
        return false
    end

    local version = tonumber(data.version)
    if version ~= 1 and version ~= Config.STROKE_FORMAT_VERSION then
        logger.warn("PencilHW: unsupported stroke format version, ignoring")
        self.last_save_error = "unsupported stroke format version"
        return false
    end

    if version == 1 then
        -- Version 1 stored *screen* pixels, which is the very thing that made
        -- handwriting slide over to another part of the page (or to the
        -- neighbouring page) whenever the view scrolled or zoomed. They cannot
        -- be converted faithfully -- the view they were written under is not
        -- recorded -- so they are not loaded at all rather than being drawn in
        -- the wrong place. The file is left untouched until the next write.
        self.last_save_error = "version 1 file skipped (screen coordinates)"
        self.skipped_v1 = true
        logger.warn("PencilHW: sidecar is a version 1 file: its strokes are in"
            .. " screen coordinates and cannot be placed correctly; skipping"
            .. " them. Draw them again (see README).")
        return false
    end

    -- Page keys are written with tostring(), so a table that went through a
    -- different writer can come back with string keys; normalise them or every
    -- lookup by page number would silently miss.
    local pages, normalised = data.pages or {}, 0
    self.pages = {}
    for key, strokes in pairs(pages) do
        local numeric = tonumber(key)
        if numeric then
            self.pages[numeric] = strokes
            normalised = normalised + 1
        else
            self.pages[key] = strokes
        end
    end

    logger.info("PencilHW: loaded", self:strokeCount(), "strokes from", path,
        "(", normalised, "pages )")
    return true
end

-- A page key is a number for paged documents and an xpointer string for
-- reflowable ones, so it has to be quoted when it is not a number: writing a
-- bare xpointer would produce a sidecar Lua cannot parse, and every stroke in
-- the file would be lost on the next open.
local function luaKey(page)
    if type(page) == "number" then return tostring(page) end
    return string.format("%q", tostring(page))
end

-- Page coordinates are fractional (document pixels at scale 1). One decimal is
-- far below what the screen can resolve and keeps the file from doubling in
-- size, which matters because the file is written on every pen lift.
--
-- Non-finite values are folded to 0 rather than written out: "nan" in the middle
-- of a JSON array is not JSON, and a NaN that reaches a renderer is worse than a
-- misplaced point. The plugin already drops them at input; this is the belt.
local function coord(value)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then return "0" end
    local rounded = math.floor(n * 10 + (n >= 0 and 0.5 or -0.5)) / 10
    if rounded == math.floor(rounded) then
        return string.format("%d", rounded)
    end
    return string.format("%.1f", rounded)
end

local function pointList(points)
    local out = {}
    for i = 1, #points do
        out[i] = coord(points[i])
    end
    return table.concat(out, ",")
end

-- The document fingerprint, as it appears in the .lua file. Only fields that are
-- actually known are written: a `bytes = nil` would break the reader side's
-- comparison, so an unknown field is simply absent.
local function docMetaLine(meta)
    if type(meta) ~= "table" then return nil end

    local fields = {}
    local function add(key, value, quoted)
        if value == nil or value == "" then return end
        if quoted then
            fields[#fields + 1] = string.format("%s=%q", key, tostring(value))
        else
            fields[#fields + 1] = string.format("%s=%s", key, tostring(value))
        end
    end

    local name = meta.name
    if type(name) == "string" and #name > 160 then name = name:sub(1, 160) end
    add("name", name, true)
    add("kind", meta.kind, true)
    add("pages", tonumber(meta.pages))
    add("bytes", tonumber(meta.bytes))

    if #fields == 0 then return nil end
    return "  doc = { " .. table.concat(fields, ", ") .. " },\n"
end

function StrokeStore:save()
    local path = self:sidecarPath()
    if not path then
        self.last_save_error = "no sidecar directory"
        logger.warn("PencilHW: no sidecar directory, strokes stay in memory only")
        return false
    end

    if self.sidecar_dir then
        util.makePath(self.sidecar_dir)
    end

    local f = io.open(path, "w")
    if not f then
        self.last_save_error = "cannot write " .. path
        logger.warn("PencilHW: cannot write", path)
        return false
    end

    f:write("-- pencil-handwriting.koplugin stroke data\n")
    f:write("return {\n")
    f:write("  version = ", Config.STROKE_FORMAT_VERSION, ",\n")
    if Config.DOC_FINGERPRINT then
        local meta_line = docMetaLine(self.doc_meta)
        if meta_line then f:write(meta_line) end
    end
    f:write("  pages = {\n")

    for page, strokes in pairs(self.pages) do
        f:write("    [", luaKey(page), "] = {\n")
        for _, s in ipairs(strokes) do
            f:write("      { tool=", string.format("%q", s.tool or "pen"),
                    ", space=", string.format("%q", s.space or "native"),
                    ", width=", tostring(s.width or Config.DEFAULT_WIDTH),
                    ", color=", string.format("%q", s.color or Config.DEFAULT_COLOR),
                    ", points={", pointList(s.points), "} },\n")
        end
        f:write("    },\n")
    end

    f:write("  },\n")
    f:write("}\n")
    f:close()

    self.saved_count = self:strokeCount()
    self.last_save_error = nil
    if self.saved_count == 0 then
        -- Writing an empty set is a destructive event worth seeing in the log:
        -- otherwise "the strokes are gone" cannot be told apart from "the
        -- strokes were never written".
        logger.info("PencilHW: wrote an EMPTY stroke set to", path)
    else
        logger.dbg("PencilHW: saved", self.saved_count, "strokes to", path)
    end
    return true
end

-- ============================================================================
-- JSON export
-- ============================================================================
-- Written by hand rather than through a JSON library: the file is a fixed,
-- flat shape (numbers, short strings, arrays), there is no JSON module the
-- plugin can count on, and an escaping bug here would silently produce a file
-- that no tool can read.
local function jsonEscape(value)
    local text = tostring(value or "")
    text = text:gsub("[\\\"]", "\\%0")
    text = text:gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    -- Control characters cannot appear in a JSON string unescaped.
    text = text:gsub("%c", function(c) return string.format("\\u%04x", c:byte()) end)
    return text
end

local function jsonNumber(value, fallback)
    local n = tonumber(value)
    if not n or n ~= n then return tostring(fallback or 0) end
    if n == math.floor(n) and math.abs(n) < 1e15 then
        return string.format("%d", n)
    end
    return string.format("%.4f", n)
end

function StrokeStore:jsonPath()
    if not self.sidecar_dir then return nil end
    return self.sidecar_dir .. "/" .. Config.JSON_EXPORT_FILENAME
end

-- Exports every stroke, in every coordinate space, exactly as stored -- the
-- consumer (a script, the pencil-ink web service) decides what it can use. The
-- page key is always a string so that reflow documents' xpointers survive.
function StrokeStore:exportJSON()
    local path = self:jsonPath()
    if not path then
        self.last_export_error = "no sidecar directory"
        return nil, self.last_export_error
    end

    util.makePath(self.sidecar_dir)
    local f = io.open(path, "w")
    if not f then
        self.last_export_error = "cannot write " .. path
        return nil, self.last_export_error
    end

    local out = {}
    local function w(s) out[#out + 1] = s end

    w("{\n")
    w('  "format": "pencil-handwriting",\n')
    w('  "version": ' .. jsonNumber(Config.STROKE_FORMAT_VERSION) .. ",\n")
    w('  "plugin": "' .. jsonEscape(Config.VERSION) .. '",\n')

    if Config.DOC_FINGERPRINT and type(self.doc_meta) == "table" then
        local meta = self.doc_meta
        local fields = {}
        if type(meta.name) == "string" and meta.name ~= "" then
            fields[#fields + 1] = '    "name": "' .. jsonEscape(meta.name) .. '"'
        end
        if type(meta.kind) == "string" and meta.kind ~= "" then
            fields[#fields + 1] = '    "kind": "' .. jsonEscape(meta.kind) .. '"'
        end
        if tonumber(meta.pages) then
            fields[#fields + 1] = '    "pages": ' .. jsonNumber(meta.pages)
        end
        if tonumber(meta.bytes) then
            fields[#fields + 1] = '    "bytes": ' .. jsonNumber(meta.bytes)
        end
        if #fields > 0 then
            w('  "doc": {\n' .. table.concat(fields, ",\n") .. "\n  },\n")
        end
    end

    w('  "pages": {')
    local first_page = true
    for page, strokes in pairs(self.pages) do
        w(first_page and "\n" or ",\n")
        first_page = false
        w('    "' .. jsonEscape(page) .. '": [')
        for i = 1, #strokes do
            local s = strokes[i]
            w(i == 1 and "\n" or ",\n")
            w('      { "tool": "' .. jsonEscape(s.tool or "pen")
                .. '", "space": "' .. jsonEscape(s.space or "native")
                .. '", "width": ' .. jsonNumber(s.width, Config.DEFAULT_WIDTH)
                .. ', "color": "' .. jsonEscape(s.color or Config.DEFAULT_COLOR)
                .. '", "points": [')
            local pts = {}
            for j = 1, #(s.points or {}) do
                pts[j] = coord(s.points[j])
            end
            w(table.concat(pts, ","))
            w("] }")
        end
        w("\n    ]")
    end
    if not first_page then w("\n") end
    w("  }\n}\n")

    f:write(table.concat(out))
    f:close()

    self.last_export_error = nil
    self.exported_path = path
    self.exported_count = self:strokeCount()
    logger.info("PencilHW: exported", self.exported_count, "strokes to", path)
    return path
end

-- How many strokes are in each coordinate space. A file that mixes them is
-- expected right after an upgrade, not a bug (see STORE_IN_PAGE_SPACE).
function StrokeStore:spaceCounts()
    local counts = {}
    for _, strokes in pairs(self.pages) do
        for _, s in ipairs(strokes) do
            local space = s.space or "native"
            counts[space] = (counts[space] or 0) + 1
        end
    end

    local parts = {}
    for space, n in pairs(counts) do
        parts[#parts + 1] = space .. "=" .. n
    end
    table.sort(parts)
    return table.concat(parts, " ")
end

-- One-line state summary for the diagnostics dialog.
function StrokeStore:describe()
    local path = self:sidecarPath()
    if not path then
        return "sidecar: NONE (doc_settings has no sidecar dir!)"
    end
    local size = "missing"
    local f = io.open(path, "r")
    if f then
        local content = f:read("*a")
        f:close()
        size = tostring(#(content or "")) .. " bytes"
    end
    local spaces = self:spaceCounts()
    return string.format("sidecar: %s\nfile: %s, saved strokes: %s, last error: %s%s\n%s",
        path, size, tostring(self.saved_count or "-"),
        tostring(self.last_save_error or "none"),
        spaces ~= "" and ("\nstroke space: " .. spaces) or "",
        self:describeDocMeta())
end

-- Note: writing the sidecar on every single stroke would rewrite the whole
-- file once per stroke (quadratic I/O) for no benefit, because the file is
-- flushed shortly after the pen lifts and on every page change.
function StrokeStore:addStroke(page, stroke)
    if page == nil then
        -- Nothing to file it under: say so instead of raising "table index is
        -- nil" inside an input callback.
        logger.warn("PencilHW: stroke dropped, no page identity yet")
        return false
    end
    self.pages[page] = self.pages[page] or {}
    table.insert(self.pages[page], stroke)
    return true
end

function StrokeStore:addEraseStroke(page, x, y)
    self.pages[page] = self.pages[page] or {}
    table.insert(self.pages[page], {
        tool = "eraser",
        width = 0,
        color = Config.DEFAULT_COLOR,
        points = { x, y },
    })
end

-- A nil page key would raise "table index is nil" rather than simply finding
-- nothing, and it can reach here before the reader has announced its first
-- page. Returning an empty set keeps a missing identity from turning into an
-- error inside the repaint (where it would be swallowed by the pcall).
function StrokeStore:pageStrokes(page)
    if page == nil then return {} end
    return self.pages[page] or {}
end

function StrokeStore:strokeCount()
    local n = 0
    for _, strokes in pairs(self.pages) do
        n = n + #strokes
    end
    return n
end

-- Distinct page keys. A document that keeps reporting one key no matter which
-- page is on screen shows up here as 1, which is the signature of strokes
-- landing on every page.
function StrokeStore:pageCount()
    local n = 0
    for _ in pairs(self.pages) do
        n = n + 1
    end
    return n
end

function StrokeStore:removePageStrokes(page)
    if page == nil then return 0 end
    local n = #(self.pages[page] or {})
    if n > 0 then
        self.pages[page] = nil
        self:save()
        -- Logged because "the strokes are gone" has two very different causes:
        -- this, or a write that never happened. Without the line, the two look
        -- identical in a report.
        logger.info("PencilHW: cleared", n, "strokes on page", tostring(page))
    end
    return n
end

function StrokeStore:removeAll()
    local n = self:strokeCount()
    self.pages = {}
    self:save()
    logger.info("PencilHW: cleared all", n, "strokes in the document")
    return n
end

return StrokeStore

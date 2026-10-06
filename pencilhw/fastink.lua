--[[--
Direct e-ink path for Android readers built on a Freescale EPDC (i.MX6,
`mxc_epdc_fb`), such as the iReader Smart (R1001).

Why this exists
---------------
KOReader's Android framebuffer has no e-ink driver for these devices. Every
refresh, however small, copies the whole window to Android and leaves the
waveform to the system -- fine for a page turn, far too slow for ink: each pen
sample cost a full-window copy, a SurfaceFlinger composition and a default
(slow) panel update, so the ink trailed the pen by a long way.

While a stroke is being written, this module paints the new segment straight
into the framebuffer page that is on the panel right now and asks the EPDC for
a DU update of just that rectangle. KOReader's own buffer still receives the
same ink, and the normal refresh once the pen lifts brings Android back in
sync -- so the worst a stray system repaint can do mid-stroke is hide the fast
ink until then.

Everything is opt-in by detection: if the node is not an `mxc_epdc_fb`, its
geometry does not match the KOReader screen, or the driver rejects the update
request, the module reports why and the plugin keeps its old refresh path.
--]]

local ffi = require("ffi")
local C = ffi.C
local logger = require("logger")
local Blitbuffer = require("ffi/blitbuffer")
local Canvas = require("pencilhw/canvas")
local Config = require("pencilhw/config")

-- KOReader's own declarations of open/ioctl/mmap; loaded here in case nothing
-- else has pulled them in yet.
pcall(require, "ffi/posix_h")

local function safeCdef(decl)
    local ok, err = pcall(ffi.cdef, decl)
    if not ok then
        logger.dbg("PencilHW: cdef skipped:", tostring(err))
    end
end

safeCdef("int open(const char *pathname, int flags)")
safeCdef("int close(int fd)")
safeCdef("int ioctl(int fd, unsigned long request, ...)")
safeCdef("int munmap(void *, size_t)")
-- linux/fb.h, 3.0-era layout: struct fb_var_screeninfo is 40 u32 words.
safeCdef("struct phw_fb_var { uint32_t v[40]; }")
safeCdef([[struct phw_fb_fix {
    char id[16];
    unsigned long smem_start;
    uint32_t smem_len;
    uint32_t type;
    uint32_t type_aux;
    uint32_t visual;
    uint16_t xpanstep;
    uint16_t ypanstep;
    uint16_t ywrapstep;
    uint32_t line_length;
    unsigned long mmio_start;
    uint32_t mmio_len;
    uint32_t accel;
    uint16_t capabilities;
    uint16_t reserved[2];
}]])
-- linux/mxcfb.h struct mxcfb_update_data. The fields that matter come first and
-- are the same in every Freescale/NTX variant; everything after `flags`
-- (alt_buffer_data, and dither_mode/quant_bit on newer kernels) stays zero, so
-- one buffer large enough for the biggest variant serves them all.
safeCdef([[struct phw_mxcfb_update {
    uint32_t top;
    uint32_t left;
    uint32_t width;
    uint32_t height;
    uint32_t waveform_mode;
    uint32_t update_mode;
    uint32_t update_marker;
    int32_t temp;
    uint32_t flags;
    uint32_t tail[9];
}]])

local O_RDWR     = 2
local PROT_RW    = 3   -- PROT_READ | PROT_WRITE
local MAP_SHARED = 1

local FBIOGET_VSCREENINFO = 0x4600
local FBIOGET_FSCREENINFO = 0x4602
-- _IOW('F', 0x2E, struct mxcfb_update_data): 64 bytes on the original BSP
-- layout, 72 where dither_mode/quant_bit were added. Tried in that order.
local MXCFB_SEND_UPDATE = { 0x4040462E, 0x4048462E }

local VAR_XRES, VAR_YRES = 0, 1
local VAR_YRES_VIRTUAL   = 3
local VAR_YOFFSET        = 5
local VAR_BPP            = 6

local UPDATE_MODE_PARTIAL       = 0
local TEMP_USE_AMBIENT          = 0x1000
local EPDC_FLAG_FORCE_MONOCHROME = 0x02

local function nowMs()
    local ok, time = pcall(require, "ui/time")
    if ok and time and time.now and time.to_ms then
        return time.to_ms(time.now())
    end
    return os.clock() * 1000
end

local FastInk = {}
FastInk.__index = FastInk

-- Opens the panel for direct ink, or returns nil and the reason it will not.
-- `screen_w`/`screen_h` are KOReader's screen size: direct ink is only right
-- when the framebuffer page is exactly what KOReader draws into.
function FastInk.open(screen_w, screen_h)
    local path = Config.FASTINK_DEVICE or "/dev/graphics/fb0"
    local fd = C.open(path, O_RDWR)
    if fd < 0 then
        return nil, "cannot open " .. path .. " (errno " .. ffi.errno() .. ")"
    end

    local function fail(why)
        C.close(fd)
        return nil, why
    end

    local fix = ffi.new("struct phw_fb_fix[1]")
    if C.ioctl(fd, FBIOGET_FSCREENINFO, fix) ~= 0 then
        return fail("FBIOGET_FSCREENINFO failed (errno " .. ffi.errno() .. ")")
    end
    local id = ffi.string(fix[0].id)
    if id:sub(1, 11) ~= "mxc_epdc_fb" then
        return fail("framebuffer is " .. id .. ", not an EPDC")
    end

    local var = ffi.new("struct phw_fb_var[1]")
    if C.ioctl(fd, FBIOGET_VSCREENINFO, var) ~= 0 then
        return fail("FBIOGET_VSCREENINFO failed (errno " .. ffi.errno() .. ")")
    end
    local xres, yres = var[0].v[VAR_XRES], var[0].v[VAR_YRES]
    local bpp = var[0].v[VAR_BPP]
    if xres ~= screen_w or yres ~= screen_h then
        return fail(string.format("framebuffer %dx%d does not match screen %sx%s",
            xres, yres, tostring(screen_w), tostring(screen_h)))
    end

    local bbtype
    if bpp == 16 then
        bbtype = Blitbuffer.TYPE_BBRGB16
    elseif bpp == 32 then
        bbtype = Blitbuffer.TYPE_BBRGB32
    elseif bpp == 8 then
        bbtype = Blitbuffer.TYPE_BB8
    else
        return fail("unsupported depth " .. bpp .. " bpp")
    end

    local line_length = fix[0].line_length
    local size = line_length * var[0].v[VAR_YRES_VIRTUAL]
    if fix[0].smem_len > 0 and fix[0].smem_len < size then size = fix[0].smem_len end
    local map = C.mmap(nil, size, PROT_RW, MAP_SHARED, fd, 0)
    if map == nil or ffi.cast("intptr_t", map) == -1 then
        return fail("mmap failed (errno " .. ffi.errno() .. ")")
    end

    local self = setmetatable({
        fd = fd,
        map = ffi.cast("uint8_t *", map),
        map_size = size,
        line_length = line_length,
        bpp = bpp,
        bbtype = bbtype,
        w = xres,
        h = yres,
        var = var,
        upd = ffi.new("struct phw_mxcfb_update[1]"),
        request = nil,       -- the MXCFB_SEND_UPDATE variant that worked
        failed = nil,        -- reason, once the driver has refused us
        pending = nil,       -- rectangle drawn but not yet sent to the panel
        last_send = 0,
        sent = 0,
    }, FastInk)
    logger.info(string.format("PencilHW: fast ink on %s (%s) %dx%d %dbpp stride=%d",
        path, id, xres, yres, bpp, line_length))
    return self
end

function FastInk:matches(screen_w, screen_h)
    return self.w == screen_w and self.h == screen_h
end

-- The framebuffer page on the panel right now. SurfaceFlinger flips between
-- several pages, so this is looked up for every segment.
function FastInk:visiblePage()
    if C.ioctl(self.fd, FBIOGET_VSCREENINFO, self.var) ~= 0 then return nil end
    local yoffset = self.var[0].v[VAR_YOFFSET]
    if (yoffset + self.h) * self.line_length > self.map_size then return nil end
    if self.bb and self.yoffset == yoffset then return self.bb end

    self.yoffset = yoffset
    self.bb = Blitbuffer.new(self.w, self.h, self.bbtype,
        self.map + yoffset * self.line_length, self.line_length,
        self.line_length * 8 / self.bpp)
    return self.bb
end

local function union(a, b)
    if not a then return { x = b.x, y = b.y, w = b.w, h = b.h } end
    local x, y = math.min(a.x, b.x), math.min(a.y, b.y)
    local x2 = math.max(a.x + a.w, b.x + b.w)
    local y2 = math.max(a.y + a.h, b.y + b.h)
    return { x = x, y = y, w = x2 - x, h = y2 - y }
end

-- Paints one segment onto the panel. False means the direct path is not
-- available (any more) and the caller should refresh the usual way.
function FastInk:drawLine(x0, y0, x1, y1, radius, color)
    if self.failed or not self.fd then return false end
    local bb = self:visiblePage()
    if not bb then return false end

    local region = Canvas.drawLine(bb, x0, y0, x1, y1, radius, color)
    if not region then return true end
    self.pending = union(self.pending, region)

    if nowMs() - self.last_send >= (Config.FASTINK_INTERVAL_MS or 0) then
        return self:flush()
    end
    return true
end

-- Sends whatever has been drawn since the last update.
function FastInk:flush()
    local r = self.pending
    self.pending = nil
    if not r or self.failed or not self.fd then return not self.failed end

    local x = math.max(0, math.floor(r.x))
    local y = math.max(0, math.floor(r.y))
    local x2 = math.min(self.w, math.ceil(r.x + r.w))
    local y2 = math.min(self.h, math.ceil(r.y + r.h))
    if x2 <= x or y2 <= y then return true end

    local upd = self.upd
    ffi.fill(upd, ffi.sizeof(upd))
    upd[0].top, upd[0].left = y, x
    upd[0].width, upd[0].height = x2 - x, y2 - y
    local waveform = self.waveform or Config.FASTINK_WAVEFORM or 1
    upd[0].waveform_mode = waveform
    upd[0].update_mode = UPDATE_MODE_PARTIAL
    upd[0].temp = Config.FASTINK_TEMP or TEMP_USE_AMBIENT
    if Config.FASTINK_MONO_WAVEFORMS and Config.FASTINK_MONO_WAVEFORMS[waveform] then
        upd[0].flags = EPDC_FLAG_FORCE_MONOCHROME
    end

    local requests = self.request and { self.request } or MXCFB_SEND_UPDATE
    for _, request in ipairs(requests) do
        if C.ioctl(self.fd, request, upd) == 0 then
            if not self.request then
                self.request = request
                logger.info(string.format("PencilHW: fast ink update accepted (request 0x%08X)", request))
            end
            self.sent = self.sent + 1
            self.last_send = nowMs()
            return true
        end
    end

    self.failed = "MXCFB_SEND_UPDATE refused (errno " .. ffi.errno() .. ")"
    logger.warn("PencilHW: fast ink disabled:", self.failed)
    return false
end

function FastInk:describe()
    if self.failed then return "failed: " .. self.failed end
    return string.format("%dx%d %dbpp, waveform=%d, updates sent=%d%s", self.w, self.h,
        self.bpp, self.waveform or Config.FASTINK_WAVEFORM or 1, self.sent,
        self.request and string.format(" (0x%08X)", self.request) or "")
end

function FastInk:close()
    self.pending = nil
    self.bb = nil
    if self.map then
        C.munmap(self.map, self.map_size)
        self.map = nil
    end
    if self.fd then
        C.close(self.fd)
        self.fd = nil
    end
end

return FastInk

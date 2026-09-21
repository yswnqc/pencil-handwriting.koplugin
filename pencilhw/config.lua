--[[--
Configuration for pencil-handwriting.

Kept in its own namespace (pencilhw/) so that it can never collide with a
module exposed by another plugin sharing the global package.loaded table.
--]]

local _ = require("gettext")
-- The colour names are shown in a menu, so they go through the plugin's own
-- dictionary as well. Loading it must not be able to break the plugin: on any
-- failure the plain gettext function is kept and the labels stay English.
do
    local ok, i18n = pcall(require, "pencilhw/i18n")
    if ok and type(i18n) == "table" and type(i18n.gettext) == "function" then
        _ = i18n.gettext
    end
end

local Config = {}

-- ============================================================================
-- Version
-- ============================================================================
-- Single source of truth: main.lua and _meta.lua both read this, so the build
-- reported in the diagnostics can never be a stale copy again.
Config.VERSION = "0.13.1"

-- ============================================================================
-- Input device discovery
-- ============================================================================
-- Nodes are autodetected: /proc/bus/input/devices is parsed and the node that
-- actually advertises a pen tool (BTN_TOOL_PEN / BTN_TOOL_RUBBER) wins. A
-- hardcoded path is not reliable here -- the digitizer node name and index
-- differ between Kindle models and firmware revisions.
Config.EXTRA_DEVICE_PATHS = {}
-- Tried first, in order, before autodetection. Fill this in only if
-- autodetection picks the wrong node, e.g. { "/dev/input/event3" }.

Config.TOUCH_DEVICE_CANDIDATES = {
    "/dev/input/touch",     -- Kindle Scribe / Scribe 3 / Colorsoft
    "/dev/input/event2",
    "/dev/input/event1",
    "/dev/input/event0",
}
-- Last-resort fallback, used only when nothing above matches. The pen node is
-- blind guessing at this point, so a warning is logged when it is used.

Config.PEN_NAME_HINTS    = { "wacom", "stylus", "pen", "digitizer", "elan", "scrib" }
Config.FINGER_NAME_HINTS = { "touchscreen", "cyttsp", "goodix", "ft5x06", "himax",
                             "synaptics", "atmel", "touch" }

-- BTN_TOOL_PEN / BTN_TOOL_RUBBER: decisive evidence that a node is a digitizer.
Config.PEN_KEY_BITS = { 0x140, 0x141 }

-- ============================================================================
-- evdev constants (linux/input-event-codes.h)
-- ============================================================================
Config.EV_SYN                    = 0x00
Config.EV_KEY                    = 0x01
Config.EV_ABS                    = 0x03

Config.SYN_REPORT                = 0x00

Config.BTN_TOUCH                 = 0x14a
Config.BTN_TOOL_PEN              = 0x140
Config.BTN_TOOL_RUBBER           = 0x141

Config.ABS_X                     = 0x00
Config.ABS_Y                     = 0x01
Config.ABS_PRESSURE              = 0x18
Config.ABS_MT_SLOT               = 0x2f
Config.ABS_MT_POSITION_X         = 0x35
Config.ABS_MT_POSITION_Y         = 0x36
Config.ABS_MT_TOOL_TYPE          = 0x37
Config.ABS_MT_TRACKING_ID        = 0x39
Config.ABS_MT_PRESSURE           = 0x3a

Config.TOOL_FINGER               = 0
Config.TOOL_PEN                  = 1
Config.TOOL_ERASER               = 2
Config.TOOL_HIGHLIGHTER          = 3

-- ============================================================================
-- Pen behaviour
-- ============================================================================
Config.MIN_MOVE_DISTANCE_PX      = 2

Config.DEFAULT_WIDTH             = 3
Config.MIN_WIDTH                 = 1
Config.MAX_WIDTH                 = 24
Config.WIDTH_PRESETS             = { 1, 2, 3, 5, 8, 12, 16, 24 }

Config.DEFAULT_COLOR             = "black"

-- Palette entries: { key, gettext label, 8-bit gray level (0-255) }
-- Gray levels are resolved to Blitbuffer colours at runtime in canvas.lua.
Config.COLOR_PALETTE = {
    { "black",  _("Black"),     0x00 },
    { "gray25", _("Gray 25%"),  0x40 },
    { "gray50", _("Gray 50%"),  0x80 },
    { "gray75", _("Gray 75%"),  0xc0 },
    { "white",  _("White"),     0xff },
}

-- ============================================================================
-- Input source
-- ============================================================================
-- Default only: the effective value is stored in the global reader settings
-- and can be switched at runtime from "Pencil handwriting -> Input source".
--   "auto"    -- prefer KOReader's stylus API, fall back to evdev
--   "stylus"  -- only the KOReader stylus callback (>= 2026.07.2-60 nightly)
--   "evdev"   -- only read the digitizer node ourselves
-- The stylus API is strongly preferred: KOReader has already parsed the node,
-- knows which slot belongs to the pen, and lets the callback *dominate* the
-- event so a pen stroke can never be interpreted as a page-turn swipe.
Config.INPUT_SOURCE = "auto"

-- Coordinates handed to the stylus callback are raw digitizer values, which
-- normally already are native (portrait) panel pixels -- the space strokes are
-- stored in. If a device reports in its own units instead, "auto" notices the
-- out-of-range values, opens the digitizer node read-only to learn its axis
-- ranges, and scales them into place. The screen rotation is applied
-- separately, at draw time, by pencilhw/geometry.
Config.STYLUS_COORD_CORRECTION = "auto"     -- "auto" | "none"

-- ============================================================================
-- Coordinate handling
-- ============================================================================
-- The digitizer reports absolute coordinates in its own units, which do not
-- have to match the panel resolution. When the node exposes ABS_X/ABS_Y or
-- the multitouch equivalents, their min/max are read with EVIOCGABS and the
-- values are scaled into screen pixels. Set to false if the ranges are
-- reported wrongly and strokes end up scaled.
Config.AUTO_SCALE_RAW            = true

-- ============================================================================
-- Pen-only input
-- ============================================================================
-- Skin must never write. The slot and the tool reported for an event are not
-- enough to tell the pen from a hand: KOReader's touch layer writes its contacts
-- into whichever slot is *current*, and that is the pen slot as soon as the pen
-- has been seen -- so a finger arrives with the pen's slot number and whatever
-- tool and contact id the pen left behind in it, looking exactly like the pen.
-- (The diagnostics' "Last slot" line prints everything the input layer reported.)
--
-- What a hand cannot fake is the path: the digitizer tracks the pen and nothing
-- else, so pen samples form a continuous line, while a contact on the far side of
-- the screen is a jump no pen tip can make between two samples. Such a sample is
-- dropped instead of drawn, which is what turns a hand landing on the page into
-- no ink at all rather than a straight line right across it.
Config.PEN_ONLY_GATE               = true

-- The shortest distance that is already too far for one pen sample: the floor
-- for slow movement (90 px ~ 7 mm on the 1860x2480 panel).
Config.PEN_MAX_JUMP_PX             = 90

-- How fast a pen tip may be travelling, in panel px per second (~97 cm/s). The
-- limit grows with the time since the last sample, so a fast stroke -- or a
-- digitizer with a low sample rate -- is not mistaken for a hand.
Config.PEN_MAX_SPEED_PX_S          = 12000

-- ...but it stops growing here: a hand resting on the page for a second must not
-- "become" the pen just because time passed (~3.2 cm).
Config.PEN_MAX_JUMP_CAP_PX         = 400

-- After this long without a single pen event, the remembered pen position is
-- stale and the next contact is believed again, whatever its distance: a pen put
-- down and picked up somewhere else must be able to start writing there.
Config.PEN_ANCHOR_MAX_AGE_MS       = 1500

-- ============================================================================
-- Pen origin oracle
-- ============================================================================
-- Everything above is a guess: it infers "was this the pen?" from the shape of
-- the path, and a hand that lands close enough to the nib beats it. There is a
-- way to *know* instead, and the hardware hands it over for free.
--
-- On this device the digitizer is its own input node and the capacitive layer is
-- another one, so the digitizer node reports the pen and nothing else.
-- KOReader never grabs an input node (checked in frontend/device/input.lua and
-- frontend/device/kindle/device.lua), and evdev delivers every event to every
-- open descriptor, so the plugin can open that node read-only, *without*
-- grabbing it, and just listen. That yields the two facts the stylus callback
-- cannot supply about itself:
--
--   * whether the pen tip is on the glass right now (the node's own BTN_TOUCH),
--   * where the pen tip is (the node's own ABS_X / ABS_Y).
--
-- A sample that claims a pen contact while the digitizer says the tip is up, or
-- that lands nowhere near where the digitizer puts the tip, did not come from
-- the pen. Nothing is inferred, and no threshold takes part in the decision.
--
-- By the time the callback runs, the whole frame is already sitting in our
-- queue (the kernel queues to every reader at emission time), so the listener is
-- drained right there instead of from a timer: there is no race against
-- KOReader's own read.
--
-- ---------------------------------------------------------------- trust ----
-- Every one of those facts is only as good as the listener that reports it, and
-- a listener that is reading the wrong thing does not say "I cannot tell" -- it
-- says "not the pen" to everything, which means *nothing is ever drawn*. There
-- is no error message for that: "no ink" and "no pen" look exactly alike from
-- the outside, and it is a whole session's work that goes missing.
--
-- So the three claims below are trusted separately, and each one has to be
-- earned by the pen itself before it is allowed to take ink away:
--
--   * "the pen tool is not active on this node"     -- earned by any hover
--   * "the tip is not on the glass"                 -- earned by any contact
--   * "this contact is not where the pen is"        -- earned by one agreement
--
-- A working device earns all three within the first stroke, so nothing is lost;
-- a mis-detected node, or one whose coordinates are in other units, never earns
-- the claims it cannot back up and is simply ignored instead of being believed.
Config.PEN_ORACLE                  = true

-- The listener is only trusted once it has proved it is receiving. A
-- descriptor that never delivers a frame cannot be told from a pen that is never
-- used, and believing it would classify every sample as "not the pen" -- that
-- is, draw nothing at all. Until then the gate above keeps working as before.
Config.PEN_ORACLE_MIN_FRAMES       = 8

-- How far a sample may sit from where the digitizer reports the tip and still
-- count as the pen. Both sides are in the plugin's own coordinate space, so
-- this only has to absorb sampling skew between the two readers (~120 px, ~1 cm
-- on the 1860x2480 panel).
--
-- It is also the number the *first agreement* is measured against: until one
-- contact has landed inside it, the two sides have not been shown to be the same
-- coordinate space at all, and a distance between two different spaces is not
-- evidence of anything (see classifyStylusOrigin). Until then the gate above
-- decides, which is what keeps a listener with the wrong units from eating every
-- stroke.
Config.PEN_ORACLE_POS_TOL_PX       = 120

-- The listener's own health check: a listener that has examined this many
-- samples without ever once recognising the pen -- no hover, no agreement -- is
-- not reading the digitizer at all. It is harmless by then (it has earned none
-- of the three claims, so it is being ignored rather than believed), and this
-- only exists to stop it reading a useless descriptor for the rest of the
-- session and to say so in the diagnostics.
Config.PEN_ORACLE_MAX_SILENT       = 40

-- How long "the pen is around" lasts after the last pen event, for the block
-- that covers hold and double-tap only (see touchBlockWanted). A palm that stays
-- where it landed after a stroke is a hold, and a hold opens a dialog in the
-- middle of the page -- but a *finger* turning the page does it with a swipe,
-- which no tap-shaped zone matches, so this window costs nothing that was asked
-- for.
Config.PEN_NEAR_WINDOW_MS          = 2500

-- ============================================================================
-- Touch blocking, revisited
-- ============================================================================
-- Finger input has to keep working while drawing: turning the page with a finger
-- is an ordinary thing to do between strokes, so covering the whole session is
-- the wrong default -- which is why Config.BLOCK_TOUCH_DEFAULT is false and the
-- switch below is about how much *more* than the contact window to cover.
--
-- What is left is the one window where a touch cannot be anything but a hand:
-- while the pen tip is on the glass. Nothing deliberate is done with a finger at
-- that moment, and it is exactly when a palm comes to rest on the page. So the
-- block covers the contact window, plus a short tail for the hand following the
-- pen as it lifts.
Config.PEN_CONTACT_TOUCH_BLOCK     = true
Config.PEN_CONTACT_BLOCK_TAIL_MS   = 400

-- ============================================================================
-- Input interception
-- ============================================================================
-- Grabbing the node exclusively means KOReader's own gesture detector never
-- sees the pen. It only matters when the pen shares one node with the
-- capacitive layer; if it does not, grabbing is unnecessary. It is dangerous
-- on a shared node (finger input would die), so it stays opt-in.
Config.EXCLUSIVE_GRAB_DEFAULT    = false

-- Swallow touch gestures while drawing so a resting palm or wrist does not
-- turn pages. Off by default, and it now only escalates: with it off the
-- contact window below still protects the pen-down moment, while turning it on
-- extends the block to the whole writing session -- which costs the finger
-- gestures that are wanted the rest of the time.
Config.BLOCK_TOUCH_DEFAULT       = false

-- Taps inside the top strip must keep opening the reader menu, otherwise
-- touch blocking would make the menu unreachable. Ratio of screen height.
Config.MENU_STRIP_RATIO          = 0.12

-- What a switch called "block touch while drawing" has to cover, in layers.
-- A touch zone matches exactly one gesture name -- GestureRange compares `ges`
-- with ==, so passing a list of names never matches anything -- and a resting
-- palm is not only a tap: it holds still long enough to be a hold, and it gets
-- dragged along with the hand.
--
--   * the tap zone (always on with the switch above);
--   * one more zone per stationary-contact gesture below: a hand resting on the
--     screen makes those *before* the pen lands, so there is no pen event yet
--     to gate on;
--   * Config.PEN_TOUCH_BLOCK while the pen is on the glass, which covers every
--     dragging gesture at once.
Config.BLOCK_HOLD_GESTURES       = true
Config.BLOCK_DOUBLE_TAP          = true

-- Deliberately NOT blocked: two_finger_tap. The diagonal two-finger tap is
-- KOReader's screenshot gesture, and a screenshot is the cheapest way to get a
-- page of handwriting off the device -- a zone that swallowed it would cost
-- more than the stray palm it would catch.
Config.BLOCK_TWO_FINGER_TAP      = false

-- The switch's upper level: touch input is switched off globally
-- (InputContainer:setIgnoreTouchInput) for as long as the pen tool is around --
-- hovering counts -- so a wrist dragged across the screen cannot turn a page in
-- the middle of a stroke, and it is held a little past the pen leaving. It
-- covers the whole session, which is why it stays behind the switch: it takes
-- finger gestures away with it.
Config.PEN_TOUCH_BLOCK           = true

-- Tail for the level above: the hand usually leaves the screen after the pen
-- does, and a swipe is only recognised when the finger lifts, so the block
-- outlives the stroke a little. Long enough to cover the hand following the pen,
-- short enough that a finger tap right afterwards still counts.
Config.PEN_TOUCH_BLOCK_TAIL_MS   = 700

-- Watchdog: a lost BTN_TOUCH release must not leave touch switched off until
-- the reader is restarted. When the pen reports nothing at all for this long,
-- the block is dropped.
Config.PEN_TOUCH_BLOCK_QUIET_MS  = 15000

-- ============================================================================
-- Eraser
-- ============================================================================
Config.ERASER_RADIUS_PX          = 24

-- An erase pass only rescans when the eraser has moved this far, and no more
-- often than the given interval. The scan is linear in the number of points
-- stored for the page, and erase events arrive at the digitizer rate, so
-- without throttling a heavily annotated page stalls the input loop.
-- The interval is kept short enough that consecutive scans stay closer
-- together than the eraser disc's diameter, so coverage has no holes.
Config.ERASE_MIN_MOVE_PX         = 4
Config.ERASE_MIN_INTERVAL_S      = 0.02

-- Repainting the page is expensive, so erases coalesce into at most one
-- repaint per window. Lifting the eraser always forces a final repaint.
-- Flooding the refresh queue instead is what made the device appear frozen.
Config.ERASE_REFRESH_MS          = 400

-- ============================================================================
-- Refresh strategy
-- ============================================================================
-- After the pen lifts: persist, then one proper refresh that also clears the
-- ghosting the fast partial refreshes leave behind.
Config.REFRESH_SETTLE_MS         = 600

-- How long after a page change the page-identity accessors are re-read, to
-- find out whether they track pages at all. Delayed on purpose: the document's
-- own fields can still hold the old page at the instant the page-change event
-- fires, so probing immediately would blame a healthy accessor.
Config.KEY_AUDIT_DELAY_S         = 0.4

-- ============================================================================
-- Page identity
-- ============================================================================
-- A stroke is filed under a page identifier and the same identifier decides
-- which strokes are painted. Deriving it two different ways in the write path
-- and in the paint path is exactly what makes one stroke show up on two pages
-- -- so main.lua keeps a single value (self.page_key), resolved in one place
-- and updated the moment a page-change event arrives.
--
-- There is deliberately no menu switch for this. The document accessors were
-- measured *lagging behind* the page turn on this build (crash.log: a page
-- change to 40, and `ui.paging.current_page` still reporting 39 four tenths of
-- a second later), and a lagging identity paints one page's strokes onto its
-- neighbour -- so a switch was a way to break the plugin by accident. The
-- identity is chosen automatically:
--
--   paged documents (PDF, DjVu, CBZ) -> the PageUpdate event page
--   reflowable documents (EPUB, FB2) -> the accessor chain, xpointer first
--
-- The values are:
--   "auto" -- as described above (the only supported setting)
--   "live" -- source-level debug: always the accessor chain, even for paged
--             documents. Expect ink on the neighbouring page; used only to
--             compare what the accessors report against the event.
-- Whatever is chosen, the diagnostics print the event page, the identity in
-- use, and what every accessor returns.
Config.PAGE_KEY_SOURCE           = "auto"

-- Menu switch: force the panel clean-up on *every* page turn, not only the
-- pages that have ink on them. Only useful as a test -- the diagnostics show
-- whether it is on.
Config.FULL_REFRESH_ON_PAGE_CHANGE = false

-- What happens to the panel when a page has been written on and is then left.
--
-- Ink is drawn straight into the framebuffer, so it is not part of KOReader's
-- page image. A page turn repaints the framebuffer correctly, but the *panel*
-- is only given a non-flashing update, and that does not erase solid black ink:
-- the strokes from the page you just left stay visible as a ghost on the next
-- one. Text ghosts far less than a pen stroke, which is why only the ink
-- follows you.
--
--   "on_ink" -- one flashing full refresh after a turn, only when the page
--               being left has ink on it (default). Pages you have not written
--               on keep KOReader's normal, fast, flash-free turn.
--   "always" -- flash on every page turn
--   "off"    -- never; KOReader's own refresh decision stands
Config.PAGE_EXIT_CLEANUP = "on_ink"

-- The refresh mode used for that clean-up. "full" flashes the whole screen,
-- which is what actually removes the ghost; "flashui" and "ui" are gentler and
-- may leave a trace of heavy ink.
Config.PAGE_EXIT_REFRESH_MODE = "full"

-- Guard for a long stroke drawn without ever lifting the pen: one real refresh
-- every few seconds. Note that a refresh *includes* the strokes, it does not
-- replace them, so this is only about ghosting, never about data loss.
Config.REFRESH_GHOST_MS          = 8000

Config.POLL_INTERVAL_S           = 0.008

-- ============================================================================
-- Persistence
-- ============================================================================
Config.SIDECAR_FILENAME          = "pencil_handwriting.lua"
Config.STROKE_FORMAT_VERSION     = 2

-- Same strokes, as JSON, written next to the sidecar by the menu's
-- "Export stroke data (JSON)". The .lua file is what the *device* reads back;
-- the JSON copy exists for everything else (a desktop script, the pencil-ink
-- web service, a phone): it needs no Lua parser and no file manager that
-- understands a .sdr directory.
Config.JSON_EXPORT_FILENAME      = "pencil_handwriting.json"

-- The document's own fingerprint (file name, format, page count, size in bytes)
-- goes into both files. Without it there is no way to tell "these strokes belong
-- to *this* PDF" from "these strokes belong to a different file that happens to
-- have the same kind of page numbers" -- and mismatched strokes look perfectly
-- plausible, just in the wrong places. Costs one stat and one page count, once
-- per document.
Config.DOC_FINGERPRINT           = true

-- Stroke coordinates are stored in document *page* space (document pixels at
-- scale 1, measured with the reader's own screenToPageTransform) so the ink
-- stays attached to the content it was written on: scrolling, zooming or a page
-- that only occupies part of the screen then cannot slide the handwriting over
-- to another part of the page -- or over the neighbouring page.
--
-- Files written by version 1 are still read: their strokes are panel pixels and
-- are tagged "native" on load, so they keep being drawn the old way.
Config.STORE_IN_PAGE_SPACE       = true

-- ============================================================================
-- Helpers
-- ============================================================================
-- Kept lazy on purpose: a failure here must never break plugin load.
function Config.isKindleScribe()
    local ok, device = pcall(require, "device")
    if not ok or not device or not device.model then return false end
    return device.model:match("^KindleScribe") ~= nil
end

function Config.colorKeyForLevel(level)
    for _, entry in ipairs(Config.COLOR_PALETTE) do
        if entry[3] == level then return entry[1] end
    end
    return "black"
end

return Config

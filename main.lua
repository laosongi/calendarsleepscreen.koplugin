--[[--
息屏万年历：设备进入休眠屏（息屏）时，显示当月万年历（公历 + 农历）、
当前时间与日期、节日对照。

接管原理：包装 `ui/screensaver` 的 `show()`。插件启用时用自绘的万年历
widget 替换默认睡眠屏内容；禁用、或遇到关机/重启等特殊流程（prefix 事件）
时，自动回退到 KOReader 原生睡眠屏逻辑。
--]]--

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ScreenSaverWidget = require("ui/widget/screensaverwidget")
local ScreenSaverLockWidget = require("ui/widget/screensaverlockwidget")
local LineWidget = require("ui/widget/linewidget")
local Screensaver = require("ui/screensaver")
local logger = require("logger")
local _ = require("gettext")

local Lunar = require("calendarsleepscreen_lunardate")
local PluginShare = require("pluginshare")

local Screen = Device.screen

-- 设置保存于 G_reader_settings 的子表中，settings_key 供插件管理器清理
local SETTING_KEY = "calendarsleepscreen"

local function getSettings()
    return G_reader_settings:readSetting(SETTING_KEY, { enabled = false })
end

local function isEnabled()
    local s = getSettings()
    return s ~= nil and s.enabled == true
end

local function setEnabled(v)
    local s = getSettings()
    s.enabled = v and true or false
    G_reader_settings:saveSetting(SETTING_KEY, s)
end

-- KOReader 内置 CJK 字体；异常时回退到默认 UI 字体
local function getCJKFace(size)
    local ok, face = pcall(Font.getFace, Font, "cfont", size)
    if ok and face then return face end
    return Font:getFace("infofont", size)
end

-- 水平边距（随屏幕比例缩放）
local function getMargin()
    return math.floor(Screen:getWidth() / 24)
end

--[[ 动态刷新状态：保存时间 TextWidget 引用用于每分钟局部刷新，
     以及当前屏保 widget 用于局部重绘。
     凌晨 1:00-7:00 恢复系统挂起（不刷新，省电）。 --]]
local cal_state = { time_tw = nil, time_dimen = nil, widget = nil }
local auto_refresh_time, auto_refresh_date

-- 独立追踪日志（不依赖 crash.log，便于每次息屏都记录）
local function trace(msg)
    local f = io.open("/tmp/cal_trace.log", "a")
    if f then
        f:write(os.date("%H:%M:%S ") .. tostring(msg) .. "\n")
        f:close()
    end
end

-- lipc flIntensity(0-24) → sysfs brightness(0-4095) 映射表（PW3 max77696-bl，实测）
-- 充电息屏唤醒时系统不自动映射 brightness，需手动写
local FL_MAP = { 1, 3, 6, 9, 12, 15, 18, 21, 24 }
local FL_BRIGHT = { 2, 4, 28, 120, 336, 775, 1382, 2195, 3280 }
local function fl_to_brightness(fl)
    if fl <= FL_MAP[1] then return FL_BRIGHT[1] end
    if fl >= FL_MAP[#FL_MAP] then return FL_BRIGHT[#FL_BRIGHT] end
    for i = 1, #FL_MAP - 1 do
        local a, b = FL_MAP[i], FL_MAP[i + 1]
        if fl >= a and fl <= b then
            local ba, bb = FL_BRIGHT[i], FL_BRIGHT[i + 1]
            return math.floor(ba + (fl - a) * (bb - ba) / (b - a))
        end
    end
    return FL_BRIGHT[#FL_BRIGHT]
end

-- 不主动保持唤醒（不设 preventScreenSaver，避免与 Kindle 电源状态机冲突导致卡电源）。
-- 靠"插着充电器时 Kindle 不自动睡眠"的自然特性：充电时每分钟刷新定时器能继续跑、时间持续走；
-- 未充电时设备真挂起，时间停息屏时刻、唤醒更新。
local function pauseAutoSuspend()
end

local function resumeAutoSuspend()
    if Device:isKindle() then
        PluginShare.pause_auto_suspend = false
        PluginShare.keepalive = false
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver 0")
    end
end

-- 距下次跨午夜（日期变化）的秒数
local function getNextDayRefreshInSeconds()
    return (24 - tonumber(os.date("%H"))) * 3600
end

-- 每分钟刷新顶部时间（局部重绘，省电）；凌晨1-7点不刷新并允许真挂起
auto_refresh_time = function()
    local h = tonumber(os.date("%H"))
    if h >= 1 and h < 7 then
        resumeAutoSuspend()
        UIManager:unschedule(auto_refresh_date)
        return
    end
    -- 不设 preventScreenSaver（避免卡电源）：充电时 Kindle 自然不睡眠，定时器继续跑、时间持续走；
    -- 未充电时真挂起定时器停（时间停息屏时刻，唤醒更新）。
    if cal_state.time_tw and cal_state.widget then
        local t = os.date("*t")
        cal_state.time_tw:setText(string.format("%02d:%02d", t.hour, t.min))
        cal_state._rc = (cal_state._rc or 0) + 1
        if cal_state._rc % 10 == 0 then
            -- 每10分钟全刷一次，彻底清除累积残影
            UIManager:setDirty(cal_state.widget, "full")
        else
            -- 放大刷新区域到整个屏幕（partial 波形），墨水翻转更均匀，减轻局部残影
            UIManager:setDirty(cal_state.widget, "partial")
        end
    end
    UIManager:scheduleIn(61 - tonumber(os.date("%S")), auto_refresh_time)
end


local function attachSaverCleanup(widget)
    widget.onCloseWidget = function()
        resumeAutoSuspend()
        UIManager:unschedule(auto_refresh_time)
        UIManager:unschedule(auto_refresh_date)
        -- 唤醒关闭万年历 widget 时重置 Device 屏保标志：
        -- 原生 close_widget 不重置它，会残留 true，导致后续息屏 intoScreenSaver 跳过万年历接管（"首次显示、后续不显示"根因）
        if Device and Device.screen_saver_mode ~= nil then
            Device.screen_saver_mode = false
            trace("reset screen_saver_mode=false on wake")
        end
        -- 恢复背光：充电息屏唤醒时系统不自动开 bl_power 也不映射 brightness → 手动写 sysfs 打开硬件 + 写亮度
        local ok_light = pcall(function()
            local ffiUtil = require("ffi/util")
            local bl = "/sys/class/backlight/max77696-bl"
            ffiUtil.writeToSysfs(31, bl .. "/bl_power")
            local fl = Device.powerd and Device.powerd.fl_intensity or 0
            ffiUtil.writeToSysfs(fl_to_brightness(fl), bl .. "/brightness")
        end)
        trace("manual frontlight on: " .. tostring(ok_light))
    end
end

local function startAutoRefresh()
    UIManager:scheduleIn(61 - tonumber(os.date("%S")), auto_refresh_time)
    UIManager:scheduleIn(getNextDayRefreshInSeconds(), auto_refresh_date)
end

--[[ 绘制万年历内容 widget（息屏与预览共用）。
     需在旋转到竖屏后调用，尺寸取自当前屏幕。
     返回：内容 widget，失败返回 nil + 错误信息 --]]
local function buildCalendarContent()
    local t = os.date("*t")
    local today = Lunar.solar2lunar(t.year, t.month, t.day)
    if not today then
        return nil, "solar2lunar failed (check device date, must be 1900-3000)"
    end

    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local margin = getMargin()
    local inner_w = screen_w - 2 * margin
    local inner_h = screen_h - 2 * margin

    -- 跟随系统设定：读取系统正文字号与字体作为基准
    local sys_size = G_reader_settings:readSetting("copt_font_size") or math.floor(screen_w / 28)
    local sys_font = "cfont"  -- 用内置CJK字体；不用 cre_font(Microsoft YaHei)，KOReader 无法解析该名导致屏保接管失败
    local function getFace(size)
        local ok, face = pcall(Font.getFace, Font, sys_font, size)
        if ok and face then
            return face
        end
        local ok2, face2 = pcall(Font.getFace, Font, "cfont", size)
        return ok2 and face2 or nil
    end
    local time_size = math.max(36, math.floor(sys_size * 3))
    local date_size = math.floor(sys_size * 1.4)
    local lunar_size = math.floor(sys_size * 1.1)
    local wday_size = math.floor(sys_size * 1.0)
    local day_size = math.floor(sys_size * 1.3)
    local cell_lunar_size = math.max(8, math.floor(sys_size * 0.8))

    -- 自适应字号：保证文字单行完整显示、不换行
    local function fit(text, base, maxw)
        local size = base
        while size > 6 do
            local face = getFace(size)
            if face and TextWidget:new{ text = text, face = face }:getSize().w <= maxw then
                return face
            end
            size = size - 1
        end
        return getFace(base)
    end

    -- 上半区：时间 / 日期 / 农历，之间加分割线
    cal_state.time_tw = TextWidget:new{
        text = string.format("%02d:%02d", t.hour, t.min),
        face = getFace(time_size),
    }
    cal_state.time_dimen = Geom:new{ x = 0, y = margin, w = screen_w, h = time_size }
    local time_w = CenterContainer:new{
        dimen = Geom:new{ w = inner_w, h = time_size },
        cal_state.time_tw,
    }
    local date_text = string.format("%d年%d月%d日 星期%s", t.year, t.month, t.day, today.weekdayCn)
    local date_face = fit(date_text, date_size, inner_w)
    local date_tw = TextWidget:new{ text = date_text, face = date_face }
    local date_w = CenterContainer:new{
        dimen = Geom:new{ w = inner_w, h = date_tw:getSize().h },
        date_tw,
    }
    local lunar_line = string.format("%s年(%s) 农历%s%s", today.gzYear, today.animal, today.imonthCn, today.idayCn)
    local festive = today.festival or today.lunarFestival
    if festive then
        lunar_line = lunar_line .. " · " .. festive
    end
    local lunar_face = fit(lunar_line, lunar_size, inner_w)
    local lunar_tw = TextWidget:new{ text = lunar_line, face = lunar_face }
    local lunar_w = CenterContainer:new{
        dimen = Geom:new{ w = inner_w, h = lunar_tw:getSize().h },
        lunar_tw,
    }
    local sep = function()
        return VerticalGroup:new{
            VerticalSpan:new{ width = math.floor(margin / 3) },
            LineWidget:new{ dimen = Geom:new{ w = inner_w, h = 1 }, background = Blitbuffer.COLOR_BLACK },
            VerticalSpan:new{ width = math.floor(margin / 3) },
        }
    end
    local header = VerticalGroup:new{ time_w, sep(), date_w, sep(), lunar_w }
    local header_h = header:getSize().h

    -- 日历网格
    local days = Lunar.solarDays(t.year, t.month)
    local grid, first_col = Lunar.getMonthGrid(t.year, t.month)
    if not grid or days < 0 then
        return nil, "getMonthGrid failed"
    end
    local rows = math.ceil((first_col + days) / 7)

    local cell_w = math.floor(inner_w / 7)
    local cell_h = math.floor((inner_h - header_h - margin) / (rows + 1))

    -- 表头（周日开头：日 一 二 三 四 五 六）
    local wday_names = { "日", "一", "二", "三", "四", "五", "六" }
    local week_header = HorizontalGroup:new{}
    for c = 0, 6 do
        table.insert(week_header, CenterContainer:new{
            dimen = Geom:new{ w = cell_w, h = cell_h },
            TextWidget:new{
                text = wday_names[c + 1],
                face = getFace(wday_size),
            },
        })
    end

    -- 日期行：每格上为公历日、下为农历日；当天黑底白字
    local cal_rows = VerticalGroup:new{}
    table.insert(cal_rows, week_header)
    for r = 0, rows - 1 do
        local row = HorizontalGroup:new{}
        for c = 0, 6 do
            local day = r * 7 + c - first_col + 1
            local cell
            if day >= 1 and day <= days then
                local is_today = day == t.day
                local dface = fit(tostring(day), day_size, cell_w - 4)
                local lface = fit(grid[day].lunarTxt, cell_lunar_size, cell_w - 4)
                cell = VerticalGroup:new{
                    CenterContainer:new{
                        dimen = Geom:new{ w = cell_w, h = math.floor(cell_h / 2) },
                        TextWidget:new{
                            text = tostring(day),
                            face = dface,
                            fgcolor = is_today and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
                        },
                    },
                    CenterContainer:new{
                        dimen = Geom:new{ w = cell_w, h = math.floor(cell_h / 2) },
                        TextWidget:new{
                            text = grid[day].lunarTxt,
                            face = lface,
                            fgcolor = is_today and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_DARK_GRAY,
                        },
                    },
                }
                cell = FrameContainer:new{
                    bordersize = 0,
                    padding = 0,
                    margin = 0,
                    background = is_today and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
                    cell,
                }
            else
                -- 空占位，保持列对齐
                cell = CenterContainer:new{
                    dimen = Geom:new{ w = cell_w, h = cell_h },
                    HorizontalSpan:new{ width = 0 },
                }
            end
            table.insert(row, cell)
        end
        table.insert(cal_rows, row)
    end

    local body = VerticalGroup:new{
        header,
        VerticalSpan:new{ width = math.floor(margin / 3) },
        LineWidget:new{ dimen = Geom:new{ w = inner_w, h = 1 }, background = Blitbuffer.COLOR_BLACK },
        VerticalSpan:new{ width = math.floor(margin / 3) },
        cal_rows,
    }
    return FrameContainer:new{
        bordersize = 0,
        padding = margin,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            body,
        },
    }
end

-- 每天跨午夜重建整个万年历（更新日历网格/农历/日期）
-- 注意：需在 buildCalendarContent 定义之后，否则 Lua 局部作用域解析不到
auto_refresh_date = function()
    local h = tonumber(os.date("%H"))
    if h >= 1 and h < 7 then
        resumeAutoSuspend()
        return
    end
    local ok, content = pcall(buildCalendarContent)
    if ok and content and cal_state.widget then
        UIManager:close(cal_state.widget)
        local w = ScreenSaverWidget:new{
            widget = content,
            background = Blitbuffer.COLOR_WHITE,
            covers_fullscreen = true,
        }
        w.modal = true
        w.dithered = true
        cal_state.widget = w
        attachSaverCleanup(w)
        UIManager:show(w, "full")
    end
    UIManager:scheduleIn(getNextDayRefreshInSeconds(), auto_refresh_date)
end

local function installSaverPatch()
    if patch_installed then return end
    patch_installed = true

    local origShow = Screensaver.show
    Screensaver.show = function(self)
        logger.info("cal: show called, prefix=", tostring(self.prefix), " enabled=", tostring(isEnabled()))
        trace("show called prefix=" .. tostring(self.prefix) .. " enabled=" .. tostring(isEnabled()))
        -- 未启用、关机/重启流程（prefix）、或无 UI 实例时走原生逻辑
        if not isEnabled() or (self.prefix ~= nil and self.prefix ~= "") then
            trace("NOT take over, origShow prefix=" .. tostring(self.prefix))
            return origShow(self)
        end

        Device.screen_saver_mode = true
        -- 息屏时转正（竖屏），与原生行为一致；ScreenSaverWidget 关闭时自动恢复
        if Screen:getRotationMode() % 2 == 1 then
            Device.orig_rotation_mode = Screen:getRotationMode()
            Screen:setRotationMode(Screen.DEVICE_ROTATED_UPRIGHT)
        else
            Device.orig_rotation_mode = nil
        end

        local ok, content = pcall(buildCalendarContent)
        if not ok or not content then
            -- 构建失败（如系统日期异常）时恢复旋转并回退原生睡眠屏
            if Device.orig_rotation_mode then
                Screen:setRotationMode(Device.orig_rotation_mode)
                Device.orig_rotation_mode = nil
            end
            Device.screen_saver_mode = false
            logger.warn("calendarsleepscreen: build failed, fallback to native sleep screen:", content)
            return origShow(self)
        end

        logger.info("cal: take over screensaver")
        trace("take over")
        self.screensaver_widget = ScreenSaverWidget:new{            widget = content,
            background = Blitbuffer.COLOR_WHITE,
            covers_fullscreen = true,
        }
        self.screensaver_widget.modal = true
        self.screensaver_widget.dithered = true
        UIManager:show(self.screensaver_widget, "full")
        -- 手动同步渲染屏保 widget 到 framebuffer 并刷新屏幕：确保未充电挂起快时画面也一定上屏。
        -- （UIManager 渲染走异步 tick，未充电挂起会打断它，导致"首次显示、后续不显示"的时好时坏。）
        local painted_ok = pcall(function()
            trace("manual paint start")
            local bb = Screen.bb
            bb:fill(Blitbuffer.COLOR_WHITE)
            self.screensaver_widget:getSize()
            self.screensaver_widget:paintTo(bb, 0, 0)
            Screen:refreshFull(0, 0, Screen:getWidth(), Screen:getHeight())
        end)
        if not painted_ok then
            trace("manual paint FAILED, fallback forceRePaint")
            UIManager:forceRePaint()
        else
            trace("manual paint ok")
        end

        -- 记录屏保 widget 供每分钟刷新；不设 keepalive，充电时自然刷新、未充电真挂起
        cal_state.widget = self.screensaver_widget
        attachSaverCleanup(self.screensaver_widget)
        pauseAutoSuspend()
        startAutoRefresh()

        -- 尊重"手势解锁"设置
        if Device:isTouchDevice()
                and G_reader_settings:readSetting("screensaver_delay") == "gesture" then
            self.screensaver_lock_widget = ScreenSaverLockWidget:new{ ui = self.ui }
            UIManager:show(self.screensaver_lock_widget)
        end
    end
end

local CalendarSleepScreen = WidgetContainer:extend{
    name = "calendarsleepscreen",
    is_doc_only = false,
    settings_key = SETTING_KEY,
}

function CalendarSleepScreen:init()
    installSaverPatch()
    if self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
end

-- 亮屏状态下预览息屏效果；点按或按键退出
function CalendarSleepScreen:preview()
    local ok, content = pcall(buildCalendarContent)
    if not ok or not content then
        UIManager:show(InfoMessage:new{
            text = _("预览失败：") .. tostring(content),
        })
        return
    end

    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local container = InputContainer:new{ modal = true }
    container.dimen = Geom:new{ w = screen_w, h = screen_h }
    container[1] = FrameContainer:new{
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        content,
    }
    if Device:isTouchDevice() then
        container.ges_events.Tap = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{ x = 0, y = 0, w = screen_w, h = screen_h },
            },
        }
    end
    if Device:hasKeys() then
        container.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end
    function container:onTap()
        UIManager:close(self)
        return true
    end
    container.onAnyKeyPressed = container.onTap
    function container:onCloseWidget()
        UIManager:setDirty(nil, "full")
    end
    UIManager:show(container, "full")
end

function CalendarSleepScreen:addToMainMenu(menu_items)
    menu_items.calendarsleepscreen = {
        text = _("息屏万年历"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("启用息屏万年历"),
                checked_func = function() return isEnabled() end,
                callback = function(touchmenu_instance)
                    setEnabled(not isEnabled())
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
            {
                text = _("预览效果"),
                callback = function()
                    self:preview()
                end,
            },
            {
                text = _("使用说明"),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = _("息屏时显示当月万年历、农历与息屏那一刻的时间。\n\n电纸书休眠后屏幕不再刷新，时间停留在息屏时刻；唤醒后再息屏会自动更新。\n息屏期间按开机键或轻触即可唤醒。"),
                    })
                end,
            },
        },
    }
end

return CalendarSleepScreen

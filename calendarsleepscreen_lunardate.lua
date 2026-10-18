--[[--
公历 ↔ 农历转换（支持 1900–3000 年），万年历息屏插件的核心算法模块。

数据与算法移植自广泛验证的 JJonline/calendar.js 压缩表实现（含 2033 闰冬月、
2057 年闰月等修正数据）。为兼容 KOReader 的 LuaJIT（Lua 5.1），未使用 bit
库与 5.2+ 特性，位测试采用纯算术实现。
--]]--

local lunarInfo = require("calendarsleepscreen_lunarinfo")

local Lunar = {}

-- 公历平年每月天数
local SOLAR_MONTH = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
-- 天干 / 地支 / 生肖
local GAN = { "甲", "乙", "丙", "丁", "戊", "己", "庚", "辛", "壬", "癸" }
local ZHI = { "子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥" }
local ANIMALS = { "鼠", "牛", "虎", "兔", "龙", "蛇", "马", "羊", "猴", "鸡", "狗", "猪" }
-- 数字转中文
local N_STR1 = { "日", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十" }
local N_STR2 = { "初", "十", "廿", "卅" }
local N_STR3 = { "正", "二", "三", "四", "五", "六", "七", "八", "九", "十", "冬", "腊" }

-- 精简节日表（名称均 ≤ 3 字，避免息屏格子内溢出）
local FESTIVAL = {
    ["1-1"] = "元旦",
    ["5-1"] = "劳动节",
    ["6-1"] = "儿童节",
    ["10-1"] = "国庆节",
}
local L_FESTIVAL = {
    ["12-30"] = "除夕",
    ["1-1"] = "春节",
    ["1-15"] = "元宵",
    ["2-2"] = "龙抬头",
    ["5-5"] = "端午",
    ["7-7"] = "七夕",
    ["8-15"] = "中秋",
    ["9-9"] = "重阳",
    ["12-8"] = "腊八",
}

-- 位测试（等价于 bit.band(x, m) ~= 0），m 必须是 2 的整数次幂
local function hasbit(x, m)
    return x % (m + m) >= m
end

-- 格里高利日数（JDN，1582-10-15 之后有效），可直接推算星期
local function jdn(y, m, d)
    local a = math.floor((14 - m) / 12)
    local yy = y + 4800 - a
    local mm = m + 12 * a - 3
    return d + math.floor((153 * mm + 2) / 5) + 365 * yy
         + math.floor(yy / 4) - math.floor(yy / 100) + math.floor(yy / 400) - 32045
end

-- 农历表基准日：1900-01-31 = 农历 1900 年正月初一
local BASE_JDN = jdn(1900, 1, 31)

-- 农历 y 年的压缩表数据（1 起始）
function Lunar.info(y)
    return lunarInfo[y - 1900 + 1]
end

--- 农历 y 年一整年的总天数
function Lunar.lYearDays(y)
    local info = Lunar.info(y)
    local sum = 348
    local m = 0x8000
    while m > 0x8 do
        if hasbit(info, m) then sum = sum + 1 end
        m = math.floor(m / 2)
    end
    return sum + Lunar.leapDays(y)
end

--- 农历 y 年闰几月（0 = 无闰月）
function Lunar.leapMonth(y)
    return Lunar.info(y) % 16
end

--- 农历 y 年闰月的天数（无闰月则返回 0）
function Lunar.leapDays(y)
    if Lunar.leapMonth(y) > 0 then
        return hasbit(Lunar.info(y), 0x10000) and 30 or 29
    end
    return 0
end

-- 农历 1..12 月的大小位掩码（bit15=正月 .. bit4=腊月）
local MDAY_MASK = { 0x8000, 0x4000, 0x2000, 0x1000, 0x800, 0x400, 0x200, 0x100, 0x80, 0x40, 0x20, 0x10 }

--- 农历 y 年 m 月（非闰月）的天数
function Lunar.monthDays(y, m)
    if m > 12 or m < 1 then return -1 end
    return hasbit(Lunar.info(y), MDAY_MASK[m]) and 30 or 29
end

--- 公历 y 年 m 月的天数
function Lunar.solarDays(y, m)
    if m > 12 or m < 1 then return -1 end
    if m == 2 then
        if (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0 then return 29 end
        return 28
    end
    return SOLAR_MONTH[m]
end

--- 农历年份 → 干支纪年（如 "丙午"）
function Lunar.toGanZhiYear(lYear)
    local gan = (lYear - 3) % 10
    local zhi = (lYear - 3) % 12
    if gan == 0 then gan = 10 end
    if zhi == 0 then zhi = 12 end
    return GAN[gan] .. ZHI[zhi]
end

--- 农历年份 → 生肖
function Lunar.getAnimal(y)
    return ANIMALS[(y - 4) % 12 + 1]
end

--- 农历日数字 → 中文（初十 / 廿三 / 三十）
function Lunar.toChinaDay(d)
    if d == 10 then return "初十"
    elseif d == 20 then return "二十"
    elseif d == 30 then return "三十" end
    return N_STR2[math.floor(d / 10) + 1] .. N_STR1[d % 10 + 1]
end

--- 农历月数字 → 中文月名（正月 / 腊月）
function Lunar.toChinaMonth(m)
    if m > 12 or m < 1 then return -1 end
    return N_STR3[m] .. "月"
end

--- 公历转农历
-- @return table 或 nil（超出支持范围）
-- {
--   year, month, day,        -- 公历年月日
--   weekday = 1..7 (1=周一), weekdayCn = "一".."日",
--   lyear, lmonth, lday,     -- 农历年月日
--   isLeap = 是否闰月,
--   gzYear = "丙午", animal = "马",
--   imonthCn = "闰二月", idayCn = "初三",
--   festival = 阳历节日 or nil, lunarFestival = 农历节日 or nil,
-- }
function Lunar.solar2lunar(y, m, d)
    if y < 1900 or y > 3000 then return nil end
    if y == 1900 and m == 1 and d < 31 then return nil end

    local j = jdn(y, m, d)
    local offset = j - BASE_JDN

    -- 定农历年：逐个农历年扣减
    local lyear = 1900
    local ydays = 0
    while offset >= 0 do
        if lyear > 3000 then return nil end -- 超出压缩表覆盖范围
        ydays = Lunar.lYearDays(lyear)
        if offset < ydays then break end
        offset = offset - ydays
        lyear = lyear + 1
    end

    -- 定农历月、日：月序列 1..12，闰月插在第 leap 月之后（对齐原版 calendar.js 的 --i 回退语义）
    local leap = Lunar.leapMonth(lyear)
    local lmonth = 1
    local isLeap = false
    local days = 0
    while lmonth < 13 and offset > 0 do
        if leap > 0 and lmonth == leap + 1 and not isLeap then
            lmonth = lmonth - 1 -- 回退月号：本轮处理闰月
            isLeap = true
            days = Lunar.leapDays(lyear)
        else
            days = Lunar.monthDays(lyear, lmonth)
        end
        if isLeap and lmonth == leap + 1 then
            isLeap = false -- 闰月之后接着的正常月处理时解除闰月状态
        end
        offset = offset - days
        lmonth = lmonth + 1
    end
    -- 闰月初一特判（对齐原版）
    if offset == 0 and leap > 0 and lmonth == leap + 1 then
        if isLeap then
            isLeap = false
        else
            isLeap = true
            lmonth = lmonth - 1
        end
    end
    if offset < 0 then
        offset = offset + days
        lmonth = lmonth - 1
    end
    local lday = offset + 1

    -- 星期（1=周一 .. 7=周日）
    local weekday = (j + 1) % 7
    if weekday == 0 then weekday = 7 end

    -- 中文描述
    local imonthCn = (isLeap and "闰" or "") .. Lunar.toChinaMonth(lmonth)
    local idayCn = Lunar.toChinaDay(lday)
    -- 节日（含除夕修正：腊月为小月 29 天时，腊月廿九即除夕）
    local festival = FESTIVAL[m .. "-" .. d]
    local lfKey = lmonth .. "-" .. lday
    if lmonth == 12 and lday == 29 and Lunar.monthDays(lyear, 12) == 29 then
        lfKey = "12-30"
    end
    local lunarFestival = L_FESTIVAL[lfKey]

    return {
        year = y, month = m, day = d,
        weekday = weekday,
        weekdayCn = (weekday == 7 and N_STR1[1] or N_STR1[weekday + 1]),
        lyear = lyear, lmonth = lmonth, lday = lday,
        isLeap = isLeap,
        gzYear = Lunar.toGanZhiYear(lyear),
        animal = Lunar.getAnimal(lyear),
        imonthCn = imonthCn,
        idayCn = idayCn,
        festival = festival,
        lunarFestival = lunarFestival,
    }
end

--- 返回公历 y 年 m 月的日历网格数据（供息屏 widget 绘制）
-- @return grid 表（1..当月天数，每项 {day, col, weekdayCn, lunarTxt}），首日列号 col（0=周日..6=周六）
function Lunar.getMonthGrid(y, m)
    local days = Lunar.solarDays(y, m)
    if days < 0 then return nil end
    local first_col = (jdn(y, m, 1) + 1) % 7 -- 周日开头的列号（周日=0..周六=6）
    local grid = {}
    for day = 1, days do
        local r = Lunar.solar2lunar(y, m, day)
        if not r then return nil end
        local lunarTxt
        if r.festival then
            lunarTxt = r.festival
        elseif r.lunarFestival then
            lunarTxt = r.lunarFestival
        elseif r.lday == 1 then
            lunarTxt = r.imonthCn -- 每月初一显示农历月名（闰二月等）
        else
            lunarTxt = r.idayCn
        end
        grid[day] = {
            day = day,
            col = (first_col + day - 1) % 7,
            weekdayCn = r.weekdayCn,
            lunarTxt = lunarTxt,
        }
    end
    return grid, first_col
end

--- 星期表头（1..7 对应 周一..周日）
Lunar.WEEKDAY_CN = { "一", "二", "三", "四", "五", "六", "日" }

return Lunar

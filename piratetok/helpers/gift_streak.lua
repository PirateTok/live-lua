--- Gift streak tracker — computes per-event deltas from TikTok's running totals.
-- TikTok combo gifts fire multiple events during a streak, each carrying a
-- running total in repeat_count (2, 4, 7, 7). This helper tracks active
-- streaks by group_id and computes the delta per event.
local socket = require "socket"

local STALE_SECS = 60

local GiftStreakTracker = {}
GiftStreakTracker.__index = GiftStreakTracker

--- Create a new tracker.
---@return table tracker
function GiftStreakTracker.new()
    return setmetatable({ _streaks = {} }, GiftStreakTracker)
end

--- Process a raw gift event and return enriched streak data with deltas.
---@param gift table decoded WebcastGiftMessage
---@return table enriched event with streakId, isActive, isFinal, eventGiftCount, etc.
function GiftStreakTracker:process(gift)
    local gift_details = gift.gift_details or {}
    local diamond_per = gift_details.diamond_count or 0
    local gift_type = gift_details.gift_type or 0
    local is_combo = gift_type == 1
    local repeat_end = gift.repeat_end or 0
    local is_final = repeat_end == 1
    local group_id = gift.group_id or 0
    local repeat_count = gift.repeat_count or 0

    if not is_combo then
        return {
            streak_id = group_id,
            is_active = false,
            is_final = true,
            event_gift_count = 1,
            total_gift_count = 1,
            event_diamond_count = diamond_per,
            total_diamond_count = diamond_per,
        }
    end

    local now = socket.gettime()
    self:_evict_stale(now)

    local prev_count = 0
    local prev = self._streaks[group_id]
    if prev then prev_count = prev.last_repeat_count end

    local delta = repeat_count - prev_count
    if delta < 0 then delta = 0 end

    if is_final then
        self._streaks[group_id] = nil
    else
        self._streaks[group_id] = {
            last_repeat_count = repeat_count,
            last_seen = now,
        }
    end

    local rc = math.max(repeat_count, 1)

    return {
        streak_id = group_id,
        is_active = not is_final,
        is_final = is_final,
        event_gift_count = delta,
        total_gift_count = repeat_count,
        event_diamond_count = diamond_per * delta,
        total_diamond_count = diamond_per * rc,
    }
end

--- Number of currently active (non-finalized) streaks.
---@return number
function GiftStreakTracker:active_streaks()
    local n = 0
    for _ in pairs(self._streaks) do n = n + 1 end
    return n
end

--- Clear all tracked state. For reconnect scenarios.
function GiftStreakTracker:reset()
    self._streaks = {}
end

function GiftStreakTracker:_evict_stale(now)
    for id, entry in pairs(self._streaks) do
        if now - entry.last_seen >= STALE_SECS then
            self._streaks[id] = nil
        end
    end
end

return GiftStreakTracker

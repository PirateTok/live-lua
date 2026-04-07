--- Like accumulator — monotonizes TikTok's inconsistent total_like_count.
-- TikTok's total field on like events arrives from different server shards
-- with stale values, causing backwards jumps. The count field (per-event
-- delta) is reliable.

local LikeAccumulator = {}
LikeAccumulator.__index = LikeAccumulator

--- Create a new accumulator.
---@return table accumulator
function LikeAccumulator.new()
    return setmetatable({
        _max_total = 0,
        _accumulated = 0,
    }, LikeAccumulator)
end

--- Process a raw like event and return monotonized stats.
---@param like table decoded WebcastLikeMessage (fields: count, total)
---@return table stats with event_like_count, total_like_count, accumulated_count, went_backwards
function LikeAccumulator:process(like)
    local count = like.count or 0
    local total = like.total or 0

    self._accumulated = self._accumulated + count
    local went_backwards = total < self._max_total
    if total > self._max_total then
        self._max_total = total
    end

    return {
        event_like_count = count,
        total_like_count = self._max_total,
        accumulated_count = self._accumulated,
        went_backwards = went_backwards,
    }
end

--- Clear state. For reconnect.
function LikeAccumulator:reset()
    self._max_total = 0
    self._accumulated = 0
end

return LikeAccumulator

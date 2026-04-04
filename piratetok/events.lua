--- Event mapper — decodes protobuf messages into typed events.
-- Sub-routes SocialMessage, MemberMessage, ControlMessage into convenience events.
-- Both raw and convenience events fire for the same message.
local pb = require "pb"

local M = {}

--- Primary message type map.
-- Maps wire type string to proto message name.
local PRIMARY = {
    WebcastChatMessage = "WebcastChatMessage",
    WebcastGiftMessage = "WebcastGiftMessage",
    WebcastLikeMessage = "WebcastLikeMessage",
    WebcastMemberMessage = "WebcastMemberMessage",
    WebcastSocialMessage = "WebcastSocialMessage",
    WebcastRoomUserSeqMessage = "WebcastRoomUserSeqMessage",
    WebcastControlMessage = "WebcastControlMessage",
    WebcastLiveIntroMessage = "WebcastLiveIntroMessage",
    WebcastRoomMessage = "WebcastRoomMessage",
    WebcastCaptionMessage = "WebcastCaptionMessage",
    WebcastGoalUpdateMessage = "WebcastGoalUpdateMessage",
    WebcastImDeleteMessage = "WebcastImDeleteMessage",
    WebcastRankUpdateMessage = "WebcastRankUpdateMessage",
    WebcastPollMessage = "WebcastPollMessage",
    WebcastEnvelopeMessage = "WebcastEnvelopeMessage",
    WebcastRoomPinMessage = "WebcastRoomPinMessage",
    WebcastUnauthorizedMemberMessage = "WebcastUnauthorizedMemberMessage",
    WebcastLinkMicMethod = "WebcastLinkMicMethod",
    WebcastLinkMicBattle = "WebcastLinkMicBattle",
    WebcastLinkMicArmies = "WebcastLinkMicArmies",
    WebcastLinkMessage = "WebcastLinkMessage",
    WebcastLinkLayerMessage = "WebcastLinkLayerMessage",
    WebcastLinkMicLayoutStateMessage = "WebcastLinkMicLayoutStateMessage",
    WebcastGiftPanelUpdateMessage = "WebcastGiftPanelUpdateMessage",
    WebcastInRoomBannerMessage = "WebcastInRoomBannerMessage",
    WebcastGuideMessage = "WebcastGuideMessage",
    WebcastEmoteChatMessage = "WebcastEmoteChatMessage",
    WebcastQuestionNewMessage = "WebcastQuestionNewMessage",
    WebcastSubNotifyMessage = "WebcastSubNotifyMessage",
    WebcastBarrageMessage = "WebcastBarrageMessage",
    WebcastHourlyRankMessage = "WebcastHourlyRankMessage",
    WebcastMsgDetectMessage = "WebcastMsgDetectMessage",
    WebcastLinkMicFanTicketMethod = "WebcastLinkMicFanTicketMethod",
    WebcastRoomVerifyMessage = "WebcastRoomVerifyMessage",
    WebcastOecLiveShoppingMessage = "WebcastOecLiveShoppingMessage",
    WebcastGiftBroadcastMessage = "WebcastGiftBroadcastMessage",
    WebcastRankTextMessage = "WebcastRankTextMessage",
    WebcastGiftDynamicRestrictionMessage = "WebcastGiftDynamicRestrictionMessage",
    WebcastViewerPicksUpdateMessage = "WebcastViewerPicksUpdateMessage",
}

--- Secondary message types.
local SECONDARY = {
    WebcastAccessControlMessage = "WebcastAccessControlMessage",
    WebcastAccessRecallMessage = "WebcastAccessRecallMessage",
    WebcastAlertBoxAuditResultMessage = "WebcastAlertBoxAuditResultMessage",
    WebcastBindingGiftMessage = "WebcastBindingGiftMessage",
    WebcastBoostCardMessage = "WebcastBoostCardMessage",
    WebcastBottomMessage = "WebcastBottomMessage",
    WebcastGameRankNotifyMessage = "WebcastGameRankNotifyMessage",
    WebcastGiftPromptMessage = "WebcastGiftPromptMessage",
    WebcastLinkStateMessage = "WebcastLinkStateMessage",
    WebcastLinkMicBattlePunishFinish = "WebcastLinkMicBattlePunishFinish",
    WebcastLinkmicBattleTaskMessage = "WebcastLinkmicBattleTaskMessage",
    WebcastMarqueeAnnouncementMessage = "WebcastMarqueeAnnouncementMessage",
    WebcastNoticeMessage = "WebcastNoticeMessage",
    WebcastNotifyMessage = "WebcastNotifyMessage",
    WebcastPartnershipDropsUpdateMessage = "WebcastPartnershipDropsUpdateMessage",
    WebcastPartnershipGameOfflineMessage = "WebcastPartnershipGameOfflineMessage",
    WebcastPartnershipPunishMessage = "WebcastPartnershipPunishMessage",
    WebcastPerceptionMessage = "WebcastPerceptionMessage",
    WebcastSpeakerMessage = "WebcastSpeakerMessage",
    WebcastSubCapsuleMessage = "WebcastSubCapsuleMessage",
    WebcastSubPinEventMessage = "WebcastSubPinEventMessage",
    WebcastSubscriptionNotifyMessage = "WebcastSubscriptionNotifyMessage",
    WebcastToastMessage = "WebcastToastMessage",
    WebcastSystemMessage = "WebcastSystemMessage",
    WebcastLiveGameIntroMessage = "WebcastLiveGameIntroMessage",
    RoomVerifyMessage = "WebcastRoomVerifyMessage",
}

--- Map wire name to a simpler event name for callbacks.
local EVENT_NAME = {
    WebcastChatMessage = "chat",
    WebcastGiftMessage = "gift",
    WebcastLikeMessage = "like",
    WebcastMemberMessage = "member",
    WebcastSocialMessage = "social",
    WebcastRoomUserSeqMessage = "room_user_seq",
    WebcastControlMessage = "control",
    WebcastLiveIntroMessage = "live_intro",
    WebcastRoomMessage = "room_message",
    WebcastCaptionMessage = "caption",
    WebcastGoalUpdateMessage = "goal_update",
    WebcastImDeleteMessage = "im_delete",
    WebcastRankUpdateMessage = "rank_update",
    WebcastPollMessage = "poll",
    WebcastEnvelopeMessage = "envelope",
    WebcastRoomPinMessage = "room_pin",
    WebcastUnauthorizedMemberMessage = "unauthorized_member",
    WebcastLinkMicMethod = "link_mic_method",
    WebcastLinkMicBattle = "link_mic_battle",
    WebcastLinkMicArmies = "link_mic_armies",
    WebcastLinkMessage = "link_message",
    WebcastLinkLayerMessage = "link_layer",
    WebcastLinkMicLayoutStateMessage = "link_mic_layout_state",
    WebcastGiftPanelUpdateMessage = "gift_panel_update",
    WebcastInRoomBannerMessage = "in_room_banner",
    WebcastGuideMessage = "guide",
    WebcastEmoteChatMessage = "emote_chat",
    WebcastQuestionNewMessage = "question_new",
    WebcastSubNotifyMessage = "sub_notify",
    WebcastBarrageMessage = "barrage",
    WebcastHourlyRankMessage = "hourly_rank",
    WebcastMsgDetectMessage = "msg_detect",
    WebcastLinkMicFanTicketMethod = "link_mic_fan_ticket",
    WebcastRoomVerifyMessage = "room_verify",
    WebcastOecLiveShoppingMessage = "oec_live_shopping",
    WebcastGiftBroadcastMessage = "gift_broadcast",
    WebcastRankTextMessage = "rank_text",
    WebcastGiftDynamicRestrictionMessage = "gift_dynamic_restriction",
    WebcastViewerPicksUpdateMessage = "viewer_picks_update",
    -- secondary
    WebcastAccessControlMessage = "access_control",
    WebcastAccessRecallMessage = "access_recall",
    WebcastAlertBoxAuditResultMessage = "alert_box_audit",
    WebcastBindingGiftMessage = "binding_gift",
    WebcastBoostCardMessage = "boost_card",
    WebcastBottomMessage = "bottom_message",
    WebcastGameRankNotifyMessage = "game_rank_notify",
    WebcastGiftPromptMessage = "gift_prompt",
    WebcastLinkStateMessage = "link_state",
    WebcastLinkMicBattlePunishFinish = "link_mic_battle_punish",
    WebcastLinkmicBattleTaskMessage = "link_mic_battle_task",
    WebcastMarqueeAnnouncementMessage = "marquee_announcement",
    WebcastNoticeMessage = "notice",
    WebcastNotifyMessage = "notify",
    WebcastPartnershipDropsUpdateMessage = "partnership_drops",
    WebcastPartnershipGameOfflineMessage = "partnership_game_offline",
    WebcastPartnershipPunishMessage = "partnership_punish",
    WebcastPerceptionMessage = "perception",
    WebcastSpeakerMessage = "speaker",
    WebcastSubCapsuleMessage = "sub_capsule",
    WebcastSubPinEventMessage = "sub_pin",
    WebcastSubscriptionNotifyMessage = "subscription_notify",
    WebcastToastMessage = "toast",
    WebcastSystemMessage = "system_message",
    WebcastLiveGameIntroMessage = "live_game_intro",
}

--- Decode a wire message and return a list of events.
-- Sub-routed messages yield both raw + convenience events.
---@param msg_type string the wire "type" field
---@param payload string raw protobuf bytes
---@return table list of {name=string, data=table} event records
function M.decode_message(msg_type, payload)
    local proto_name = PRIMARY[msg_type]
    if not proto_name then
        proto_name = SECONDARY[msg_type]
    end

    if not proto_name then
        -- unknown passthrough
        return {{ name = "unknown", data = { method = msg_type, payload = payload } }}
    end

    local decoded, decode_err = pb.decode(proto_name, payload)
    if not decoded then
        return {{ name = "unknown", data = {
            method = msg_type, payload = payload,
            decode_error = decode_err,
        } }}
    end

    local event_name = EVENT_NAME[msg_type] or msg_type
    local events = {{ name = event_name, data = decoded }}

    -- Sub-routing: fire convenience events alongside raw events
    if msg_type == "WebcastSocialMessage" then
        local action = decoded.action or 0
        if action == 1 then
            events[#events + 1] = { name = "follow", data = decoded }
        elseif action >= 2 and action <= 5 then
            events[#events + 1] = { name = "share", data = decoded }
        end
    elseif msg_type == "WebcastMemberMessage" then
        if (decoded.action or 0) == 1 then
            events[#events + 1] = { name = "join", data = decoded }
        end
    elseif msg_type == "WebcastControlMessage" then
        if (decoded.action or 0) == 3 then
            events[#events + 1] = { name = "live_ended", data = decoded }
        end
    end

    return events
end

--- Gift helper: check if a gift is a combo gift.
---@param gift table decoded WebcastGiftMessage
---@return boolean
function M.is_combo_gift(gift)
    if not gift.gift_details then return false end
    return (gift.gift_details.gift_type or 0) == 1
end

--- Gift helper: check if combo streak is over.
---@param gift table decoded WebcastGiftMessage
---@return boolean
function M.is_streak_over(gift)
    if not M.is_combo_gift(gift) then return true end
    return (gift.repeat_end or 0) == 1
end

--- Gift helper: total diamond value.
---@param gift table decoded WebcastGiftMessage
---@return number
function M.diamond_total(gift)
    local per = 0
    if gift.gift_details then
        per = gift.gift_details.diamond_count or 0
    end
    local count = math.max(gift.repeat_count or 0, 1)
    return per * count
end

return M

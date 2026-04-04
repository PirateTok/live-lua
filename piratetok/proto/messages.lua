--- Core, useful, and niche message protobuf schemas.
-- Tag numbers match PirateTok-rust-live (ground truth).
-- IMPORTANT: lua-protobuf crashes on wire type mismatch. Only declare
-- fields with KNOWN correct tags. Undeclared fields are silently skipped.
local M = {}

local SCHEMA = [[
syntax = "proto3";

// ─── Core events (7) ─────────────────────────────────────

message WebcastChatMessage {
    bytes common = 1;
    User user = 2;
    string comment = 3;
    string content_language = 14;
}

message WebcastGiftMessage {
    bytes common = 1;
    int32 gift_id = 2;
    int64 fan_ticket_count = 3;
    int32 group_count = 4;
    int32 repeat_count = 5;
    int32 combo_count = 6;
    User user = 7;
    User to_user = 8;
    int32 repeat_end = 9;
    uint64 group_id = 11;
    GiftDetails gift_details = 15;
    bool is_first_sent = 25;
}

message WebcastLikeMessage {
    bytes common = 1;
    int32 count = 2;
    int32 total = 3;
    User user = 5;
}

message WebcastMemberMessage {
    bytes common = 1;
    User user = 2;
    int32 member_count = 3;
    int32 action = 10;
}

message WebcastSocialMessage {
    bytes common = 1;
    User user = 2;
    int64 share_type = 3;
    int64 action = 4;
    string share_target = 5;
    int32 follow_count = 6;
}

message WebcastRoomUserSeqMessage {
    bytes common = 1;
    int32 viewer_count = 3;
    int64 popularity = 6;
    int32 total_user = 7;
}

message WebcastControlMessage {
    bytes common = 1;
    int32 action = 2;
    string reason = 3;
}

// ─── Useful events (5) ───────────────────────────────────

message WebcastLiveIntroMessage {
    bytes common = 1;
    int64 room_id = 2;
    int32 audit_status = 3;
    string content = 4;
    User host = 5;
}

message WebcastRoomMessage {
    bytes common = 1;
    string content = 2;
}

message CaptionData {
    string language = 1;
    string text = 2;
}

message WebcastCaptionMessage {
    bytes common = 1;
    uint64 timestamp = 2;
    CaptionData caption_data = 4;
}

message WebcastGoalUpdateMessage {
    bytes common = 1;
    int64 contributor_id = 4;
    int64 contribute_count = 9;
    int64 contribute_score = 10;
    bool pin = 13;
    bool unpin = 14;
}

message WebcastImDeleteMessage {
    bytes common = 1;
    repeated int64 delete_msg_ids = 2;
    repeated int64 delete_user_ids = 3;
}

// ─── Niche events ───────────────────────────────────────

message WebcastRankUpdateMessage {
    bytes common = 1;
    int64 group_type = 3;
    int64 priority = 5;
}

message WebcastPollMessage {
    bytes common = 1;
    int32 message_type = 2;
    int64 poll_id = 3;
    bytes start_content = 4;
    bytes end_content = 5;
    bytes update_content = 6;
    int32 poll_kind = 7;
}

message EnvelopeInfo {
    string envelope_id = 1;
    int32 business_type = 2;
    int32 diamond_count = 5;
    int32 people_count = 6;
}

message WebcastEnvelopeMessage {
    bytes common = 1;
    EnvelopeInfo envelope_info = 2;
    int32 display = 3;
}

message WebcastRoomPinMessage {
    bytes common = 1;
    bytes pinned_message = 2;
    string original_msg_type = 30;
    uint64 timestamp = 31;
}

message WebcastUnauthorizedMemberMessage {
    bytes common = 1;
    int32 action = 2;
    bytes nick_name_prefix = 3;
    string nick_name = 4;
}

message WebcastLinkMicMethod {
    bytes common = 1;
    int32 message_type = 2;
    int64 user_id = 5;
    int64 channel_id = 8;
}

message WebcastLinkMicBattle {
    bytes common = 1;
    int64 battle_id = 2;
    int32 action = 4;
}

message WebcastLinkMicArmies {
    bytes common = 1;
    int64 battle_id = 2;
    int64 channel_id = 4;
    int32 battle_status = 7;
}

message WebcastLinkMessage {
    bytes common = 1;
    int32 message_type = 2;
    int64 linker_id = 3;
    int32 scene = 4;
}

message WebcastLinkLayerMessage {
    bytes common = 1;
    int32 message_type = 2;
    int64 channel_id = 3;
    int32 scene = 4;
}

message WebcastLinkMicLayoutStateMessage {
    bytes common = 1;
    int64 room_id = 2;
    int32 layout_state = 3;
    string layout_key = 6;
}

message WebcastGiftPanelUpdateMessage {
    bytes common = 1;
    int64 room_id = 2;
    int64 panel_version = 3;
}

message WebcastInRoomBannerMessage {
    bytes common = 1;
    int32 position = 3;
    int32 action_type = 4;
}

message WebcastGuideMessage {
    bytes common = 1;
    int32 guide_type = 2;
    int64 duration_ms = 5;
    string scene = 7;
}

// ─── Extended events ────────────────────────────────────

message WebcastEmoteChatMessage {
    bytes common = 1;
    User user = 2;
    string emote_id = 3;
    Image emote_image = 4;
}

message WebcastQuestionNewMessage {
    bytes common = 1;
    string content = 2;
    User user = 3;
}

message WebcastSubNotifyMessage {
    bytes common = 1;
    User user = 2;
}

message WebcastBarrageMessage {
    bytes common = 1;
}

message WebcastHourlyRankMessage {
    bytes common = 1;
}

message WebcastMsgDetectMessage {
    bytes common = 1;
}

message WebcastLinkMicFanTicketMethod {
    bytes common = 1;
}

message WebcastRoomVerifyMessage {
    bytes common = 1;
}

message WebcastOecLiveShoppingMessage {
    bytes common = 1;
}

message WebcastGiftBroadcastMessage {
    bytes common = 1;
}

message WebcastRankTextMessage {
    bytes common = 1;
}

message WebcastGiftDynamicRestrictionMessage {
    bytes common = 1;
}

message WebcastViewerPicksUpdateMessage {
    bytes common = 1;
}
]]

function M.register(p)
    p:load(SCHEMA, "messages.proto")
end

return M

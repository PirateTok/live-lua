--- Secondary message protobuf schemas.
-- All TikTok messages start with a common field at tag 1 (wire type 2).
-- We declare bytes common = 1 for safety — lua-protobuf crashes on
-- wire type mismatches, so undeclared is safer than wrong.
local M = {}

local SCHEMA = [[
syntax = "proto3";

message WebcastAccessControlMessage { bytes common = 1; }
message WebcastAccessRecallMessage { bytes common = 1; }
message WebcastAlertBoxAuditResultMessage { bytes common = 1; }
message WebcastBindingGiftMessage { bytes common = 1; }
message WebcastBoostCardMessage { bytes common = 1; }
message WebcastBottomMessage { bytes common = 1; }
message WebcastGameRankNotifyMessage { bytes common = 1; }
message WebcastGiftPromptMessage { bytes common = 1; }
message WebcastLinkStateMessage { bytes common = 1; }
message WebcastLinkMicBattlePunishFinish { bytes common = 1; }
message WebcastLinkmicBattleTaskMessage { bytes common = 1; }
message WebcastMarqueeAnnouncementMessage { bytes common = 1; }
message WebcastNoticeMessage { bytes common = 1; }
message WebcastNotifyMessage { bytes common = 1; }
message WebcastPartnershipDropsUpdateMessage { bytes common = 1; }
message WebcastPartnershipGameOfflineMessage { bytes common = 1; }
message WebcastPartnershipPunishMessage { bytes common = 1; }
message WebcastPerceptionMessage { bytes common = 1; }
message WebcastSpeakerMessage { bytes common = 1; }
message WebcastSubCapsuleMessage { bytes common = 1; }
message WebcastSubPinEventMessage { bytes common = 1; }
message WebcastSubscriptionNotifyMessage { bytes common = 1; }
message WebcastToastMessage { bytes common = 1; }
message WebcastSystemMessage { bytes common = 1; }
message WebcastLiveGameIntroMessage { bytes common = 1; }
]]

function M.register(p)
    p:load(SCHEMA, "messages_ext.proto")
end

return M

--- Common protobuf type definitions shared across messages.
-- User, Image, Badge, FollowInfo, FansClub, etc.
local M = {}

local SCHEMA = [[
syntax = "proto3";

message Image {
    repeated string urls = 1;
    string uri = 2;
    int32 width = 3;
    int32 height = 4;
}

message PrivilegeLogExtra {
    string data_version = 1;
    string privilege_id = 2;
    string level = 5;
}

message BadgeImage {
    Image image = 2;
}

message BadgeText {
    string key = 2;
    string default_pattern = 3;
}

message BadgeString {
    string content_str = 2;
}

message BadgeStruct {
    int32 display_type = 1;
    int32 badge_scene = 3;
    bool display = 11;
    PrivilegeLogExtra log_extra = 12;
    BadgeImage image_badge = 20;
    BadgeText text_badge = 21;
    BadgeString string_badge = 22;
}

message FollowInfo {
    int64 following_count = 1;
    int64 follower_count = 2;
    int64 follow_status = 3;
}

message FansClubData {
    string club_name = 1;
    int32 level = 2;
}

message FansClubMember {
    FansClubData data = 1;
}

message User {
    int64 id = 1;
    string nickname = 3;
    string bio_description = 5;
    Image avatar_thumb = 9;
    Image avatar_medium = 10;
    Image avatar_large = 11;
    bool verified = 12;
    FollowInfo follow_info = 22;
    FansClubMember fans_club = 24;
    int32 top_vip_no = 31;
    int64 pay_score = 34;
    int64 fan_ticket_count = 35;
    string unique_id = 38;
    string display_id = 46;
    repeated BadgeStruct badge_list = 64;
    int64 follow_status = 1024;
    bool is_follower = 1029;
    bool is_following = 1030;
    bool is_subscribe = 1090;
}

message GiftDetails {
    int64 id = 5;
    bool combo = 10;
    int32 gift_type = 11;
    int32 diamond_count = 12;
    string name = 16;
}

message TopGifter {
    User user = 1;
    int64 coins = 2;
}
]]

function M.register(p)
    p:load(SCHEMA, "common.proto")
end

return M

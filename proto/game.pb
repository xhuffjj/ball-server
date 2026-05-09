
®1

game.protogame"2
Food
id (Rid
x (Rx
y (Ry"9
LoginFirstReq
playerid (	Rplayerid
A (RA"W
LoginFirstRes
code (Rcode
msg (	Rmsg
salt (Rsalt
B (RB"<
LoginSecondReq
playerid (	Rplayerid
M1 (RM1"\
LoginSecondRes
code (Rcode
msg (	Rmsg
M2 (RM2
token (	Rtoken"Y
RegisterReq
playerid (	Rplayerid
salt (Rsalt
verifier (Rverifier"3
RegisterRes
code (Rcode
msg (	Rmsg"

KickNotify
msg (	Rmsg"

EnterReq"¶
EnterRes
code (Rcode
msg (	Rmsg
battle_host (	R
battleHost
battle_port (R
battlePort
battle_conv (R
battleConv!
battle_token (	RbattleToken"

LeaveReq"0
LeaveRes
code (Rcode
msg (	Rmsg"%
BattleAuthReq
token (	Rtoken"R
BattleAuthRes
code (Rcode
msg (	Rmsg
	ready_seq (RreadySeq"0
BattleReadyAckReq
	ready_seq (RreadySeq"˜
CellInfo
cell_id (RcellId
x (Rx
y (Ry
size (Rsize
playerid (Rplayerid'
protected_timer (RprotectedTimer"B
	SporeInfo
spore_id (RsporeId
x (Rx
y (Ry")
EnterNotify
playerid (Rplayerid")
LeaveNotify
playerid (Rplayerid"¤
InputFrameReq
	input_seq (RinputSeq
target_x (RtargetX
target_y (RtargetY
moving (Rmoving
split (Rsplit
spit (Rspit"í
SelfNewCell
cell_id (RcellId$
parent_cell_id (RparentCellId
playerid (Rplayerid

action_seq (R	actionSeq
x (Rx
y (Ry
size (Rsize
boost_vx (RboostVx
boost_vy	 (RboostVy"Õ
SelfNewSporeInfo
spore_id (RsporeId
x (Rx
y (Ry
vx (Rvx
vy (Rvy%
owner_playerid (RownerPlayerid

action_seq (R	actionSeq$
source_cell_id (RsourceCellId"ß
FrameUpdate$
cells (2.game.CellInfoRcells'
	new_foods (2
.game.FoodRnewFoods5

new_spores (2.game.SelfNewSporeInfoR	newSpores$
eaten_food_ids (ReatenFoodIds
tick (Rtick%
dead_playerids (RdeadPlayerids.
	new_cells (2.game.SelfNewCellRnewCells'
spores (2.game.SporeInfoRspores
ack	 (Rack"”
SceneSnapshot$
cells (2.game.CellInfoRcells'
spores (2.game.SporeInfoRspores 
foods (2
.game.FoodRfoods
tick (Rtick"€
AchieveInfo

achieve_id (R	achieveId
progress (Rprogress
is_done (RisDone

claim_time (	R	claimTime"
AchieveListReq"?
AchieveListRes-
achieves (2.game.AchieveInfoRachieves"0
AchieveClaimReq

achieve_id (R	achieveId"7
AchieveClaimRes
code (Rcode
msg (	Rmsg"D
AchieveNotify3
achieveinfo (2.game.AchieveInfoRachieveinfo"	
WorkReq"
WorkRes
coin (Rcoin"9
ItemInfo
item_id (RitemId
count (Rcount"

BagListReq"2

BagListRes$
items (2.game.ItemInfoRitems";

UseItemReq
item_id (RitemId
count (Rcount"2

UseItemRes
code (Rcode
msg (	Rmsg"j

AttachInfo
id (Rid
item_id (RitemId
count (Rcount

is_claimed (R	isClaimed"°
	MailBrief
mail_id (RmailId
	sender_id (RsenderId
title (	Rtitle
is_read (RisRead

attach_num (R	attachNum
expire_time (	R
expireTime"

MailDetail
mail_id (RmailId
	sender_id (RsenderId
title (	Rtitle
content (	Rcontent
is_read (RisRead
create_time (	R
createTime
expire_time (	R
expireTime2
attachments (2.game.AttachInfoRattachments"
MailListReq"4
MailListRes%
mails (2.game.MailBriefRmails"&
MailReadReq
mail_id (RmailId"]
MailReadRes
code (Rcode
msg (	Rmsg(
detail (2.game.MailDetailRdetail"'
MailClaimReq
mail_id (RmailId"4
MailClaimRes
code (Rcode
msg (	Rmsg"(
MailDeleteReq
mail_id (RmailId"5
MailDeleteRes
code (Rcode
msg (	Rmsg"1

MailNotify#
mail (2.game.MailBriefRmail"^
FriendBrief
friendid (Rfriendid
status (Rstatus
	is_online (RisOnline"—
PublicBaseInfo
playerid (Rplayerid
level (Rlevel
	vip_level (RvipLevel
	is_online (RisOnline
in_scene (RinScene"+
FriendInfoReq
friendid (Rfriendid"_
FriendInfoRes
code (Rcode
msg (	Rmsg(
info (2.game.PublicBaseInfoRinfo"
FriendListReq"<
FriendListRes+
friends (2.game.FriendBriefRfriends"
FriendPendingReq"?
FriendPendingRes+
friends (2.game.FriendBriefRfriends"+
FriendAddReq
	target_id (RtargetId"4
FriendAddRes
code (Rcode
msg (	Rmsg".
FriendAcceptReq
	target_id (RtargetId"7
FriendAcceptRes
code (Rcode
msg (	Rmsg".
FriendRejectReq
	target_id (RtargetId"7
FriendRejectRes
code (Rcode
msg (	Rmsg".
FriendDeleteReq
	target_id (RtargetId"7
FriendDeleteRes
code (Rcode
msg (	Rmsg"
BaseInfoReq"É
BaseInfoRes
coin (Rcoin
level (Rlevel
	vip_level (RvipLevel
exp (Rexp
playerid (Rplayerid&
last_login_time (RlastLoginTime

rank_score (R	rankScore"[
ReconnectReq
playerid (Rplayerid
token (	Rtoken
last_ack (RlastAck""
ReconnectRes
code (Rcode"'
JoinMatchReq
mode_id (RmodeId"4
JoinMatchRes
code (Rcode
msg (	Rmsg"
CancelMatchReq"6
CancelMatchRes
code (Rcode
msg (	Rmsg"
MatchStatusReq"e
MatchStatusRes
code (Rcode
msg (	Rmsg
state (Rstate
mode_id (RmodeId"0
MatchFoundNotify
	playerids (R	playerids"

PrepareReq"2

PrepareRes
code (Rcode
msg (	Rmsg"N
RoomPlayerState
playerid (Rplayerid
is_prepared (R
isPrepared"D
RoomPrepareNotify/
players (2.game.RoomPlayerStateRplayers"›
BattleConnectNotify
battle_host (	R
battleHost
battle_port (R
battlePort
battle_conv (R
battleConv!
battle_token (	RbattleToken"+
RoomDismissNotify
reason (	Rreason"’
BattleResultNotify
rank (Rrank!
weight_score (RweightScore
score_delta (R
scoreDelta
coin (Rcoin
exp (Rexpbproto3
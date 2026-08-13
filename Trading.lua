local State = require(script.State)
local Types = require(script.Types)

local Trading = {}

-- Sessions stores every active trade by its session ID.
-- PlayerSessions provides a direct lookup from UserId -> SessionId,
-- allowing us to quickly determine whether a player is already trading.
function Trading.CreateManager(Config: Types.Config?): Types.Manager
	return {
		Sessions = {},
		PlayerSessions = {},
		Config = Config or {
			CountdownDuration = 3,
			NegotiationTimeout = 120,
			MaxItemsPerOffer = 6,
		},
		NextId = 0,
	}
end


local function GenerateId(Manager: Types.Manager): string
	Manager.NextId += 1
	return "TRADE_" .. Manager.NextId .. "_" .. tick()
end

-- A session contains all states required to manage one trade.
-- Offers and Ready are indexed by UserId so both participants can
-- independently modify only their own side of the trade.
local function CreateSession(
	Id: string,
	PlayerA: Player,
	PlayerB: Player,
	Config: Types.Config,
	Callbacks: { [any]: any }
): Types.Session
	return {
		Id = Id,
		PlayerA = PlayerA,
		PlayerB = PlayerB,
		State = State.Requested,
		NegotiationTimeout = Config.NegotiationTimeout,
		MaxItemsPerOffer = Config.MaxItemsPerOffer,
		CountdownDuration = Config.CountdownDuration,
		Offers = {
			[PlayerA.UserId] = {},
			[PlayerB.UserId] = {},
		},
		Ready = {
			[PlayerA.UserId] = false,
			[PlayerB.UserId] = false,
		},
		Callbacks = Callbacks or {},
		TimerThread = nil,
	}
end

-- // Helpers

local function IsParticipant(Session: Types.Session, PlayerId: number)
	return PlayerId == Session.PlayerA.UserId or PlayerId == Session.PlayerB.UserId
end

local function ClearTimer(Session: Types.Session)
	if Session.TimerThread then
		--task.cancel(Session.TimerThread)
		Session.TimerThread = nil
	end
end

-- PlayerSessions maps each player to their active trade.
-- This also prevents a player from joining multiple trades.
function Trading.CreateSession(Manager: Types.Manager, PlayerA: Player, PlayerB: Player, Callbacks: { [any]: any })
	local A_ID, B_ID = PlayerA.UserId, PlayerB.UserId

	if Manager.PlayerSessions[A_ID] then
		return nil, "PlayerA in trade"
	end
	if Manager.PlayerSessions[B_ID] then
		return nil, "PlayerB in trade"
	end

	local ID = GenerateId(Manager)
	local Session = CreateSession(ID, PlayerA, PlayerB, Manager.Config, Callbacks)

	Manager.Sessions[ID] = Session
	Manager.PlayerSessions[A_ID] = ID
	Manager.PlayerSessions[B_ID] = ID

	return Session
end

function Trading.GetSession(Manager: Types.Manager, SessionId): Types.Session?
	return Manager.Sessions[SessionId]
end

function Trading.GetSessionByPlayer(Manager: Types.Manager, UserId: number): Types.Session?
	local ID = Manager.PlayerSessions[UserId]
	return ID and Manager.Sessions[ID] or nil
end

function Trading.DestroySession(Manager: Types.Manager, SessionId: string)
	local Session = Manager.Sessions[SessionId]
	if not Session then
		return
	end

	ClearTimer(Session)

	Manager.Sessions[SessionId] = nil
	Manager.PlayerSessions[Session.PlayerA.UserId] = nil
	Manager.PlayerSessions[Session.PlayerB.UserId] = nil
end

-- // State Transitions

-- Once accepted, the session enters negotiation and starts a timeout.
-- The callback is responsible for notifying the server integration
-- so the trade can be cancelled if negotiation takes too long.
function Trading.Accept(Session: Types.Session, PlayerB: Player)
	if Session.State ~= State.Requested then
		return false, "Already Handled"
	end

	if not IsParticipant(Session, PlayerB.UserId) then
		return false, "Not Participant"
	end

	if PlayerB ~= Session.PlayerB then
		return false, "Not Invited Player"
	end

	Session.State = State.Negotiating

	Session.TimerThread = task.delay(Session.NegotiationTimeout, function()
		if Session.Callbacks.OnCancel then
			Session.Callbacks.OnCancel(Session, "NegotiationTimeout")
		end
	end)

	return true
end

function Trading.Cancel(Session: Types.Session, PlayerId: number)
	if not IsParticipant(Session, PlayerId) then
		return false, "Not participant"
	end

	if Session.State == State.Completed or Session.State == State.Cancelled then
		return false, "Already ended."
	end

	ClearTimer(Session)

	Session.State = State.Cancelled

	if Session.Callbacks.OnCancel then
		Session.Callbacks.OnCancel(Session, "PlayerCancelled")
	end

	return true
end

function Trading.Complete(Session: Types.Session)
	if Session.State ~= State.Countdown then
		return false, "Not in countdown"
	end

	ClearTimer(Session)
	Session.State = State.Completed

	if Session.Callbacks.OnCompleted then
		Session.Callbacks.OnCompleted(Session)
	end

	return true
end

function Trading.ForceCancel(Session: Types.Session, Reason: string)
	if Session.State == State.Completed or Session.State == State.Cancelled then
		return
	end

	ClearTimer(Session)
	Session.State = State.Cancelled

	if Session.Callbacks.OnCancel then
		Session.Callbacks.OnCancel(Session, Reason)
	end
end

-- // Offer Management

function Trading.GetOffer(Session: Types.Session, PlayerId: number)
	return Session.Offers[PlayerId]
end

-- Let the inventory system handle item validation so this module
-- doesn't need to know how items are stored.
function Trading.AddItem(Session: Types.Session, PlayerId: number, ItemId: string)
	if Session.State ~= State.Negotiating then
		return false, "Not Negotiating"
	end

	if not IsParticipant(Session, PlayerId) then
		return false, "Not Participant"
	end

	local Offer = Session.Offers[PlayerId]
	if #Offer >= Session.MaxItemsPerOffer then
		return false, "Offer Full"
	end

	for _, Id in ipairs(Offer) do
		if Id == ItemId then
			return false, "already Offered"
		end
	end

	if Session.Callbacks.CanAddItem then
		local Ok, Err = Session.Callbacks.CanAddItem(Session, PlayerId, ItemId)
		if not Ok then
			return false, Err
		end
	end

	table.insert(Offer, ItemId)

	if Session.Callbacks.OnItemAdded then
		Session.Callbacks.OnItemAdded(Session, PlayerId, ItemId)
	end

	return true
end

function Trading.RemoveItem(Session: Types.Session, PlayerId: number, ItemId: string)
	if Session.State ~= State.Negotiating then
		return false, "Not Negotiating"
	end

	if not IsParticipant(Session, PlayerId) then
		return false, "Not Participant"
	end

	local Offer = Session.Offers[PlayerId]
	for i, Id in ipairs(Offer) do
		if Id == ItemId then
			table.remove(Offer, i)

			if Session.Callbacks.OnItemRemoved then
				Session.Callbacks.OnItemRemoved(Session, PlayerId, ItemId)
			end

			return true
		end
	end

	return false, "Item Not In Offer"
end

-- // Ready & Countdown

function Trading.SetReady(Session: Types.Session, PlayerId: number, IsReady: boolean)
	if not IsParticipant(Session, PlayerId) then
		return false, "Not Participant"
	end

	if Session.State == State.Negotiating then
		Session.Ready[PlayerId] = IsReady

		if IsReady and Session.Ready[Session.PlayerA.UserId] and Session.Ready[Session.PlayerB.UserId] then
			ClearTimer(Session)
			Session.State = State.Countdown

			if Session.Callbacks.OnCountdownStarted then
				Session.Callbacks.OnCountdownStarted(Session, Session.CountdownDuration)
			end

			Session.TimerThread = task.delay(Session.CountdownDuration, function()
				if Session.State == State.Countdown then
					Trading.Complete(Session)
				end
			end)
		end

		return true
	elseif Session.State == State.Countdown then
		if not IsReady then
			ClearTimer(Session)
			Session.Ready[Session.PlayerA.UserId] = false
			Session.Ready[Session.PlayerB.UserId] = false
			Session.State = State.Negotiating

			if Session.Callbacks.OnCountdownCancelled then
				Session.Callbacks.OnCountdownCancelled(Session)
			end

			return true
		end

		return false, "Already Ready"
	end

	return false, "Invalid State: " .. Session.State
end

return Trading
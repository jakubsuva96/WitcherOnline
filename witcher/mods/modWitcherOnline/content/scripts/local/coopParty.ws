// Party rules for playing the story together: the leader's world leads and the member follows it.
// Leader -> member state goes on channel "ps", member -> leader on "ms". Both are whole states repeated by the
// server; counters in them mark events, so a lost or repeated packet never replays or drops one.

function COOP_LEASH_RANGE() : float
{
    return 80.0;
}

function COOP_LEASH_DELAY() : float
{
    return 10.0;
}

// how long a downed player waits for the partner before the usual outcome
function COOP_DOWNED_TIME() : float
{
    return 60.0;
}

// spaces can't travel inside a field; the client turns '*' back into ' '
function CoopField(text : string) : string
{
    if(text == "")
    {
        return "-";
    }
    return StrReplaceAll(text, " ", "*");
}

function CoopBit(value : bool) : int
{
    if(value)
    {
        return 1;
    }
    return 0;
}

function CoopFieldValue(text : string) : string
{
    if(text == "-")
    {
        return "";
    }
    return text;
}

class r_CoopParty
{
    // leader's own state
    private var ftSeq : int;
    private var ftPin : name;
    private var ftArea : name;
    private var medSeq : int;
    private var medTime : float;
    private var lastSentState : string;
    private var lastStateSentAt : float;

    // the member's copy of the leader's state
    private var leaderKnown : bool;
    private var leaderFtSeq : int;
    private var leaderMedSeq : int;
    private var leaderInScene : bool;
    private var pendingFtPin : name;
    private var pendingFtArea : name;
    private var pendingFt : bool;

    // member following
    private var farSince : float;
    private var nextFollowAt : float;
    private var sceneFollowDone : bool;
    private var sceneProtected : bool;
    private var lastCheckAt : float;
    private var nextDialogNoteAt : float;

    // a new id each time a save is loaded: counters restart, so the other side starts over too
    private var sessionId : int;
    private var lastMemberStateSent : string;
    private var lastMemberStateSentAt : float;

    // downed and revive, both roles
    private var immortalSet : bool;
    private var dying : bool;
    private var downed : bool;
    private var downedAt : float;
    private var lastDownedCheckAt : float;
    private var reviveSeq : int;
    private var partnerName : string;
    private var partnerDowned : bool;
    private var partnerKnown : bool;
    private var partnerSession : int;
    private var partnerReviveSeq : int;

    // leader: deaths and the save the member resyncs from
    private var deathSeq : int;
    private var newestSave : string;
    private var leaderSession : int;
    private var leaderDeathSeq : int;
    private var leaderSave : string;

    // member: the last neutral NPC this player angered, for the leader to turn hostile
    private var aggroSeq : int;
    private var aggroTpl : string;
    private var aggroPos : Vector;
    private var memberAggroSeq : int;

    default farSince = -1;

    public function Role() : int
    {
        return theGame.r_getMultiplayerClient().getCoopEnemies().GetRole();
    }

    public function IsMember() : bool
    {
        return Role() == 2;
    }

    private function LeaderName() : string
    {
        return theGame.r_getMultiplayerClient().getJoinedParty();
    }

    private function LeaderGlobal() : r_RemotePlayer
    {
        var globals : array<r_RemotePlayer>;
        var leader : string;
        var i : int;

        leader = LeaderName();
        globals = theGame.r_getMultiplayerClient().getGlobalPlayers();
        for(i = 0; i < globals.Size(); i += 1)
        {
            if(globals[i] && globals[i].username == leader)
            {
                return globals[i];
            }
        }
        return NULL;
    }

    private function InScene() : bool
    {
        return theGame.IsDialogOrCutscenePlaying() || theGame.IsCurrentlyPlayingNonGameplayScene();
    }

    private function Note(text : string)
    {
        theGame.GetGuiManager().ShowNotification("Co-op: " + text);
    }

    // called every frame from the client's tick while in game
    public function Tick()
    {
        var role : int;
        var now : float;

        if(!thePlayer)
        {
            return;
        }

        now = theGame.GetEngineTimeAsSeconds();
        role = Role();
        if(role == 1)
        {
            LeaderTick(now);
        }
        else if(role == 2)
        {
            MemberTick(now);
        }
        else
        {
            LeaveMemberState();
        }
        DownedTick(role, now);
    }

    // after every load (the client survives loads, the world doesn't)
    public function OnSessionStart()
    {
        sessionId = RandRange(1000000, 1);
        immortalSet = false;
        dying = false;
        downed = false;
        partnerKnown = false;
        partnerDowned = false;
        leaderKnown = false;
        lastSentState = "";
        lastMemberStateSent = "";
        RefreshNewestSave();
    }

    // ---------------------------------------------------------------- leader

    private function LeaderTick(now : float)
    {
        var stateText : string;
        var scene : int;

        scene = 0;
        if(InScene())
        {
            scene = 1;
        }

        stateText = "coop ps " + ftSeq + " " + CoopField(NameToString(ftPin)) + " " + CoopField(NameToString(ftArea))
            + " " + scene + " " + medSeq + " " + FloatToStringPrec(medTime, 0) + " " + sessionId + " " + CoopBit(downed)
            + " " + reviveSeq + " " + deathSeq + " " + CoopField(newestSave);

        if(stateText != lastSentState || now - lastStateSentAt > 2.0)
        {
            WO_Send(stateText);
            lastSentState = stateText;
            lastStateSentAt = now;
        }
    }

    public function OnLocalFastTravel(pinTag : name, areaID : name)
    {
        if(Role() != 1)
        {
            return;
        }
        ftSeq += 1;
        ftPin = pinTag;
        ftArea = areaID;
    }

    public function OnLocalMeditationRestored(simulatedTime : float)
    {
        if(Role() != 1 || simulatedTime <= 0)
        {
            return;
        }
        medSeq += 1;
        medTime = simulatedTime;
    }

    // ---------------------------------------------------------------- member

    // "ps ftSeq ftPin ftArea scene medSeq medTime session downed reviveSeq deathSeq save"
    public function OnLeaderState(sender : string, count : int)
    {
        var newFtSeq, newMedSeq, newSession, newReviveSeq, newDeathSeq : int;

        if(count < 11 || Role() != 2 || sender != LeaderName())
        {
            return;
        }

        newFtSeq = StringToInt(WO_Str(1), 0);
        newMedSeq = StringToInt(WO_Str(5), 0);
        newSession = StringToInt(WO_Str(7), 0);
        newReviveSeq = StringToInt(WO_Str(9), 0);
        newDeathSeq = StringToInt(WO_Str(10), 0);
        leaderInScene = WO_Str(4) == "1";
        leaderSave = CoopFieldValue(WO_Str(11));
        partnerName = sender;
        SetPartnerDowned(WO_Str(8) == "1");

        if(newSession != leaderSession)
        {
            leaderKnown = false;
            leaderSession = newSession;
        }

        if(leaderKnown && newReviveSeq != partnerReviveSeq && downed)
        {
            ReviveSelf(0.3);
            Note(sender + " tě oživil.");
        }
        partnerReviveSeq = newReviveSeq;

        if(leaderKnown && newDeathSeq != leaderDeathSeq)
        {
            Note(sender + " zemřel. Načítám jeho poslední uloženou hru.");
            Resync();
        }
        leaderDeathSeq = newDeathSeq;

        // the first state only tells where the counters stand; nothing that happened before joining is replayed
        if(leaderKnown && newFtSeq != leaderFtSeq && CoopFieldValue(WO_Str(2)) != "")
        {
            pendingFtPin = WO_ToName(CoopFieldValue(WO_Str(2)));
            pendingFtArea = WO_ToName(CoopFieldValue(WO_Str(3)));
            pendingFt = true;
        }
        if(leaderKnown && newMedSeq != leaderMedSeq)
        {
            GetWitcherPlayer().MeditationRestoring(StringToFloat(WO_Str(6), 0));
            Note(LeaderName() + " meditoval: čas, zdraví a alchymie jsou srovnané.");
        }

        leaderFtSeq = newFtSeq;
        leaderMedSeq = newMedSeq;
        leaderKnown = true;
    }

    private function MemberTick(now : float)
    {
        var gp : r_RemotePlayer;
        var myScene : bool;

        SendMemberState(now);

        if(now - lastCheckAt < 0.25)
        {
            return;
        }
        lastCheckAt = now;

        myScene = InScene();
        gp = LeaderGlobal();

        FollowScene(gp, myScene);

        if(pendingFt && !myScene && !theGame.r_getMultiplayerClient().WO_GetTeleporting())
        {
            pendingFt = false;
            FollowFastTravel(now);
            return;
        }

        Leash(gp, myScene, now);
    }

    private function FollowFastTravel(now : float)
    {
        var maps : CCommonMapManager;

        maps = theGame.GetCommonMapManager();
        if(pendingFtArea == '' || pendingFtArea == maps.GetCurrentArea())
        {
            maps.PerformLocalFastTravelTeleport(pendingFtPin);
        }
        else
        {
            theGame.r_getMultiplayerClient().WO_SetTeleporting(true);
            maps.PerformGlobalFastTravelTeleport(pendingFtArea, pendingFtPin);
        }
        Note("cestuješ spolu s hráčem " + LeaderName() + ".");
        nextFollowAt = now + 20.0;
        farSince = -1;
    }

    // While the leader's scene plays, the member is brought next to the leader and can't be hurt. The member's own
    // scene (same quest point) takes over when it starts.
    private function FollowScene(gp : r_RemotePlayer, myScene : bool)
    {
        if(leaderInScene && !myScene && gp)
        {
            if(!sceneFollowDone)
            {
                sceneFollowDone = true;
                if(gp.area == WO_CurrentAreaCode() && VecDistance(thePlayer.GetWorldPosition(), gp.pos) > 15.0)
                {
                    TeleportNear(gp.pos);
                    Note(LeaderName() + " je ve scéně, přenáším tě k němu.");
                }
            }
            if(!sceneProtected)
            {
                thePlayer.SetImmortalityMode(AIM_Invulnerable, AIC_Scene);
                sceneProtected = true;
            }
            return;
        }

        if(!leaderInScene)
        {
            sceneFollowDone = false;
        }
        if(sceneProtected)
        {
            // a scene of the member's own owns AIC_Scene now and resets it when it ends
            if(!myScene)
            {
                thePlayer.SetImmortalityMode(AIM_None, AIC_Scene);
            }
            sceneProtected = false;
        }
    }

    private function Leash(gp : r_RemotePlayer, myScene : bool, now : float)
    {
        var dist : float;

        if(!gp || myScene || leaderInScene || now < nextFollowAt || theGame.r_getMultiplayerClient().WO_GetTeleporting()
            || now - gp.lastUpdate > 3.0)
        {
            farSince = -1;
            return;
        }

        if(gp.area != WO_CurrentAreaCode())
        {
            if(farSince < 0)
            {
                farSince = now;
                Note(LeaderName() + " je v jiné oblasti, za " + FloatToStringPrec(COOP_LEASH_DELAY(), 0) + " s tě k němu přenesu.");
            }
            else if(now - farSince >= COOP_LEASH_DELAY())
            {
                mpghosts_teleport(gp.username);
                nextFollowAt = now + 20.0;
                farSince = -1;
            }
            return;
        }

        dist = VecDistance(thePlayer.GetWorldPosition(), gp.pos);
        if(dist <= COOP_LEASH_RANGE())
        {
            farSince = -1;
            return;
        }

        if(farSince < 0)
        {
            farSince = now;
            Note("jsi od hráče " + LeaderName() + " dál než " + FloatToStringPrec(COOP_LEASH_RANGE(), 0) + " m, za "
                + FloatToStringPrec(COOP_LEASH_DELAY(), 0) + " s tě k němu přenesu.");
        }
        else if(now - farSince >= COOP_LEASH_DELAY())
        {
            TeleportNear(gp.pos);
            nextFollowAt = now + 5.0;
            farSince = -1;
        }
    }

    // beside the leader rather than inside him; a rider is moved with the horse
    private function TeleportNear(pos : Vector)
    {
        var target : Vector;

        target = pos;
        target.X += 1.2;
        target.Y += 1.2;
        target.Z += 0.3;

        if(thePlayer.IsUsingVehicle() && thePlayer.GetUsedVehicle())
        {
            thePlayer.GetUsedVehicle().Teleport(target);
        }
        else
        {
            thePlayer.Teleport(target);
        }
    }

    private function LeaveMemberState()
    {
        if(sceneProtected)
        {
            thePlayer.SetImmortalityMode(AIM_None, AIC_Scene);
            sceneProtected = false;
        }
        leaderKnown = false;
        leaderInScene = false;
        pendingFt = false;
        farSince = -1;
    }

    // "ms session downed reviveSeq aggroSeq aggroTpl x y z"
    private function SendMemberState(now : float)
    {
        var stateText : string;

        stateText = "coop ms " + sessionId + " " + CoopBit(downed) + " " + reviveSeq + " " + aggroSeq + " "
            + CoopField(aggroTpl) + " " + FloatToStringPrec(aggroPos.X, 1) + " " + FloatToStringPrec(aggroPos.Y, 1) + " "
            + FloatToStringPrec(aggroPos.Z, 1);

        if(stateText != lastMemberStateSent || now - lastMemberStateSentAt > 2.0)
        {
            WO_Send(stateText);
            lastMemberStateSent = stateText;
            lastMemberStateSentAt = now;
        }
    }

    public function OnMemberState(sender : string, count : int)
    {
        var globals : array<r_RemotePlayer>;
        var isMember : bool;
        var newSession, newReviveSeq, newAggroSeq, i : int;
        var pos : Vector;

        if(count < 8 || Role() != 1)
        {
            return;
        }

        globals = theGame.r_getMultiplayerClient().getGlobalPlayers();
        for(i = 0; i < globals.Size(); i += 1)
        {
            if(globals[i] && globals[i].username == sender && globals[i].inParty
                && globals[i].joinedParty == theGame.r_getMultiplayerClient().getUsername())
            {
                isMember = true;
            }
        }
        if(!isMember)
        {
            return;
        }

        newSession = StringToInt(WO_Str(1), 0);
        newReviveSeq = StringToInt(WO_Str(3), 0);
        newAggroSeq = StringToInt(WO_Str(4), 0);
        partnerName = sender;
        SetPartnerDowned(WO_Str(2) == "1");

        if(newSession != partnerSession)
        {
            partnerKnown = false;
            partnerSession = newSession;
        }

        if(partnerKnown && newReviveSeq != partnerReviveSeq && downed)
        {
            ReviveSelf(0.3);
            Note(sender + " tě oživila.");
        }
        if(partnerKnown && newAggroSeq != memberAggroSeq)
        {
            pos.X = StringToFloat(WO_Str(6), 0);
            pos.Y = StringToFloat(WO_Str(7), 0);
            pos.Z = StringToFloat(WO_Str(8), 0);
            HostAggro(CoopFieldValue(WO_Str(5)), pos, sender);
        }

        partnerReviveSeq = newReviveSeq;
        memberAggroSeq = newAggroSeq;
        partnerKnown = true;
    }

    // ---------------------------------------------------------------- downed and revive

    // Immortal keeps a co-op player at 1 HP instead of dying; at 1 HP the player goes down and the partner revives
    // them. Kill triggers, falls and drowning ignore immortality and still kill.
    private function DownedTick(role : int, now : float)
    {
        if(now - lastDownedCheckAt < 0.1)
        {
            return;
        }
        lastDownedCheckAt = now;

        if(role == 0)
        {
            if(downed)
            {
                ReviveSelf(0.3);
            }
            if(immortalSet)
            {
                thePlayer.SetImmortalityMode(AIM_None, AIC_Cheat);
                immortalSet = false;
            }
            partnerDowned = false;
            return;
        }

        if(dying || !thePlayer.IsAlive())
        {
            return;
        }

        if(!downed)
        {
            if(!thePlayer.IsImmortalityModeSetByChannel(AIM_Immortal, AIC_Cheat))
            {
                thePlayer.SetImmortalityMode(AIM_Immortal, AIC_Cheat);
            }
            immortalSet = true;

            // fistfights knock out through their own unconscious mode; scenes may set health themselves
            if(thePlayer.GetStatMax(BCS_Vitality) > 0 && thePlayer.GetStat(BCS_Vitality) <= 1.5
                && !thePlayer.WillBeUnconscious() && !InScene())
            {
                EnterDowned(now);
            }
            return;
        }

        if(now - downedAt >= COOP_DOWNED_TIME() || (role == 1 && partnerDowned))
        {
            DownedExpired(role);
        }
    }

    private function EnterDowned(now : float)
    {
        downed = true;
        downedAt = now;
        thePlayer.SetImmortalityMode(AIM_Invulnerable, AIC_Cheat);
        thePlayer.BlockAllActions('WO_Downed', true);
        thePlayer.SetBehaviorVariable('unconsciousEnd', 0);
        thePlayer.RaiseForceEvent('Unconscious');
        if(partnerName != "")
        {
            Note("jsi na zemi! " + partnerName + " tě může oživit Interakcí u tebe (" + FloatToStringPrec(COOP_DOWNED_TIME(), 0) + " s).");
        }
        else
        {
            Note("jsi na zemi! Spoluhráč tě může oživit Interakcí u tebe.");
        }
    }

    private function ReviveSelf(fraction : float)
    {
        if(!downed)
        {
            return;
        }
        downed = false;
        thePlayer.ForceSetStat(BCS_Vitality, fraction * thePlayer.GetStatMax(BCS_Vitality));
        thePlayer.SetBehaviorVariable('unconsciousEnd', 1);
        thePlayer.BlockAllActions('WO_Downed', false);
        thePlayer.SetImmortalityMode(AIM_Immortal, AIC_Cheat);
    }

    // Nobody came: the member gets up next to the leader; the leader dies for real (both load the leader's save).
    private function DownedExpired(role : int)
    {
        var gp : r_RemotePlayer;

        if(role == 2)
        {
            ReviveSelf(0.3);
            gp = LeaderGlobal();
            if(gp && gp.area == WO_CurrentAreaCode())
            {
                TeleportNear(gp.pos);
            }
            Note("jsi zpátky na nohou vedle hráče " + LeaderName() + ".");
            return;
        }

        downed = false;
        dying = true;
        thePlayer.BlockAllActions('WO_Downed', false);
        thePlayer.SetImmortalityMode(AIM_None, AIC_Cheat);
        immortalSet = false;
        thePlayer.Kill('WO_Downed', true);
    }

    private function SetPartnerDowned(value : bool)
    {
        if(value && !partnerDowned)
        {
            Note(partnerName + " je na zemi! Běž k němu a stiskni Interakci.");
        }
        partnerDowned = value;
    }

    // Interact on the downed partner's ghost revives them instead of opening the player menu.
    public function TryReviveGhost(ghost : CActor) : bool
    {
        var rp : r_RemotePlayer;

        if(!partnerDowned || downed || !ghost)
        {
            return false;
        }
        rp = mpghosts_getPlayerFromActor(ghost);
        if(!rp || rp.username != partnerName || VecDistance(thePlayer.GetWorldPosition(), ghost.GetWorldPosition()) > 3.5)
        {
            return false;
        }
        reviveSeq += 1;
        Note("oživuješ hráče " + partnerName + ".");
        return true;
    }

    // ---------------------------------------------------------------- deaths and resync

    public function OnLocalDeath()
    {
        var role : int;

        // a lost fistfight or a guard's knockout ends unconscious, not dead
        if(thePlayer.WillBeUnconscious())
        {
            return;
        }

        role = Role();
        dying = true;
        if(role == 1)
        {
            deathSeq += 1;
        }
        else if(role == 2)
        {
            Note("umřel jsi. Načítám poslední uloženou hru hráče " + LeaderName() + ".");
            Resync();
        }
    }

    public function RefreshNewestSave()
    {
        var saves : array<SSavegameInfo>;

        theGame.ListSavedGames(saves);
        if(saves.Size() > 0)
        {
            newestSave = saves[0].filename;
        }
    }

    // Loads the leader's newest save, which the join launcher keeps copied into this PC's co-op slot.
    public function Resync() : bool
    {
        var saves : array<SSavegameInfo>;
        var wanted : string;
        var i : int;

        if(leaderSave == "")
        {
            Note("nevím, kterou uloženou hru načíst: nejsi v partě s hostem.");
            return false;
        }

        wanted = StrLower(leaderSave);
        theGame.ListSavedGames(saves);
        for(i = 0; i < saves.Size(); i += 1)
        {
            if(StrLower(saves[i].filename) == wanted)
            {
                Note("načítám uloženou hru hráče " + LeaderName() + "...");
                theGame.LoadGameInit(saves[i], false);
                return true;
            }
        }

        Note("poslední uložená hra hráče " + LeaderName() + " u tebe ještě není. Nech běžet okno co-op spouštěče a zkus to za chvíli.");
        return false;
    }

    // ---------------------------------------------------------------- guards

    // A member's hit on a neutral NPC only angers that NPC in the member's world; the leader turns its twin
    // hostile so it becomes a shared enemy.
    public function OnNpcDamaged(npc : CNewNPC, action : W3DamageAction)
    {
        if(!npc || action.attacker != thePlayer || !npc.IsAlive() || npc.HasTag('MPEntity') || !IsMember())
        {
            return;
        }
        if(npc.GetAttitude(thePlayer) == AIA_Hostile)
        {
            return;
        }
        aggroSeq += 1;
        aggroTpl = npc.GetReadableName();
        aggroPos = npc.GetWorldPosition();
    }

    private function HostAggro(tpl : string, pos : Vector, member : string)
    {
        var entities : array<CGameplayEntity>;
        var npc, target : CNewNPC;
        var ghostPlayer : r_RemotePlayer;
        var best, dist : float;
        var i : int;

        if(tpl == "")
        {
            return;
        }

        FindGameplayEntitiesInSphere(entities, pos, 6, 16, '', FLAG_OnlyAliveActors);
        best = 999;
        for(i = 0; i < entities.Size(); i += 1)
        {
            npc = (CNewNPC)entities[i];
            if(!npc || npc.HasTag('MPEntity') || npc.GetReadableName() != tpl)
            {
                continue;
            }
            dist = VecDistance(npc.GetWorldPosition(), pos);
            if(dist < best)
            {
                best = dist;
                target = npc;
            }
        }
        if(!target)
        {
            return;
        }

        target.SetAttitude(thePlayer, AIA_Hostile);
        ghostPlayer = mpghosts_getPlayer(member);
        if(ghostPlayer && ghostPlayer.ghost)
        {
            target.SetAttitude(ghostPlayer.ghost, AIA_Hostile);
        }
        theGame.GetBehTreeReactionManager().CreateReactionEventIfPossible(target, 'CombatNearbyAction', 5.0, 18.0f, -1.f, -1, true);
    }

    // ---------------------------------------------------------------- rules

    // The leader picks in a dialogue both are in; alone, the member picks normally.
    public function BlocksOwnDialogPick() : bool
    {
        var gp : r_RemotePlayer;
        var now : float;

        if(!IsMember() || !leaderInScene)
        {
            return false;
        }
        gp = LeaderGlobal();
        if(!gp || gp.area != WO_CurrentAreaCode() || VecDistance(thePlayer.GetWorldPosition(), gp.pos) > 12.0)
        {
            return false;
        }

        now = theGame.GetEngineTimeAsSeconds();
        if(now >= nextDialogNoteAt)
        {
            Note("vybírá " + LeaderName() + ".");
            nextDialogNoteAt = now + 3.0;
        }
        return true;
    }

    // The leader's clock is the shared one; the member gets the time skip and the refill from the leader's meditation.
    public function BlocksMeditation() : bool
    {
        if(!IsMember())
        {
            return false;
        }
        Note("meditovat může jen " + LeaderName() + ". Když medituje, čas i alchymie se ti srovnají.");
        return true;
    }
}

@wrapMethod(CR4Player)
function OnDeath(damageAction : W3DamageAction)
{
    theGame.r_getMultiplayerClient().getCoopParty().OnLocalDeath();
    wrappedMethod(damageAction);
}

@wrapMethod(CR4Game)
function OnSaveCompleted(type : ESaveGameType, succeeded : bool)
{
    wrappedMethod(type, succeeded);
    if(succeeded && r_getMultiplayerClient())
    {
        r_getMultiplayerClient().getCoopParty().RefreshNewestSave();
    }
}

// member: load the leader's newest save (kept in the co-op slot by the join launcher)
exec function resync()
{
    theGame.r_getMultiplayerClient().getCoopParty().Resync();
}

@wrapMethod(CCommonMapManager)
function OnFastTravelInitiated(pinTag : name, areaID : name)
{
    wrappedMethod(pinTag, areaID);
    theGame.r_getMultiplayerClient().getCoopParty().OnLocalFastTravel(pinTag, areaID);
}

@wrapMethod(W3PlayerWitcher)
function Meditate() : bool
{
    if(theGame.r_getMultiplayerClient().getCoopParty().BlocksMeditation())
    {
        return false;
    }
    return wrappedMethod();
}

@wrapMethod(W3PlayerWitcher)
function CanOpenMeditationMenu() : bool
{
    if(theGame.r_getMultiplayerClient().getCoopParty().IsMember())
    {
        return false;
    }
    return wrappedMethod();
}

@wrapMethod(W3PlayerWitcher)
function MeditationRestoring(simulatedTime : float)
{
    wrappedMethod(simulatedTime);
    theGame.r_getMultiplayerClient().getCoopParty().OnLocalMeditationRestored(simulatedTime);
}

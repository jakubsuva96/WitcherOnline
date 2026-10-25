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

// A member's Yrden on the leader: the drawn trap gets a working area, so the leader's real monsters (wraiths above
// all) see it as Yrden. Vanilla sends EntersYrden/LeavesYrden and a short slowdown from the trap's own area.
class r_CoopYrdenZone
{
    public var trap : W3YrdenEntity;
    public var caster : CActor;
    public var center : Vector;
    public var range : float;
    public var until : float;
    public var inside : array<CNewNPC>;
    public var grounded : array<CNewNPC>;
    public var slow : SCustomEffectParams;
}

class r_CoopParty
{
    private var yrdenZones : array<r_CoopYrdenZone>;
    private var lastYrdenTickAt : float;
    private var profile : r_CoopProfile;

    public function GetProfile() : r_CoopProfile
    {
        if(!profile)
        {
            profile = new r_CoopProfile in this;
        }
        return profile;
    }

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
    private var reviveProgress : float;
    private var lastReviveTickAt : float;
    private var calmSince : float;

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

    // checkpoints: at key quest points the leader saves and the member loads that save, so the member's quest graph
    // can't hang on a scene, trigger or interaction it never got (facts only move it forward)
    private var checkpointSeq : int;
    private var checkpointPending : bool;
    private var checkpointRequestedAt : float;
    private var checkpointTries : int;
    private var lastArea : int;
    private var lastFastTravelAt : float;
    private var sessionStartAt : float;
    private var areaChecked : bool;
    private var wasCiri : bool;
    private var leaderCheckpointSeq : int;
    private var leaderCheckpointPending : bool;
    private var leaderIsCiri : bool;
    private var leaderInMinigame : bool;
    private var pendingResync : bool;
    private var resyncSince : float;
    private var nextResyncTryAt : float;
    private var spectating : bool;
    private var postTeleportUntil : float;
    private var leaderWasInScene : bool;

    // see-through look while a player can't act
    private var partnerInactive : bool;
    private var lookInactive : bool;

    // quest items the leader picked up, mirrored to the member (item-gated quest steps)
    private var questItemSeq : int;
    private var questItems : array<string>;
    private var leaderQuestItemSeq : int;

    default farSince = -1;
    default lastFastTravelAt = -999;

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
        YrdenTick(now);
        GetProfile().Tick();
        UpdateInactiveLook(role);
    }

    private function IsInactive() : bool
    {
        return downed || spectating || pendingResync;
    }

    // the partner's ghost goes see-through (client.ws, the 'invisible' effect) while the partner can't act
    public function ShowsAsInactive(username : string) : bool
    {
        return username == partnerName && (partnerDowned || partnerInactive);
    }

    // and this player's own character too, where the character's template has that effect
    private function UpdateInactiveLook(role : int)
    {
        var inactive : bool;

        inactive = role != 0 && IsInactive();
        if(inactive == lookInactive)
        {
            return;
        }
        lookInactive = inactive;
        if(inactive)
        {
            thePlayer.PlayEffect('invisible');
        }
        else
        {
            thePlayer.StopEffect('invisible');
        }
    }

    // ---------------------------------------------------------------- member Yrden on the leader

    public function AddYrdenZone(trap : W3YrdenEntity, caster : CActor, range : float, duration : float)
    {
        var zone : r_CoopYrdenZone;
        var minSlow, maxSlow : float;

        if(!trap || !caster || Role() != 1)
        {
            return;
        }

        zone = new r_CoopYrdenZone in this;
        zone.trap = trap;
        zone.caster = caster;
        zone.center = trap.GetWorldPosition();
        zone.range = range;
        zone.until = theGame.GetEngineTimeAsSeconds() + duration;

        zone.slow.effectType = EET_Slowdown;
        if(trap.actionBuffs.Size() > 0)
        {
            zone.slow.effectType = trap.actionBuffs[0].effectType;
            zone.slow.customAbilityName = trap.actionBuffs[0].effectAbilityName;
        }
        zone.slow.creator = caster;
        zone.slow.sourceName = "yrden_mode0";
        zone.slow.isSignEffect = true;
        zone.slow.duration = 0.3;
        minSlow = CalculateAttributeValue(thePlayer.GetSkillAttributeValue(S_Magic_3, 'min_slowdown', false, true));
        maxSlow = CalculateAttributeValue(thePlayer.GetSkillAttributeValue(S_Magic_3, 'max_slowdown', false, true));
        zone.slow.effectValue.valueAdditive = (minSlow + maxSlow) / 2;

        theGame.GetBehTreeReactionManager().CreateReactionEvent(trap, 'YrdenCreated', duration, 30, 0.1f, 999, true);
        yrdenZones.PushBack(zone);
    }

    private function YrdenTick(now : float)
    {
        var entities : array<CGameplayEntity>;
        var current : array<CNewNPC>;
        var zone : r_CoopYrdenZone;
        var npc : CNewNPC;
        var expired : bool;
        var i, j : int;

        if(yrdenZones.Size() == 0 || now - lastYrdenTickAt < 0.2)
        {
            return;
        }
        lastYrdenTickAt = now;

        for(i = yrdenZones.Size() - 1; i >= 0; i -= 1)
        {
            zone = yrdenZones[i];
            expired = now >= zone.until || !zone.trap || !zone.caster;

            current.Clear();
            if(!expired)
            {
                entities.Clear();
                FindGameplayEntitiesInSphere(entities, zone.center, zone.range, 32, '', FLAG_Attitude_Hostile + FLAG_OnlyAliveActors, zone.caster);
                for(j = 0; j < entities.Size(); j += 1)
                {
                    npc = (CNewNPC)entities[j];
                    if(npc && !npc.HasTag('MPEntity'))
                    {
                        current.PushBack(npc);
                    }
                }
            }

            for(j = zone.inside.Size() - 1; j >= 0; j -= 1)
            {
                if(!current.Contains(zone.inside[j]))
                {
                    LeaveYrden(zone, zone.inside[j]);
                    zone.inside.Erase(j);
                }
            }

            for(j = 0; j < current.Size(); j += 1)
            {
                npc = current[j];
                if(!zone.inside.Contains(npc))
                {
                    zone.inside.PushBack(npc);
                    npc.SignalGameplayEventParamObject('EntersYrden', zone.trap);
                }
                // flyers are pulled down once they touch the ground, as by the real trap
                if(!npc.IsFlying() && !zone.grounded.Contains(npc))
                {
                    npc.BlockAbility('Flying', true);
                    zone.grounded.PushBack(npc);
                }
                npc.AddEffectCustom(zone.slow);
            }

            if(expired)
            {
                yrdenZones.Erase(i);
            }
        }
    }

    private function LeaveYrden(zone : r_CoopYrdenZone, npc : CNewNPC)
    {
        if(!npc)
        {
            return;
        }
        if(zone.trap)
        {
            npc.SignalGameplayEventParamObject('LeavesYrden', zone.trap);
        }
        if(zone.grounded.Contains(npc))
        {
            npc.BlockAbility('Flying', false);
            zone.grounded.Remove(npc);
        }
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
        sessionStartAt = theGame.GetEngineTimeAsSeconds();
        areaChecked = false;
        pendingResync = false;
        spectating = false;
        RefreshNewestSave();
        GetProfile().OnSessionStart();
    }

    // ---------------------------------------------------------------- checkpoints (leader)

    private function RequestCheckpoint(reason : string)
    {
        if(Role() != 1 || checkpointPending)
        {
            return;
        }
        checkpointPending = true;
        checkpointRequestedAt = theGame.GetEngineTimeAsSeconds();
        checkpointTries = 1;
        theGame.RequestAutoSave("w3coop " + reason, true);
    }

    // a new world reached by quest (boat, portal, scene), a Ciri segment over, or a story quest done
    private function CheckpointTick(now : float)
    {
        var area : int;

        if(!areaChecked && now - sessionStartAt > 5.0)
        {
            areaChecked = true;
            area = WO_CurrentAreaCode();
            if(lastArea != 0 && area != lastArea && now - lastFastTravelAt > 120.0)
            {
                RequestCheckpoint("world");
            }
            lastArea = area;
        }

        if(wasCiri && !thePlayer.IsCiri())
        {
            RequestCheckpoint("ciri");
        }
        wasCiri = thePlayer.IsCiri();

        // saving can be refused (combat, scenes): ask again, and give up rather than hold the member forever
        if(checkpointPending && now - checkpointRequestedAt > 30.0)
        {
            checkpointTries += 1;
            checkpointRequestedAt = now;
            if(checkpointTries > 3)
            {
                checkpointPending = false;
            }
            else
            {
                theGame.RequestAutoSave("w3coop retry", true);
            }
        }
    }

    public function OnLocalQuestEvent(journalQuest : CJournalQuest)
    {
        if(Role() == 1 && journalQuest && journalQuest.GetType() == Story
            && theGame.GetJournalManager().GetEntryStatus(journalQuest) == JS_Success)
        {
            RequestCheckpoint("quest");
        }
    }

    // the leader's game reports the save done; a requested checkpoint becomes the member's next load
    private function CheckpointSaved()
    {
        if(checkpointPending)
        {
            checkpointPending = false;
            checkpointSeq += 1;
        }
    }

    // quest items the leader gets go to the member too (last few, by name)
    public function OnLocalItemGiven(data : SItemChangedData)
    {
        var inv : CInventoryComponent;
        var itemName : string;

        if(Role() != 1 || data.ids.Size() == 0)
        {
            return;
        }
        inv = thePlayer.GetInventory();
        if(!inv.IsItemQuest(data.ids[0]))
        {
            return;
        }
        itemName = NameToString(data.itemName);
        if(questItems.Contains(itemName))
        {
            questItems.Remove(itemName);
        }
        questItems.PushBack(itemName);
        if(questItems.Size() > 6)
        {
            questItems.Erase(0);
        }
        questItemSeq += 1;
    }

    private function QuestItemsField() : string
    {
        var text : string;
        var i : int;

        for(i = 0; i < questItems.Size(); i += 1)
        {
            if(i > 0)
            {
                text += "|";
            }
            text += questItems[i];
        }
        return CoopField(text);
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

        CheckpointTick(now);

        stateText = "coop ps " + ftSeq + " " + CoopField(NameToString(ftPin)) + " " + CoopField(NameToString(ftArea))
            + " " + scene + " " + medSeq + " " + FloatToStringPrec(medTime, 0) + " " + sessionId + " " + CoopBit(downed)
            + " " + reviveSeq + " " + deathSeq + " " + CoopField(newestSave) + " " + checkpointSeq + " "
            + CoopBit(checkpointPending) + " " + CoopBit(thePlayer.IsCiri()) + " " + CoopBit(thePlayer.IsInFistFightMiniGame())
            + " " + questItemSeq + " " + QuestItemsField();

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
        lastFastTravelAt = theGame.GetEngineTimeAsSeconds();
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
        var newFtSeq, newMedSeq, newSession, newReviveSeq, newDeathSeq, newCheckpointSeq, newQuestItemSeq : int;
        var now : float;

        now = theGame.GetEngineTimeAsSeconds();
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

        if(count >= 17)
        {
            newCheckpointSeq = StringToInt(WO_Str(12), 0);
            leaderCheckpointPending = WO_Str(13) == "1";
            leaderIsCiri = WO_Str(14) == "1";
            leaderInMinigame = WO_Str(15) == "1";
            newQuestItemSeq = StringToInt(WO_Str(16), 0);

            if(leaderKnown && newCheckpointSeq != leaderCheckpointSeq)
            {
                pendingResync = true;
                resyncSince = now;
                nextResyncTryAt = now + 3.0;
                Note(sender + " prošel klíčovým bodem příběhu. Načtu jeho hru, jakmile nebudeš v boji ani ve scéně.");
            }
            leaderCheckpointSeq = newCheckpointSeq;

            // also on the first state: items the leader has and this world lacks are added
            if(newQuestItemSeq != leaderQuestItemSeq || !leaderKnown)
            {
                MirrorQuestItems(CoopFieldValue(WO_Str(17)));
            }
            leaderQuestItemSeq = newQuestItemSeq;
        }

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

    private function MirrorQuestItems(list : string)
    {
        var names : array<string>;
        var inv : CInventoryComponent;
        var i : int;

        if(list == "")
        {
            return;
        }
        inv = thePlayer.GetInventory();
        names = WO_ProfileSplit(list, "|");
        for(i = 0; i < names.Size(); i += 1)
        {
            if(names[i] != "" && inv.GetItemQuantityByName(WO_ToName(names[i])) == 0)
            {
                inv.AddAnItem(WO_ToName(names[i]), 1);
            }
        }
    }

    // While the leader plays someone else (Ciri) or a minigame (fistfight), the member only watches: can't be hurt,
    // isn't pulled along, and gets the leader's save once the leader is back.
    private function Spectate(myScene : bool)
    {
        var should : bool;

        should = leaderIsCiri || leaderInMinigame;
        if(should && !spectating)
        {
            spectating = true;
            thePlayer.SetImmortalityMode(AIM_Invulnerable, AIC_Scene);
            if(leaderIsCiri)
            {
                Note(LeaderName() + " teď hraje za Ciri. Přihlížíš, po jejím úseku se načte jeho hra.");
            }
            else
            {
                Note(LeaderName() + " je v pěstním souboji. Přihlížíš.");
            }
        }
        else if(!should && spectating)
        {
            spectating = false;
            if(!myScene && !sceneProtected)
            {
                thePlayer.SetImmortalityMode(AIM_None, AIC_Scene);
            }
        }
    }

    private function ResyncTick(now : float, myScene : bool)
    {
        if(!pendingResync || now < nextResyncTryAt || myScene || downed || thePlayer.IsInCombat())
        {
            return;
        }
        if(Resync(true))
        {
            pendingResync = false;
            return;
        }
        nextResyncTryAt = now + 5.0;
        if(now - resyncSince > 120.0)
        {
            pendingResync = false;
            Note("hru hosta se nepodařilo načíst. Napiš do konzole resync, až bude jeho uložená hra u tebe.");
        }
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

        Spectate(myScene);
        ResyncTick(now, myScene);
        FollowScene(gp, myScene);

        // the leader's scene may have moved the leader (scene teleports): follow at once instead of in 10 s
        if(leaderWasInScene && !leaderInScene && farSince < 0)
        {
            farSince = now - COOP_LEASH_DELAY() + 1.0;
        }
        leaderWasInScene = leaderInScene;

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
        var myPos : Vector;

        // no pulling while: a scene runs, the leader is mid-load/checkpoint, the member watches or reloads, or the
        // leader is on a boat or in water (the target would be the sea)
        if(!gp || myScene || leaderInScene || now < nextFollowAt || theGame.r_getMultiplayerClient().WO_GetTeleporting()
            || now - gp.lastUpdate > 3.0 || leaderCheckpointPending || pendingResync || spectating || gp.isSailing
            || gp.isSwimming)
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

        myPos = thePlayer.GetWorldPosition();
        dist = VecDistance(myPos, gp.pos);
        // a big height difference means another floor, a cellar or a cave, where walking over may be impossible
        if(dist <= COOP_LEASH_RANGE() && !(dist > 12.0 && AbsF(myPos.Z - gp.pos.Z) > 6.0))
        {
            farSince = -1;
            return;
        }

        if(farSince < 0)
        {
            farSince = now;
            Note("jsi daleko od hráče " + LeaderName() + ", za " + FloatToStringPrec(COOP_LEASH_DELAY(), 0) + " s tě k němu přenesu.");
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

        // a moment to get one's bearings in the middle of the leader's fight
        if(!downed)
        {
            postTeleportUntil = theGame.GetEngineTimeAsSeconds() + 3.0;
            thePlayer.SetImmortalityMode(AIM_Invulnerable, AIC_Cheat);
        }
    }

    // `kjakubovi` / `tohost`: the member to the leader right now
    public function GoToLeader()
    {
        if(!IsMember())
        {
            Note("nejsi v partě s hostem.");
            return;
        }
        mpghosts_teleport(LeaderName());
        nextFollowAt = theGame.GetEngineTimeAsSeconds() + 5.0;
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
            + FloatToStringPrec(aggroPos.Z, 1) + " " + CoopBit(IsInactive());

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
        partnerInactive = count >= 9 && WO_Str(9) == "1";

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
            // after a leash teleport the channel holds a short invulnerability instead
            if(now >= postTeleportUntil && !thePlayer.IsImmortalityModeSetByChannel(AIM_Immortal, AIC_Cheat))
            {
                thePlayer.SetImmortalityMode(AIM_Immortal, AIC_Cheat);
            }
            immortalSet = true;

            if(partnerDowned)
            {
                ProximityRevive(now);
            }

            // fistfights knock out through their own unconscious mode; scenes may set health themselves
            if(thePlayer.GetStatMax(BCS_Vitality) > 0 && thePlayer.GetStat(BCS_Vitality) <= 1.5
                && !thePlayer.WillBeUnconscious() && !InScene())
            {
                EnterDowned(now);
            }
            return;
        }

        // only both down ends it; otherwise the partner comes, or the fight ends and this player gets up
        if(role == 1 && partnerDowned)
        {
            DownedExpired(role);
            return;
        }
        if(NoHostilesNear())
        {
            if(calmSince < 0)
            {
                calmSince = now;
            }
            else if(now - calmSince >= 5.0)
            {
                ReviveSelf(0.3);
                Note("boj skončil, vstáváš.");
            }
        }
        else
        {
            calmSince = -1;
        }
    }

    private function NoHostilesNear() : bool
    {
        var actors : array<CActor>;

        actors = thePlayer.GetNPCsAndPlayersInRange(25, 4, '', FLAG_Attitude_Hostile + FLAG_OnlyAliveActors + FLAG_ExcludePlayer);
        return actors.Size() == 0;
    }

    // The game blocks Interact during combat, so standing next to the downed partner for 3 s revives them too.
    private function ProximityRevive(now : float)
    {
        var rp : r_RemotePlayer;
        var dt : float;

        dt = now - lastReviveTickAt;
        lastReviveTickAt = now;
        if(dt > 0.5)
        {
            dt = 0.1;
        }

        rp = mpghosts_getPlayer(partnerName);
        if(!rp || !rp.ghost || VecDistance(thePlayer.GetWorldPosition(), rp.ghost.GetWorldPosition()) > 2.5)
        {
            reviveProgress = 0;
            return;
        }
        if(reviveProgress == 0)
        {
            Note("oživuješ hráče " + partnerName + ", zůstaň u něj 3 s...");
        }
        reviveProgress += dt;
        if(reviveProgress >= 3.0)
        {
            reviveProgress = 0;
            reviveSeq += 1;
            Note("hráč " + partnerName + " je zpátky na nohou.");
        }
    }

    private function EnterDowned(now : float)
    {
        // the partner's copy of this player stays standing; the chat line shows above this player's head there
        mpghosts_chat("Jsem na zemi! Pojď ke mně a zůstaň u mě 3 s.");
        downed = true;
        downedAt = now;
        calmSince = -1;
        thePlayer.SetImmortalityMode(AIM_Invulnerable, AIC_Cheat);
        thePlayer.BlockAllActions('WO_Downed', true);
        thePlayer.SetBehaviorVariable('unconsciousEnd', 0);
        thePlayer.RaiseForceEvent('Unconscious');
        if(partnerName != "")
        {
            Note("jsi na zemi! " + partnerName + " tě oživí, když u tebe 3 s postojí. Po konci boje vstaneš sám.");
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
            Note(partnerName + " je na zemi! Běž k němu a 3 s u něj postůj.");
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

    public function OnSaveCompleted()
    {
        RefreshNewestSave();
        CheckpointSaved();
        GetProfile().OnSaveCompleted();
    }

    // Loads the leader's newest save, which the join launcher keeps copied into this PC's co-op slot.
    public function Resync(optional quiet : bool) : bool
    {
        var saves : array<SSavegameInfo>;
        var wanted : string;
        var i : int;

        if(leaderSave == "")
        {
            if(!quiet)
            {
                Note("nevím, kterou uloženou hru načíst: nejsi v partě s hostem.");
            }
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

        if(!quiet)
        {
            Note("poslední uložená hra hráče " + LeaderName() + " u tebe ještě není. Nech běžet okno co-op spouštěče a zkus to za chvíli.");
        }
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
        // only neutral bystanders (guards, townsfolk): allies are friendly and shrug off a stray hit, as in the game
        if(npc.GetAttitude(thePlayer) != AIA_Neutral || npc.IsImportantCharacter())
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
            // the leader's copy must be a neutral bystander too: never turn an ally or a quest character
            if(!npc || npc.HasTag('MPEntity') || npc.GetReadableName() != tpl || npc.GetAttitude(thePlayer) != AIA_Neutral
                || npc.IsImportantCharacter())
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
        r_getMultiplayerClient().getCoopParty().OnSaveCompleted();
    }
}

// what the co-op sees right now, for finding out why something isn't shared
exec function coopstatus()
{
    var text : string;

    text = theGame.r_getMultiplayerClient().getCoopEnemies().StatusText();
    theGame.GetGuiManager().ShowNotification("Co-op: " + text);
    theGame.witcherLog.AddMessage("Co-op: " + text);
}

@wrapMethod(CR4Player)
function OnItemGiven(data : SItemChangedData)
{
    wrappedMethod(data);
    theGame.r_getMultiplayerClient().getCoopParty().OnLocalItemGiven(data);
}

exec function kjakubovi()
{
    theGame.r_getMultiplayerClient().getCoopParty().GoToLeader();
}

exec function tohost()
{
    theGame.r_getMultiplayerClient().getCoopParty().GoToLeader();
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

// Shared enemies (true co-op, milestone 1). The party leader's game owns the hostile NPCs near the party and
// broadcasts them ("en" channel); members mirror them as puppets (AI off, moved and healed from the leader's
// state) and send their hits to the leader ("hit" channel), who applies them to the real NPC. The leader's
// monsters attack members' ghosts; those hits go to the member ("hurt" channel) and land on their Geralt.
// Unmatched local hostiles near a member are hidden while they mirror the leader's world.

import function WO_FactsBaseline() : bool;
import function WO_FactsPage(pageSize : int) : string;

class r_CoopHostEnemy
{
    public var npc : CNewNPC;
    public var netId : int;
    public var lastSeenAt : float;
    public var deadAt : float;
    public var attackSeq : int;
    public var attackAnim : name;
    public var attackTarget : string;  // the player it attacks, for members' copies to attack the same
    public var attackTask : string;    // which attack task (CoopAttackId), for copies to make the same attack
    public var attackTaskAt : float;   // when that task started (its animation's hit windows belong to it for 2.5 s)
    public var windowSeq : int;        // the attack whose first hit window was seen (tests: LogSync)
    public var pendingTask : string;   // an attack task that started but may yet be refused (see CommitAttack)
    public var pendingAt : float;
    public var pendingWall : int;
    public var pendingFrames : int;
    public var attackAnimAt : float;   // the animation's own time when it was named, and when that was (engine time)
    public var attackNamedAt : float;
    public var lastHitAt : float;      // when it was last hit, and whether that cut its current attack short
    public var taskRunning : bool;     // its attack task still runs (its hit windows belong to it, however late)
    public var poseSnap : array<Vector>;  // its bones 0.12, 0.2, 0.3 s into an unnamed attack (PoseChecks)
    public var poseSnapTime : float;
    public var poseChecks : int;
    public var preAnim : name;         // the animation it played before its attack (OnEarlyAnimEvent), and when
    public var preAnimAt : float;
    public var earlyLogged : int;
    public var attackCut : bool;
    public var hitAnimTime : float;  // animation time of the current attack's hit
    public var hitSeq : int;         // hits it took, for members to replay the reaction
    public var hitBy : string;
    public var hitReaction : int;
    public var moveSeq : int;        // its other animated moves (dodges, taunts, ...), for members to replay
    public var moveAnim : name;
    public var moveAnimTime : float;
    public var moveKind : string;    // "dodge", "taunt", "jumpback" (members' copies make the same move), or ""
    public var moveParam : int;      // its dodge direction or taunt type
    public var moveStartTime : float;  // the move animation's own time when it was named, and when that was
    public var moveNamedAt : float;
    public var projSeq : int;        // its last projectile, for members to fire a harmless copy
    public var projAt : float;
    public var projTemplate : string;
    public var projFrom : Vector;
    public var projTo : Vector;
    public var projAngle : float;
    public var projSpeed : float;
    public var projRange : float;
    public var stride : r_CoopStride;
}

class r_CoopPuppet
{
    public var npc : CNewNPC;
    public var netId : int;
    public var spawned : bool;  // created here (destroyed on release) or a local twin (AI given back on release)
    public var aiId : int;
    public var target : Vector;
    public var yaw : float;
    public var hp : float;
    public var alive : bool;
    public var predictUntil : float;
    public var attackSeq : int;
    public var attackPlayedAt : float;
    public var attackActor : CActor;  // whom the leader's monster attacked (this player, or another player's character)
    public var attackFrom : float;    // its own attack may start from then (after a move under way) for 1.1 s
    public var attackTask : string;   // the leader's monster's attack task (CoopAttackId): this one first
    public var attackAnimText : string;  // and its animation, when known (diagnostics)
    public var attackTaskTaken : bool;   // its first attack task since (diagnostics)
    public var attackRunningSince : float;  // its attack task running since then (-1: none)
    public var puppetAnimText : string;  // its own first attack animation since (diagnostics)
    public var animsCompared : bool;
    public var aimedAt : float;       // when it was last told whom to attack (AimPuppet)
    public var slotAnimAt : float;  // an attack or move started playing (it stands meanwhile)
    public var slotAttackAt : float;  // the leader's attack animation started on its slot (SlotAttack)
    public var slotMoveAt : float;    // ...and its last move's (SlotMove)
    public var slotAnim : string;     // the animation last started on its slot, and when
    public var slotAnimStartAt : float;
    public var slotChecked : bool;    // whether that animation's hit window came (SlotAttackCheck)
    public var hitMirroredAt : float;
    public var attackCut : bool;      // the leader's monster's attack was cut short (StopSlotAttack)
    public var attackAnimAt : float;  // how far into the animation the leader's monster was when it was sent
    public var attackAnimGotAt : float;
    public var catchUpId : int;       // a faster animation speed while a late slot attack catches up (until catchUpUntil)
    public var catchUpUntil : float;
    public var slotRefusedAt : float;  // the slot refused the leader's animation (its own swing stands in)
    public var taskPending : string;  // its own attack task that started but may yet be refused (ConfirmPuppetTask)
    public var taskPendingAt : float;
    public var taskPendingFrames : int;
    public var moveSeq : int;
    public var projSeq : int;
    public var animAiId : int;
    public var hitSeq : int;
    public var wasInHitAnim : bool;
    public var wasDodging : bool;
    public var targetSpeed : float;   // how fast the leader's monster moves (m/s, smoothed), for its locomotion
    public var lastTargetAt : float;
    public var stride : r_CoopStride;
    public var reactUntil : float;  // forced idle lifted until then, so the AI plays the hit reaction
    public var addedNoFinishers : array<name>;
    public var moveKind : string;   // a mirrored move its own AI is to make (see PlayMove), until moveUntil
    public var moveParam : int;
    public var movePlayedAt : float;
    public var moveUntil : float;
    public var moveStarted : bool;
    public var moveAnimSeen : name;  // its last move animation (OnPuppetMoveAnim)
    public var moveAnimSeenTime : float;
    public var moveAnimated : bool;  // the mirrored move's animation really started
    public var moveSignals : int;    // diagnostics of the current mirrored move (see TraceMove)
    public var moveAccepted : int;
    public var moveActivatedAt : float;
    public var moveActStatus : string;
    public var moveAnimAt : float;
    public var moveAnimName : name;
    public var moveRetargets : int;
}

// Feet swinging along the actor's facing over 1.5 s windows while it moves: a walking stride swings a foot tens of
// centimeters back and forth, a slide barely at all. Diagnostics for the locomotion of puppets.
class r_CoopStride
{
    public var bones : array<int>;
    public var lows : array<float>;
    public var highs : array<float>;
    public var boneLabel : string;
    public var pelvis : int;
    public var tries : int;
    public var windowStart : float;
    public var maxSwing : float;
    public var lastPos : Vector;
    public var lastAt : float;
    public var speed : float;

    default windowStart = -1;

    // the actor's own speed from its positions (m/s, smoothed); velocity reads 0 on monsters
    public function OwnSpeed(actor : CActor, now : float) : float
    {
        var pos : Vector;

        pos = actor.GetWorldPosition();
        if(lastAt > 0 && now - lastAt > 0.01)
        {
            speed = 0.8 * speed + 0.2 * VecDistance2D(pos, lastPos) / (now - lastAt);
        }
        lastPos = pos;
        lastAt = now;
        return speed;
    }

    public function Update(actor : CActor, moving : bool, now : float)
    {
        var base, facing : Vector;
        var offset : float;
        var i : int;

        if(!moving)
        {
            // a movement shorter than a window still counts
            if(windowStart >= 0 && now - windowStart >= 0.5)
            {
                CloseWindow();
            }
            windowStart = -1;
            return;
        }
        // searched while moving, once the actor is posed where it walks
        if(bones.Size() == 0 && tries < 30)
        {
            tries += 1;
            FindBones(actor);
        }
        if(bones.Size() == 0)
        {
            return;
        }
        if(windowStart >= 0 && now - windowStart > 1.5)
        {
            CloseWindow();
            windowStart = -1;
        }
        // against the pelvis of the same pose, so a slide moving the root between poses doesn't count
        base = actor.GetWorldPosition();
        if(pelvis >= 0)
        {
            base = MatrixGetTranslation(actor.GetBoneWorldMatrixByIndex(pelvis));
        }
        facing = VecFromHeading(actor.GetHeading());
        for(i = 0; i < bones.Size(); i += 1)
        {
            offset = VecDot(MatrixGetTranslation(actor.GetBoneWorldMatrixByIndex(bones[i])) - base, facing);
            if(windowStart < 0)
            {
                lows[i] = offset;
                highs[i] = offset;
            }
            else
            {
                lows[i] = MinF(lows[i], offset);
                highs[i] = MaxF(highs[i], offset);
            }
        }
        if(windowStart < 0)
        {
            windowStart = now;
        }
    }

    private function CloseWindow()
    {
        var i : int;

        for(i = 0; i < bones.Size(); i += 1)
        {
            maxSwing = MaxF(maxSwing, highs[i] - lows[i]);
        }
    }

    // the feet by their usual names, else the bones nearest points at foot height around the body (skeletons name
    // their feet differently; the root under the body doesn't count); the torso stands in for a missing pelvis
    private function FindBones(actor : CActor)
    {
        var offsets : array<Vector>;
        var pos, probe, found : Vector;
        var heading : float;
        var bone, i : int;

        pelvis = actor.GetBoneIndex('pelvis');
        if(pelvis < 0)
        {
            pelvis = actor.GetTorsoBoneIndex();
        }
        AddBone(actor.GetBoneIndex('l_foot'));
        AddBone(actor.GetBoneIndex('r_foot'));
        if(bones.Size() > 0)
        {
            boneLabel = "feet";
            return;
        }
        if(!actor.GetRootAnimatedComponent())
        {
            return;
        }
        pos = actor.GetWorldPosition();
        heading = actor.GetHeading();
        offsets.PushBack(VecFromHeading(heading) * 0.6 + VecFromHeading(heading - 90) * 0.3);
        offsets.PushBack(VecFromHeading(heading + 180) * 0.6 + VecFromHeading(heading - 90) * 0.3);
        offsets.PushBack(VecFromHeading(heading - 90) * 0.6);
        offsets.PushBack(VecFromHeading(heading + 90) * 0.6);
        for(i = 0; i < offsets.Size(); i += 1)
        {
            probe = pos + offsets[i];
            probe.Z += 0.1;
            bone = actor.GetRootAnimatedComponent().FindNearestBoneWS(probe);
            if(bone > 0)
            {
                found = MatrixGetTranslation(actor.GetBoneWorldMatrixByIndex(bone));
                if(VecDistance2D(found, pos) >= 0.05 && found.Z - pos.Z <= 0.5)
                {
                    AddBone(bone);
                }
            }
        }
        boneLabel = "";
        for(i = 0; i < bones.Size(); i += 1)
        {
            boneLabel += "#" + bones[i];
        }
    }

    private function AddBone(bone : int)
    {
        if(bone >= 0 && !bones.Contains(bone))
        {
            bones.PushBack(bone);
            lows.PushBack(0);
            highs.PushBack(0);
        }
    }
}

class r_CoopSuppressed
{
    public var npc : CNewNPC;
    public var aiId : int;
}

class r_CoopHit
{
    public var seq : int;
    public var netId : int;
    public var frac : float;
    public var effects : array<int>;  // what the hit applies (burning, knockdown, ...), applied by the leader
}

// a leader monster's hit on a member's ghost: raw damage before the ghost's own stats
class r_CoopHurt
{
    public var user : string;
    public var seq : int;
    public var netId : int;
    public var hitReaction : int;
    public var attackSeq : int;     // the attack that landed it, to line it up with the puppet's swing
    public var hitAnimTime : float;
    public var due : float;         // member: when to apply it
    public var receivedAt : float;
    public var types : array<name>;
    public var values : array<float>;
    public var effects : array<int>; // EEffectType of the hit's buffs (bleeding, knockdown, ...)
}

class r_CoopAck
{
    public var user : string;
    public var session : int;
    public var lastSeq : int;
}

class r_CoopEnemies
{
    private var epoch : int;    // this game as leader: changes on restart so members drop stale ids
    private var session : int;  // this game as member: lets the leader restart hit numbering
    private var nextNetId : int;
    private var nextHitSeq : int;

    private var hostEnemies : array<r_CoopHostEnemy>;
    private var acks : array<r_CoopAck>;
    private var hurts : array<r_CoopHurt>;
    private var nextHurtSeq : int;
    private var lastHurtSend : float;
    private var lastHurtSentCount : int;
    private var armedGhosts : array<CActor>;
    private var wasHost : bool;
    private var lastHostSend : float;
    private var hostSeq : int;

    private var puppets : array<r_CoopPuppet>;
    private var suppressed : array<r_CoopSuppressed>;
    private var leaderName : string;
    private var leaderEpoch : int;
    private var lastSnapshotAt : float;
    private var pendingHits : array<r_CoopHit>;
    private var lastPuppetAction : W3DamageAction;  // this player's last damaging hit on a puppet, and its claim
    private var lastPuppetHit : r_CoopHit;
    private var lastHitSend : float;
    private var lastHitSentCount : int;
    private var hurtAck : int;
    private var lastSentHurtAck : int;
    private var leaderListsMyHurts : bool;
    private var delayedHurts : array<r_CoopHurt>;

    // journal entries (quests, objectives) whose status changed this session, latest status per tag
    private var journalTags : array<name>;
    private var journalStatus : array<int>;
    private var journalTick : int;
    private var lastJournalSend : float;
    private var applyingJournal : bool;
    private var journalIndexTags : array<name>;
    private var journalIndexEntries : array<CJournalBase>;
    private var journalIndexBuiltAt : float;

    // scenes and the leader's tracking (sent with the journal list)
    private var currentScene : string;
    private var sceneSkipSeq : int;
    private var sceneSkipValue : int;
    private var applyingSkip : bool;
    private var sentTrackedQuest : name;
    private var sentHighlighted : name;
    private var leaderTrackedQuest : name;
    private var leaderHighlighted : name;
    private var leaderSceneSeen : string;
    private var leaderSkipSeen : int;

    // quest facts: changes since this save was loaded, read from the engine by the client ASI
    private var factsReady : bool;
    private var nextFactsTry : float;
    private var lastFactsSend : float;
    private var factsTick : int;

    // set while this game changes a puppet itself, so the damage hook lets it through
    public var applyingHostState : bool;

    // diagnostics for logs and the test bot
    public var hitsSent : int;
    public var hitsApplied : int;
    public var puppetsSpawned : int;
    public var puppetsKilled : int;  // puppets that died with the leader's monster
    public var twinsBound : int;
    public var spawnFailures : int;
    public var lastError : string;
    public var lastHitFrac : float;
    public var hurtsCaptured : int;
    public var ghostHitsSeen : int;
    public var hurtsApplied : int;
    public var hurtsDodged : int;
    public var hurtDamageTaken : float;
    public var attacksSeen : int;
    public var attacksPlayed : int;
    public var attackPlayFailures : int;
    public var puppetAttackEvents : int;  // member: attack animations that really played on puppets
    public var puppetOwnAttacks : int;    // member: attacks a puppet started by itself (should not happen)
    public var puppetWrongTargets : int;  // member: mirrored attacks a puppet aimed at someone else than the leader's monster
    public var puppetSameTasks : int;     // member: mirrored attacks a puppet made with the leader's monster's attack task
    public var puppetSwingSwaps : int;    // member: ... with another plain swing
    public var puppetOtherTasks : int;    // member: ... with another one (the same was not available in time)
    public var puppetSameAnims : int;     // member: puppets' attack animations the same as the leader's monster's
    public var lastAttackTask : string;   // leader
    public var lastPuppetTask : string;   // member: the last mirrored attack task a puppet took (expected->taken if another)
    public var puppetAttackQuickEnds : int;  // member: puppets' attack tasks over within 0.5 s (diagnostics)
    public var spellWrongTargets : int;   // member: puppets' spells spawned while aimed at another player
    public var attackAnimsCompared : int; // member: mirrored attacks whose two animations were compared (puppetSameAnims)
    public var lastAnimPair : string;
    public var gateAsked : int;           // member: diagnostics of PuppetAttackAllowed while an attack is due
    public var gateHeldByMove : int;
    public var gateOtherTask : int;
    public var lastGateDenied : string;  // expected/offered
    public var lastFxSpawn : string;      // diagnostics: the last FX entity a shared monster (leader) or puppet spawned
    public var puppetFxTasks : int;       // member: puppets' FX spawn tasks that started
    public var puppetAiFree : bool;       // puppets' AI free while their monster fights (tests can turn it off)
        default puppetAiFree = true;
    public var slotAttacks : bool;        // member: the leader's swing animations play on puppets' slots (tests can turn it off)
        default slotAttacks = true;
    public var attackSlot : name;         // the graph slot they play on
        default attackSlot = 'NPC_ANIM_SLOT';
    public var slotAttacksPlayed : int;   // member: attack animations started on a slot
    public var slotAttacksRefused : int;
    public var lastSlotState : string;    // diagnostics: the puppet's graph when its last slot attack started
    public var slotAttacksMissed : int;   // member: slot attacks whose hit window never came
    public var slotCatchUps : int;        // member: slot attacks and moves sped up to catch up
    public var slotMoves : bool;          // member: the leader's moves play on puppets' slots (tests can turn it off)
        default slotMoves = true;
    public var slotMovesPlayed : int;     // member: moves started on a slot
    public var slotDodgesParries : int;   // ...of them dodges and parries
    public var slotMovesRefused : int;
    public var leaderNamesAnims : bool;   // member: the leader names its monsters' attack animations (not 0.2.0)
    public var attackFalseStarts : int;   // leader: attack tasks refused right away (not sent)
    public var poseNaming : bool;         // leader: unnamed swings named from the monster's pose (tests can turn it off)
        default poseNaming = true;
    public var poseNamed : int;           // leader: swings named so
    private var poseTemplates : array<string>;  // leader: the swings each monster type made (parallel arrays, PoseLearn)
    private var poseAnims : array<name>;
    private var slotMissedOnce : array<string>;  // monsters (templates) whose last slot attack missed
    private var slotless : array<string>;        // ...and those that missed twice in a row: no slot attacks
    public var syncLog : array<string>;   // tests: "kind netId seq what engineTime wall=ms" events (LogSync), drained by the test bot
    public var spellSpawns : int;         // area spells (spawned roots, entities) by shared monsters (leader) or puppets (member)
    public var projectilesMuted : int;    // member: puppets' own projectiles that didn't fly (MutesShot)
    private var firingProjectileCopy : bool;
    public var projectileSpawner : CNewNPC;  // a monster whose task is spawning projectiles without a caster right now
    public var puppetDodgesSeen : int;    // member: puppets really dodging
    public var dodgesMirrored : int;      // member: the leader's monsters' dodges passed on to their puppets
    public var movesSeen : int;
    public var lastMoveAnim : name;
    public var lastMoveKind : string;
    public var lastMoveTask : string;     // leader: the task class that made it
    public var lastPuppetMoveAnim : name; // member
    public var moveAnimEvents : int;      // member: animation events of any NPC's move tasks (diagnostics)
    public var tauntsMirrored : int;      // member: of movesPlayed
    public var puppetTauntsStarted : int; // member: of puppetMovesStarted
    public var parriesMirrored : int;     // member: of movesPlayed
    public var puppetParriesStarted : int;  // member: of puppetMovesStarted
    public var movesAnimOnly : int;       // member: other moves (or from an older leader), as slot animations
    public var moveTrace : string;        // member: how the last mirrored moves went (diagnostics)
    public var movesPlayed : int;
    public var movePlayFailures : int;
    public var puppetMovesStarted : int;  // member: mirrored moves a puppet's own AI started
    public var puppetMovesAnimated : int; // member: of those, ones whose animation was seen playing
    public var puppetDodgesAnimated : int;
    public var puppetMovesMissed : int;   // member: mirrored moves it didn't start in time
    public var puppetOwnMoves : int;      // member: dodges, taunts, jump-backs a puppet started by itself (should not happen)
    public var projectilesSeen : int;
    public var hitEffectsSent : int;     // member: effects its hits carried
    public var hitEffectsApplied : int;  // leader: effects of members' hits applied to its monsters
    public var hitEffectsHeld : int;     // leader: of those, ones the monster had right after
    public var signVisualsPlayed : int;  // other players' sign visuals shown at their copies (remotePlayer.ws)
    public var signVisualsActive : int;
    public var signVisualsByType : array<int>;  // by ESignType
    public var quenShieldsShown : int;
    public var quenHitsShown : int;      // shields that went down with the sign's burst
    public var yrdenRunesShown : int;
    public var lastSignVisual : string;  // the last one's type, effects and whether the first went active
    public var assumeOldSigns : bool;    // tests: read others' snapshots as from a version without fields 73-79
    public var meleeHitsSent : int;
    public var signHitsSent : int;
    public var projectilesFired : int;
    public var projectileFailures : int;
    public var lastHurtDelay : float;
    public var hitReactionsMirrored : int;
    public var hitAnimsSeen : int;  // puppets entering a hit animation (shows the reactions really play)
    public var hostMaxSwing : float;    // stride of the leader's real monsters while they move (calibration)
    public var puppetMaxSwing : float;  // stride of puppets while their leader's monster moves
    public var strideBone : string;
    public var puppetLocomotion : bool;  // off: puppets only slide (the glide baseline for the stride tests)
    public var hurtEffectsApplied : int;
    public var journalApplied : int;
    public var lastJournalApplied : name;
    public var journalMessages : int;   // journal lists accepted from the leader
    public var journalMissing : int;    // entries this game could not find
    public var lastJournalSeen : string;
    public var trackedApplied : int;
    public var lastTrackedApplied : name;
    public var skipsApplied : int;
    public var factsApplied : int;
    public var lastFactApplied : string;
    public var lastJournalAppliedStatus : int;

    default puppetLocomotion = true;
    default lastHostSend = -999;
    default lastSnapshotAt = -999;
    default lastHitSend = -999;
    default lastHurtSend = -999;
    default lastJournalSend = -999;
    default lastFactsSend = -999;
    default journalIndexBuiltAt = -999;

    private function EnsureIds()
    {
        if(epoch == 0)
        {
            epoch = RandRange(1000000000, 1);
            session = RandRange(1000000000, 1);
            nextNetId = 1;
            nextHitSeq = 1;
            nextHurtSeq = 1;
        }
    }

    // 0 off, 1 leader of a party with members, 2 member
    public function GetRole() : int
    {
        var client : r_MultiplayerClient;
        var globals : array<r_RemotePlayer>;
        var localOnly : bool;
        var me : string;
        var i : int;

        client = theGame.r_getMultiplayerClient();
        localOnly = theGame.GetInGameConfigWrapper().GetVarValue('MPGhosts_Main', 'MPGhosts_LocalEnemiesOnly');
        if(!client || localOnly)
        {
            return 0;
        }

        if(client.getInParty() && client.getJoinedParty() != "" && client.getJoinedParty() != "none")
        {
            return 2;
        }

        me = client.getUsername();
        globals = client.getGlobalPlayers();
        for(i = 0; i < globals.Size(); i += 1)
        {
            if(globals[i] && globals[i].inParty && globals[i].joinedParty == me)
            {
                return 1;
            }
        }
        return 0;
    }

    // called every frame from the client's tick while in game
    public function Tick()
    {
        var client : r_MultiplayerClient;
        var role : int;
        var now : float;

        client = theGame.r_getMultiplayerClient();
        if(!client || !thePlayer)
        {
            return;
        }

        EnsureIds();
        now = theGame.GetEngineTimeAsSeconds();
        RetryFactsBaseline(now);
        role = GetRole();

        if(role == 1)
        {
            if(poseNaming)
            {
                PoseChecks(now);
            }
            if(CommitDueAttacks(now) || now - lastHostSend >= COOP_SEND_INTERVAL())
            {
                HostCollect(client, now);
                HostSend();
                lastHostSend = now;
            }
            MeasureHostStrides(now);
            SendHurts(now);
            if(TrackingChanged())
            {
                lastJournalSend = -999;
            }
            SendJournal(now);
            SendFacts(now);
            wasHost = true;
        }
        else if(wasHost)
        {
            hostEnemies.Clear();
            hurts.Clear();
            DisarmGhosts();
            HostSend();
            SendHurts(now);
            wasHost = false;
        }

        if(role == 2)
        {
            if(leaderName != client.getJoinedParty())
            {
                ReleaseAll();
                pendingHits.Clear();
                leaderName = client.getJoinedParty();
                leaderEpoch = 0;
                hurtAck = 0;
                delayedHurts.Clear();
            }

            // the leader's snapshots also stop while its game sits in a menu; far from the leader, this world
            // runs its own monsters again
            if(now - lastSnapshotAt > 8.0 || !LeaderNear())
            {
                ReleaseAll();
            }
            else
            {
                ArmLeaderGhost();
                UpdatePuppets(now);
            }
            ApplyDueHurts(now);
            SendHits(now);
        }
        else if(puppets.Size() > 0 || suppressed.Size() > 0)
        {
            ReleaseAll();
            leaderName = "";
        }
        if(role != 2 && !wasHost && armedGhosts.Size() > 0)
        {
            DisarmGhosts();
        }
    }

    // ---------------------------------------------------------------- leader

    private function HostCollect(client : r_MultiplayerClient, now : float)
    {
        var candidates : array<CActor>;
        var entities : array<CGameplayEntity>;
        var globals : array<r_RemotePlayer>;
        var attitudeRef : CGameplayEntity;
        var npc : CNewNPC;
        var e : r_CoopHostEnemy;
        var me : string;
        var area : int;
        var i, j : int;

        candidates = thePlayer.GetNPCsAndPlayersInRange(40, 48, '', FLAG_Attitude_Hostile + FLAG_OnlyAliveActors + FLAG_ExcludePlayer);

        me = client.getUsername();
        area = WO_CurrentAreaCode();
        globals = client.getGlobalPlayers();
        for(i = 0; i < globals.Size(); i += 1)
        {
            if(!globals[i] || !globals[i].inParty || globals[i].joinedParty != me || globals[i].area != area
                || VecDistance(globals[i].pos, thePlayer.GetWorldPosition()) > COOP_SHARE_RANGE())
            {
                continue;
            }

            // hostile to the member's ghost (armed below) as well as to this Geralt
            attitudeRef = GhostOf(globals[i].username);
            if(!attitudeRef)
            {
                attitudeRef = thePlayer;
            }
            entities.Clear();
            FindGameplayEntitiesInSphere(entities, globals[i].pos, 40, 48, '', FLAG_Attitude_Hostile + FLAG_OnlyAliveActors, attitudeRef);
            for(j = 0; j < entities.Size(); j += 1)
            {
                if((CActor)entities[j] && !candidates.Contains((CActor)entities[j]))
                {
                    candidates.PushBack((CActor)entities[j]);
                }
            }
        }

        for(i = 0; i < candidates.Size(); i += 1)
        {
            npc = (CNewNPC)candidates[i];
            if(!npc || npc.HasTag('MPEntity') || npc.IsHorse())
            {
                continue;
            }

            e = FindHostEnemyByNpc(npc);
            if(!e)
            {
                if(hostEnemies.Size() >= 24)
                {
                    continue;
                }
                e = new r_CoopHostEnemy in this;
                e.npc = npc;
                e.netId = nextNetId;
                e.deadAt = -1;
                nextNetId += 1;
                hostEnemies.PushBack(e);
            }
            e.lastSeenAt = now;
        }

        ArmGhosts(client);

        // keep dead enemies for a few seconds so members see the death; drop ones out of range
        for(i = hostEnemies.Size() - 1; i >= 0; i -= 1)
        {
            e = hostEnemies[i];
            if(!e.npc)
            {
                hostEnemies.Erase(i);
                continue;
            }
            if(e.deadAt < 0 && !e.npc.IsAlive())
            {
                e.deadAt = now;
            }
            if((e.deadAt >= 0 && now - e.deadAt > 4.0) || (e.deadAt < 0 && now - e.lastSeenAt > 3.0))
            {
                hostEnemies.Erase(i);
            }
        }
    }

    // "en epoch seq area acks{user session lastSeq} templates{path}
    //  enemies{netId tpl appearance x y z yaw hp alive attackSeq attackAnim hitSeq hitBy hitReaction moveSeq move
    //  attackTarget projSeq [projTpl fromX fromY fromZ toX toY toZ angle speed range]}" (projSeq 0 = no projectile in the
    //  last 1.5 s; move: see MoveText)
    private function HostSend()
    {
        var templates : array<string>;
        var body : string;
        var tpl : string;
        var pos : Vector;
        var e : r_CoopHostEnemy;
        var tplIndex : int;
        var alive : int;
        var i : int;
        var now : float;

        now = theGame.GetEngineTimeAsSeconds();
        hostSeq += 1;
        body = "";
        for(i = 0; i < hostEnemies.Size(); i += 1)
        {
            e = hostEnemies[i];
            tpl = CoopEncode(e.npc.GetReadableName());
            tplIndex = templates.FindFirst(tpl);
            if(tplIndex < 0)
            {
                templates.PushBack(tpl);
                tplIndex = templates.Size() - 1;
            }

            pos = e.npc.GetWorldPosition();
            alive = 0;
            if(e.deadAt < 0)
            {
                alive = 1;
            }

            body += " " + e.netId + " " + tplIndex + " " + CoopEncode(NameToString(e.npc.GetAppearance()))
                + " " + FloatToStringPrec(pos.X, 2) + " " + FloatToStringPrec(pos.Y, 2) + " " + FloatToStringPrec(pos.Z, 2)
                + " " + FloatToStringPrec(e.npc.GetHeading(), 1) + " " + FloatToStringPrec(MaxF(0, e.npc.GetHealthPercents()), 4)
                + " " + alive + " " + e.attackSeq + " " + CoopEncode(AttackText(e))
                + " " + e.hitSeq + " " + CoopEncode(e.hitBy) + " " + e.hitReaction
                + " " + e.moveSeq + " " + CoopEncode(MoveText(e)) + " " + CoopEncode(e.attackTarget);

            if(e.projSeq > 0 && now - e.projAt < 1.5)
            {
                tpl = CoopEncode(e.projTemplate);
                tplIndex = templates.FindFirst(tpl);
                if(tplIndex < 0)
                {
                    templates.PushBack(tpl);
                    tplIndex = templates.Size() - 1;
                }
                body += " " + e.projSeq + " " + tplIndex
                    + " " + FloatToStringPrec(e.projFrom.X, 2) + " " + FloatToStringPrec(e.projFrom.Y, 2) + " " + FloatToStringPrec(e.projFrom.Z, 2)
                    + " " + FloatToStringPrec(e.projTo.X, 2) + " " + FloatToStringPrec(e.projTo.Y, 2) + " " + FloatToStringPrec(e.projTo.Z, 2)
                    + " " + FloatToStringPrec(e.projAngle, 1) + " " + FloatToStringPrec(e.projSpeed, 1) + " " + FloatToStringPrec(e.projRange, 1);
            }
            else
            {
                body += " 0";
            }
        }

        WO_Send("coop en " + epoch + " " + hostSeq + " " + WO_CurrentAreaCode() + " " + AcksText() + " " + TemplatesText(templates)
            + " " + hostEnemies.Size() + body);
    }

    // "task|anim|time|cut" (CoopAttackId, "" without a task; the animation as soon as it is known, how far into it the
    // monster is now, and "1" once a hit cut it short). 0.2.0 members take the text as an animation name, which they
    // don't use, and attack.
    private function AttackText(e : r_CoopHostEnemy) : string
    {
        var cut : string;

        if(e.attackCut)
        {
            cut = "|1";
        }
        if(!IsNameValid(e.attackAnim))
        {
            if(e.attackCut)
            {
                return e.attackTask + "||0" + cut;
            }
            return e.attackTask + "|";
        }
        return e.attackTask + "|" + NameToString(e.attackAnim) + "|"
            + FloatToStringPrec(e.attackAnimAt + theGame.GetEngineTimeAsSeconds() - e.attackNamedAt, 2) + cut;
    }

    // "kind:param:anim:time": the move's kind ("" for other animated moves), its direction or type, its animation and
    // how far into it the monster is now (0.2.0 members take the text as an animation name that doesn't exist, which
    // plays nothing, as their slot actions did anyway)
    private function MoveText(e : r_CoopHostEnemy) : string
    {
        return e.moveKind + ":" + e.moveParam + ":" + NameToString(e.moveAnim) + ":"
            + FloatToStringPrec(e.moveStartTime + theGame.GetEngineTimeAsSeconds() - e.moveNamedAt, 2);
    }

    private function AcksText() : string
    {
        var text : string;
        var i : int;

        text = "" + acks.Size();
        for(i = 0; i < acks.Size(); i += 1)
        {
            text += " " + acks[i].user + " " + acks[i].session + " " + acks[i].lastSeq;
        }
        return text;
    }

    private function TemplatesText(templates : array<string>) : string
    {
        var text : string;
        var i : int;

        text = "" + templates.Size();
        for(i = 0; i < templates.Size(); i += 1)
        {
            text += " " + templates[i];
        }
        return text;
    }

    public function CountSignVisual(type : ESignType)
    {
        while(signVisualsByType.Size() <= (int)type)
        {
            signVisualsByType.PushBack(0);
        }
        signVisualsByType[(int)type] += 1;
    }

    public function SignVisualsOf(type : ESignType) : int
    {
        if((int)type < signVisualsByType.Size())
        {
            return signVisualsByType[(int)type];
        }
        return 0;
    }

    // tests: zero the diagnostics between scenarios run in one game session
    public function ResetDiagnostics()
    {
        hitsSent = 0;
        hitsApplied = 0;
        puppetsSpawned = 0;
        puppetsKilled = 0;
        twinsBound = 0;
        spawnFailures = 0;
        lastError = "";
        lastHitFrac = 0;
        hurtsCaptured = 0;
        ghostHitsSeen = 0;
        hurtsApplied = 0;
        hurtsDodged = 0;
        hurtDamageTaken = 0;
        attacksSeen = 0;
        attacksPlayed = 0;
        attackPlayFailures = 0;
        puppetAttackEvents = 0;
        puppetOwnAttacks = 0;
        puppetWrongTargets = 0;
        puppetSameTasks = 0;
        puppetOtherTasks = 0;
        puppetSwingSwaps = 0;
        puppetSameAnims = 0;
        lastAttackTask = "";
        lastPuppetTask = "";
        spellSpawns = 0;
        lastFxSpawn = "";
        puppetFxTasks = 0;
        gateAsked = 0;
        gateHeldByMove = 0;
        gateOtherTask = 0;
        spellWrongTargets = 0;
        attackAnimsCompared = 0;
        slotAttacksPlayed = 0;
        slotAttacksRefused = 0;
        slotAttacksMissed = 0;
        slotCatchUps = 0;
        slotMovesPlayed = 0;
        slotDodgesParries = 0;
        slotMovesRefused = 0;
        attackFalseStarts = 0;
        puppetAttackQuickEnds = 0;
        projectilesMuted = 0;
        puppetDodgesSeen = 0;
        dodgesMirrored = 0;
        movesSeen = 0;
        lastMoveAnim = '';
        lastMoveKind = "";
        lastMoveTask = "";
        lastPuppetMoveAnim = '';
        moveAnimEvents = 0;
        tauntsMirrored = 0;
        puppetTauntsStarted = 0;
        parriesMirrored = 0;
        puppetParriesStarted = 0;
        movesAnimOnly = 0;
        moveTrace = "";
        movesPlayed = 0;
        movePlayFailures = 0;
        puppetMovesStarted = 0;
        puppetMovesAnimated = 0;
        puppetDodgesAnimated = 0;
        puppetMovesMissed = 0;
        puppetOwnMoves = 0;
        projectilesSeen = 0;
        hitEffectsSent = 0;
        hitEffectsApplied = 0;
        hitEffectsHeld = 0;
        signVisualsPlayed = 0;
        signVisualsActive = 0;
        signVisualsByType.Clear();
        quenShieldsShown = 0;
        quenHitsShown = 0;
        yrdenRunesShown = 0;
        lastSignVisual = "";
        assumeOldSigns = false;
        meleeHitsSent = 0;
        signHitsSent = 0;
        projectilesFired = 0;
        projectileFailures = 0;
        lastHurtDelay = 0;
        hitReactionsMirrored = 0;
        hitAnimsSeen = 0;
        hostMaxSwing = 0;
        puppetMaxSwing = 0;
        strideBone = "";
        puppetLocomotion = true;
        hurtEffectsApplied = 0;
    }

    public function SetPuppetLocomotion(on : bool)
    {
        puppetLocomotion = on;
    }

    private function MeasureHostStrides(now : float)
    {
        var e : r_CoopHostEnemy;
        var i : int;

        for(i = 0; i < hostEnemies.Size(); i += 1)
        {
            e = hostEnemies[i];
            if(!e.npc || e.deadAt >= 0)
            {
                continue;
            }
            if(!e.stride)
            {
                e.stride = new r_CoopStride in this;
            }
            e.stride.Update(e.npc, e.stride.OwnSpeed(e.npc, now) > 1.0, now);
            hostMaxSwing = MaxF(hostMaxSwing, e.stride.maxSwing);
            strideBone = e.stride.boneLabel + "/" + e.stride.pelvis;
        }
    }

    private function FindHostEnemyByNpc(npc : CNewNPC) : r_CoopHostEnemy
    {
        var i : int;

        for(i = 0; i < hostEnemies.Size(); i += 1)
        {
            if(hostEnemies[i].npc == npc)
            {
                return hostEnemies[i];
            }
        }
        return NULL;
    }

    private function FindHostEnemy(netId : int) : r_CoopHostEnemy
    {
        var i : int;

        for(i = 0; i < hostEnemies.Size(); i += 1)
        {
            if(hostEnemies[i].netId == netId)
            {
                return hostEnemies[i];
            }
        }
        return NULL;
    }

    private function FindAck(user : string, memberSession : int) : r_CoopAck
    {
        var ack : r_CoopAck;
        var i : int;

        for(i = 0; i < acks.Size(); i += 1)
        {
            if(acks[i].user == user)
            {
                if(acks[i].session != memberSession)
                {
                    acks[i].session = memberSession;
                    acks[i].lastSeq = 0;
                }
                return acks[i];
            }
        }

        ack = new r_CoopAck in this;
        ack.user = user;
        ack.session = memberSession;
        acks.PushBack(ack);
        return ack;
    }

    // "hit leader epoch session hurtAck count {seq netId fraction}": all hits the member has not seen
    // acknowledged yet, and the last hurt it applied
    private function OnHits(sender : string, count : int)
    {
        var client : r_MultiplayerClient;
        var ack : r_CoopAck;
        var effects : array<int>;
        var n, i, j, idx, seq, effectCount : int;

        client = theGame.r_getMultiplayerClient();
        if(count < 6 || WO_Str(1) != client.getUsername() || StringToInt(WO_Str(2), 0) != epoch || !IsMyPartyMember(sender))
        {
            return;
        }

        PruneHurts(sender, StringToInt(WO_Str(4), 0));
        ack = FindAck(sender, StringToInt(WO_Str(3), 0));
        n = StringToInt(WO_Str(5), 0);
        idx = 6;
        // "seq netId frac effectCount {effect}" per hit
        for(i = 0; i < n && idx + 3 < count; i += 1)
        {
            seq = StringToInt(WO_Str(idx), 0);
            effectCount = StringToInt(WO_Str(idx + 3), 0);
            effects.Clear();
            for(j = 0; j < effectCount && idx + 4 + j < count; j += 1)
            {
                effects.PushBack(StringToInt(WO_Str(idx + 4 + j), 0));
            }
            if(seq > ack.lastSeq)
            {
                ApplyHit(sender, StringToInt(WO_Str(idx + 1), 0), StringToFloat(WO_Str(idx + 2), 0), effects);
                ack.lastSeq = seq;
            }
            idx += 4 + effectCount;
        }
    }

    private function ApplyHit(sender : string, netId : int, frac : float, effects : array<int>)
    {
        var e : r_CoopHostEnemy;
        var action : W3DamageAction;
        var attacker : CActor;
        var difficultyMult : float;
        var i : int;

        e = FindHostEnemy(netId);
        if(!e || !e.npc || !e.npc.IsAlive() || (frac <= 0 && effects.Size() == 0))
        {
            return;
        }

        attacker = GhostOf(sender);

        // the damage processor scales an NPC attacker's damage by the NPC difficulty multiplier (3.3x was
        // measured); the member's game already applied its own stats, so divide that back out
        difficultyMult = 1;
        if(attacker && !attacker.IgnoresDifficultySettings())
        {
            difficultyMult = CalculateAttributeValue(attacker.GetAttributeValue(theGame.params.DIFFICULTY_DMG_MULTIPLIER));
            if(difficultyMult <= 0)
            {
                difficultyMult = 1;
            }
        }

        action = new W3DamageAction in theGame.damageMgr;
        action.Initialize(attacker, e.npc, theGame, "W3Coop", EHRT_Light, CPS_Undefined, false, false, false, false);
        if(frac > 0)
        {
            action.AddDamage(theGame.params.DAMAGE_NAME_DIRECT, MinF(frac, 1) * e.npc.GetMaxHealth() / difficultyMult);
        }
        // its own resistances decide whether they take hold; processed also without damage, as Aard's are
        for(i = 0; i < effects.Size(); i += 1)
        {
            action.AddEffectInfo((EEffectType)effects[i]);
        }
        if(effects.Size() > 0)
        {
            action.SetProcessBuffsIfNoDamage(true);
        }
        hitEffectsApplied += effects.Size();
        action.SetCannotReturnDamage(true);
        theGame.damageMgr.ProcessAction(action);
        delete action;
        for(i = 0; i < effects.Size(); i += 1)
        {
            if(e.npc.HasBuff((EEffectType)effects[i]))
            {
                hitEffectsHeld += 1;
            }
        }
        hitsApplied += 1;
    }

    private function IsMyPartyMember(user : string) : bool
    {
        var client : r_MultiplayerClient;
        var globals : array<r_RemotePlayer>;
        var i : int;

        client = theGame.r_getMultiplayerClient();
        globals = client.getGlobalPlayers();
        for(i = 0; i < globals.Size(); i += 1)
        {
            if(globals[i] && globals[i].username == user)
            {
                return globals[i].inParty && globals[i].joinedParty == client.getUsername();
            }
        }
        return false;
    }

    // the player behind an actor: this game's Geralt or another player's character here; "" for anyone else
    private function UserOf(actor : CActor) : string
    {
        var players : array<r_RemotePlayer>;
        var i : int;

        if(actor && actor == thePlayer)
        {
            return theGame.r_getMultiplayerClient().getUsername();
        }
        players = theGame.r_getMultiplayerClient().getPlayers();
        for(i = 0; actor && i < players.Size(); i += 1)
        {
            if(players[i] && players[i].ghost == actor)
            {
                return players[i].username;
            }
        }
        return "";
    }

    private function GhostOf(user : string) : CActor
    {
        var players : array<r_RemotePlayer>;
        var i : int;

        players = theGame.r_getMultiplayerClient().getPlayers();
        for(i = 0; i < players.Size(); i += 1)
        {
            if(players[i] && players[i].username == user)
            {
                return players[i].ghost;
            }
        }
        return NULL;
    }

    // Party members' ghosts join the player's attitude group and become gameplay-visible, so this game's
    // monsters attack them as they would the leader (they stay invulnerable). Undone when they leave.
    private function ArmGhosts(client : r_MultiplayerClient)
    {
        var players : array<r_RemotePlayer>;
        var wanted : array<CActor>;
        var ghost : CActor;
        var i : int;

        players = client.getPlayers();
        for(i = 0; i < players.Size(); i += 1)
        {
            if(players[i] && players[i].ghost && IsMyPartyMember(players[i].username))
            {
                wanted.PushBack(players[i].ghost);
            }
        }

        for(i = armedGhosts.Size() - 1; i >= 0; i -= 1)
        {
            if(!wanted.Contains(armedGhosts[i]))
            {
                Disarm(armedGhosts[i]);
                armedGhosts.Erase(i);
            }
        }

        for(i = 0; i < wanted.Size(); i += 1)
        {
            ghost = wanted[i];
            if(!armedGhosts.Contains(ghost))
            {
                ghost.SetTemporaryAttitudeGroup(thePlayer.GetAttitudeGroup(), AGP_Default);
                armedGhosts.PushBack(ghost);
            }
            // Witcher Online hides ghosts from gameplay again in some states (e.g. mounting)
            ghost.SetGameplayVisibility(true);
        }
    }

    // a member: the leader's character too, so that puppets can go for it when their own AI plays the leader's monster's
    // attacks on the leader (PlayAttack)
    private function ArmLeaderGhost()
    {
        var ghost : CActor;

        ghost = GhostOf(leaderName);
        if(!ghost)
        {
            return;
        }
        if(!armedGhosts.Contains(ghost))
        {
            ghost.SetTemporaryAttitudeGroup(thePlayer.GetAttitudeGroup(), AGP_Default);
            armedGhosts.PushBack(ghost);
        }
        ghost.SetGameplayVisibility(true);
    }

    private function Disarm(ghost : CActor)
    {
        if(ghost)
        {
            ghost.SetTemporaryAttitudeGroup('friendly_to_player', AGP_Default);
            ghost.SetGameplayVisibility(false);
        }
    }

    private function DisarmGhosts()
    {
        var i : int;

        for(i = 0; i < armedGhosts.Size(); i += 1)
        {
            Disarm(armedGhosts[i]);
        }
        armedGhosts.Clear();
    }

    private function GhostOwner(ghost : CActor) : string
    {
        var players : array<r_RemotePlayer>;
        var i : int;

        players = theGame.r_getMultiplayerClient().getPlayers();
        for(i = 0; i < players.Size(); i += 1)
        {
            if(players[i] && players[i].ghost == ghost && IsMyPartyMember(players[i].username))
            {
                return players[i].username;
            }
        }
        return "";
    }

    // Called for every damage action before it is processed; true drops it. On the leader, a shared
    // monster's hit on a member's ghost is recorded for that member, and ghosts' own AI deals no damage
    // (members' hits arrive as claims instead).
    public function OnBeforeDamage(act : W3DamageAction) : bool
    {
        var attacker, victim : CActor;
        var e : r_CoopHostEnemy;
        var user : string;

        attacker = (CActor)act.attacker;
        victim = (CActor)act.victim;

        // a member's puppets only hurt it through the leader's hits
        if((CNewNPC)attacker && IsPuppet((CNewNPC)attacker) && act.GetBuffSourceName() != "W3CoopHurt")
        {
            return true;
        }

        if(!wasHost)
        {
            return false;
        }
        // ...and effects applied for a member's hit (burning) tick only in the member's world, which claims them
        if(attacker && attacker.HasTag('MPEntity') && (act.GetBuffSourceName() != "W3Coop" || act.IsDoTDamage()))
        {
            return true;
        }

        if(victim && victim.HasTag('MPEntity') && !act.IsDoTDamage())
        {
            ghostHitsSeen += 1;
            e = FindHostEnemyByNpc((CNewNPC)attacker);
            user = GhostOwner(victim);
            if(e && user != "")
            {
                QueueHurt(user, e, act);
            }
        }
        return false;
    }

    private function QueueHurt(user : string, e : r_CoopHostEnemy, act : W3DamageAction)
    {
        var dts : array<SRawDamage>;
        var effects : array<EEffectType>;
        var h : r_CoopHurt;
        var i : int;

        h = new r_CoopHurt in this;
        act.GetEffectTypes(effects);
        for(i = 0; i < effects.Size(); i += 1)
        {
            h.effects.PushBack((int)effects[i]);
        }
        act.GetDTs(dts);
        for(i = 0; i < dts.Size(); i += 1)
        {
            if(dts[i].dmgVal > 0)
            {
                h.types.PushBack(dts[i].dmgType);
                h.values.PushBack(dts[i].dmgVal);
            }
        }
        if(h.types.Size() == 0)
        {
            return;
        }

        h.user = user;
        h.seq = nextHurtSeq;
        h.netId = e.netId;
        h.hitReaction = (int)act.GetHitReactionType();
        h.attackSeq = e.attackSeq;
        h.hitAnimTime = e.hitAnimTime;
        nextHurtSeq += 1;
        hurts.PushBack(h);
        if(hurts.Size() > 16)
        {
            hurts.Erase(0);
        }
        hurtsCaptured += 1;
        lastHurtSend = -999;
    }

    private function PruneHurts(user : string, lastSeq : int)
    {
        var i : int;

        for(i = hurts.Size() - 1; i >= 0; i -= 1)
        {
            if(hurts[i].user == user && hurts[i].seq <= lastSeq)
            {
                hurts.Erase(i);
            }
        }
    }

    // "hurt epoch count {user seq netId hitReaction attackSeq hitAnimTime types {type value} effects {type}}": every
    // hurt not yet acknowledged
    private function SendHurts(now : float)
    {
        var text : string;
        var h : r_CoopHurt;
        var i, j : int;

        if((hurts.Size() == 0 && lastHurtSentCount == 0) || now - lastHurtSend < COOP_SEND_INTERVAL())
        {
            return;
        }

        text = "coop hurt " + epoch + " " + hurts.Size();
        for(i = 0; i < hurts.Size(); i += 1)
        {
            h = hurts[i];
            text += " " + h.user + " " + h.seq + " " + h.netId + " " + h.hitReaction + " " + h.attackSeq
                + " " + FloatToStringPrec(h.hitAnimTime, 2) + " " + h.types.Size();
            for(j = 0; j < h.types.Size(); j += 1)
            {
                text += " " + NameToString(h.types[j]) + " " + FloatToStringPrec(h.values[j], 2);
            }
            text += " " + h.effects.Size();
            for(j = 0; j < h.effects.Size(); j += 1)
            {
                text += " " + h.effects[j];
            }
        }
        WO_Send(text);
        lastHurtSend = now;
        lastHurtSentCount = hurts.Size();
    }

    // A shared monster started (AET_DurationStart) or finished (AET_DurationEnd, where the hit is processed) an
    // attack's hit window. An attack task that started (OnAttackTask) is already sent: this only adds the animation and
    // hit time. Any other (e.g. a counter-attack from its parry task) is sent here.
    public function OnEnemyAttack(npc : CNewNPC, eventType : EAnimationEventType, animInfo : SAnimationEventAnimInfo)
    {
        var e : r_CoopHostEnemy;
        var p : r_CoopPuppet;
        var hitAnim : name;

        if(!wasHost)
        {
            // a member: the attack animation really plays on the puppet (its own attack events fire), soon after the
            // leader's attack was mirrored (an attack started late in the 1.1 s window reaches its hit window up to a
            // second later; after a move under way, the window opens later); any other is an attack of the puppet's own AI
            p = FindPuppetByNpc(npc);
            if(eventType == AET_DurationStart && p && theGame.GetEngineTimeAsSeconds() - p.attackFrom < 3.5)
            {
                puppetAttackEvents += 1;
                if(npc.GetTarget() != p.attackActor)
                {
                    puppetWrongTargets += 1;
                }
                if(p.puppetAnimText == "")
                {
                    LogSync("MA", p.netId, p.attackSeq, NameToString(GetAnimNameFromEventAnimInfo(animInfo)));
                    p.puppetAnimText = NameToString(GetAnimNameFromEventAnimInfo(animInfo));
                    CompareAttackAnims(p);
                }
            }
            else if(eventType == AET_DurationStart && p)
            {
                puppetOwnAttacks += 1;
            }
            return;
        }
        e = FindHostEnemyByNpc(npc);
        if(!e)
        {
            return;
        }

        if(eventType == AET_DurationStart)
        {
            if(e.pendingTask != "" && AnimOfThisAttack(e, animInfo))
            {
                CommitAttack(e);
            }
            // a new attack (one without a task: a counter from its parry task), unless its task runs, or ended but this is
            // still its animation (a bear's task can end before its hit window)
            hitAnim = GetAnimNameFromEventAnimInfo(animInfo);
            if(!e.taskRunning && (theGame.GetEngineTimeAsSeconds() - e.attackTaskAt > 2.5
                || (IsNameValid(e.attackAnim) && e.attackAnim != hitAnim) || !AnimOfThisAttack(e, animInfo)))
            {
                e.attackSeq += 1;
                e.attackTask = "";
                attacksSeen += 1;
                LogSync("L", e.netId, e.attackSeq, "-");
            }
            if(e.windowSeq != e.attackSeq)
            {
                e.windowSeq = e.attackSeq;
                LogSync("LA", e.netId, e.attackSeq, NameToString(GetAnimNameFromEventAnimInfo(animInfo)));
            }
            PoseLearn(e, hitAnim);
            // the hit window's animation is the attack's (an early name can be another's), unless it is the previous
            // swing's, still blending out (some graphs start the swing before its task, so an unnamed attack takes it)
            if(e.attackAnim != hitAnim && (!IsNameValid(e.attackAnim) || e.attackTask == "" || AnimOfThisAttack(e, animInfo)))
            {
                e.attackAnimAt = GetLocalAnimTimeFromEventAnimInfo(animInfo);
                e.attackNamedAt = theGame.GetEngineTimeAsSeconds();
                e.attackAnim = GetAnimNameFromEventAnimInfo(animInfo);
                HostSend();
                lastHostSend = theGame.GetEngineTimeAsSeconds();
            }
            // the target can be momentarily unset: then still the last player it went for
            if(UserOf(npc.GetTarget()) != "")
            {
                e.attackTarget = UserOf(npc.GetTarget());
            }
            e.hitAnimTime = GetLocalAnimTimeFromEventAnimInfo(animInfo);
            lastHostSend = -999;  // send it now, not on the next 100 ms tick
        }
        else if(eventType == AET_DurationEnd)
        {
            e.hitAnimTime = GetLocalAnimTimeFromEventAnimInfo(animInfo);
        }
    }

    // An attack task (CBTTaskAttack and its many kinds: swings, charges, spells, signs, summons, projectiles) started
    // (`active`) or ended. It counts once it really plays (CommitAttack, ConfirmPuppetTask): a task whose animation
    // event the graph refuses ends at once and starts again the next frame (a bear between its attacks, a human copy).
    // On the leader it is sent then, with which task it is (CoopAttackId), so members' copies make the same attack,
    // also when it has no hit window (a spell that only spawns its area effect). On a member, it tells whether the
    // puppet took the leader's attack.
    public function OnAttackTask(task : CBTTaskAttack, active : bool)
    {
        var e : r_CoopHostEnemy;
        var p : r_CoopPuppet;
        var npc : CNewNPC;

        npc = task.GetNPC();
        if(!wasHost)
        {
            p = FindPuppetByNpc(npc);
            if(!p)
            {
                return;
            }
            if(active)
            {
                p.taskPending = task.CoopAttackId();
                p.taskPendingAt = theGame.GetEngineTimeAsSeconds();
                p.taskPendingFrames = 0;
                return;
            }
            if(p.taskPending != "")
            {
                p.taskPending = "";
                return;
            }
            if(p.attackRunningSince >= 0 && theGame.GetEngineTimeAsSeconds() - p.attackRunningSince < 0.5)
            {
                puppetAttackQuickEnds += 1;
            }
            p.attackRunningSince = -1;
            return;
        }
        e = FindHostEnemyByNpc(npc);
        if(!e)
        {
            return;
        }
        if(!active && e.pendingTask != "")
        {
            e.pendingTask = "";
            attackFalseStarts += 1;
        }
        else if(!active)
        {
            e.taskRunning = false;
            // a hit ended it (an attack can also go on through a hit): members' copies stop it too
            if(theGame.GetEngineTimeAsSeconds() - e.lastHitAt < 0.5 && !e.attackCut)
            {
                e.attackCut = true;
                LogSync("LC", e.netId, e.attackSeq, "-");
                HostSend();
                lastHostSend = theGame.GetEngineTimeAsSeconds();
            }
        }
        else
        {
            e.pendingTask = task.CoopAttackId();
            e.pendingAt = theGame.GetEngineTimeAsSeconds();
            e.pendingWall = WO_ClockMs();
            e.pendingFrames = 0;
            e.earlyLogged = 0;
        }
    }

    // An animation that started with the current (or pending) attack: its own time is at most the time since the
    // attack's task started (0.35 s leeway: some graphs start a swing a little before its task, a katakan's by 0.2 s),
    // and it isn't the one that played before (still blending out).
    private function AnimOfThisAttack(e : r_CoopHostEnemy, animInfo : SAnimationEventAnimInfo) : bool
    {
        var start, now : float;

        now = theGame.GetEngineTimeAsSeconds();
        start = e.attackTaskAt;
        if(e.pendingTask != "")
        {
            start = e.pendingAt;
        }
        if(GetLocalAnimTimeFromEventAnimInfo(animInfo) > now - start + 0.35)
        {
            return false;
        }
        return GetAnimNameFromEventAnimInfo(animInfo) != e.preAnim || now - e.preAnimAt >= 1.5;
    }

    // A shared monster's attack task really started: its first animation event, its hit window, or still running two
    // frames later (CommitDueAttacks). A new attack for members, timed from the task's start.
    private function CommitAttack(e : r_CoopHostEnemy)
    {
        e.attackSeq += 1;
        e.attackTask = e.pendingTask;
        e.attackTaskAt = e.pendingAt;
        e.taskRunning = true;
        e.pendingTask = "";
        LogSync("L", e.netId, e.attackSeq, e.attackTask, e.pendingWall);
        e.attackAnim = '';
        e.poseChecks = 0;
        e.attackCut = false;
        e.hitAnimTime = 0;
        if(UserOf(e.npc.GetTarget()) != "")
        {
            e.attackTarget = UserOf(e.npc.GetTarget());
        }
        attacksSeen += 1;
        lastAttackTask = e.attackTask;
    }

    // attack tasks still running two frames (and 50 ms) after they started, without an animation event yet
    private function CommitDueAttacks(now : float) : bool
    {
        var i : int;
        var committed : bool;

        for(i = 0; i < hostEnemies.Size(); i += 1)
        {
            if(hostEnemies[i].pendingTask != "")
            {
                hostEnemies[i].pendingFrames += 1;
                if(hostEnemies[i].pendingFrames >= 2 && now - hostEnemies[i].pendingAt >= 0.05)
                {
                    CommitAttack(hostEnemies[i]);
                    committed = true;
                }
            }
        }
        return committed;
    }

    // a puppet's own attack task plays (see OnAttackTask): its idle tree waits for it to end (a spell's loop runs for
    // seconds, its effect comes late), and whether it took the leader's attack is counted
    private function ConfirmPuppetTask(p : r_CoopPuppet)
    {
        var id : string;

        id = p.taskPending;
        p.taskPending = "";
        p.attackRunningSince = p.taskPendingAt;
        LogSync("M", p.netId, p.attackSeq, id);
        if(p.attackTask == "" || p.attackTaskTaken)
        {
            return;
        }
        p.attackTaskTaken = true;
        if(id == p.attackTask)
        {
            puppetSameTasks += 1;
            lastPuppetTask = id;
        }
        else if(StrBeforeFirst(p.attackTask, ":") == "CBTTaskAttack" && StrBeforeFirst(id, ":") == "CBTTaskAttack")
        {
            puppetSwingSwaps += 1;  // another plain swing (see PuppetAttackAllowed)
        }
        else
        {
            puppetOtherTasks += 1;
            lastPuppetTask = p.attackTask + "->" + id;
        }
    }

    // An animation event while an attack task runs. On the leader the first commits the attack and names its
    // animation, sent at once so members' copies start it nearly together (the hit window, which names it for sure,
    // opens much later). On a member it shows the puppet's own task plays.
    public function OnAttackAnimEvent(task : CBTTaskAttack, eventName : name, animInfo : SAnimationEventAnimInfo)
    {
        var e : r_CoopHostEnemy;
        var p : r_CoopPuppet;

        if(!wasHost)
        {
            p = FindPuppetByNpc(task.GetNPC());
            if(p && p.taskPending != "")
            {
                ConfirmPuppetTask(p);
            }
            return;
        }
        e = FindHostEnemyByNpc(task.GetNPC());
        if(!e || !AnimOfThisAttack(e, animInfo))
        {
            return;
        }
        if(e.pendingTask != "")
        {
            CommitAttack(e);
        }
        NameAttack(e, eventName, animInfo);
    }

    // the attack's animation, named by one of its early events (within 0.6 s, and an attack animation: a task can start
    // with a run or strafe): sent right now, not on the next frame's tick
    private function NameAttack(e : r_CoopHostEnemy, eventName : name, animInfo : SAnimationEventAnimInfo)
    {
        if(IsNameValid(e.attackAnim) || theGame.GetEngineTimeAsSeconds() - e.attackTaskAt > 0.6
            || StrFindFirst(StrLower(NameToString(GetAnimNameFromEventAnimInfo(animInfo))), "attack") < 0)
        {
            return;
        }
        e.attackAnim = GetAnimNameFromEventAnimInfo(animInfo);
        e.attackAnimAt = GetLocalAnimTimeFromEventAnimInfo(animInfo);
        e.attackNamedAt = theGame.GetEngineTimeAsSeconds();
        LogSync("LE", e.netId, e.attackSeq, NameToString(e.attackAnim) + "/" + NameToString(eventName));
        HostSend();
        lastHostSend = theGame.GetEngineTimeAsSeconds();
    }

    // Enum animation events of the monster itself (OnEnumAnimEvent): many swings have no event for the attack task
    // before their hit window, but turn to the target early ('RotateEvent': at once in a human's swings, 0.2 s into an
    // arachas' that hits at 0.3 s). An animation that started with the attack (not the one playing before it, still
    // blending out) names it. Sound and footstep events, often earlier still, never reach scripts.
    public function OnEarlyAnimEvent(npc : CNewNPC, eventName : name, animInfo : SAnimationEventAnimInfo)
    {
        var e : r_CoopHostEnemy;
        var anim : name;
        var now, animTime : float;

        if(!wasHost || !npc)
        {
            return;
        }
        e = FindHostEnemyByNpc(npc);
        if(!e)
        {
            return;
        }
        now = theGame.GetEngineTimeAsSeconds();
        anim = GetAnimNameFromEventAnimInfo(animInfo);
        animTime = GetLocalAnimTimeFromEventAnimInfo(animInfo);
        if(e.pendingTask == "" && !e.taskRunning && now - e.attackTaskAt > 2.5)
        {
            e.preAnim = anim;
            e.preAnimAt = now;
            return;
        }
        if(e.earlyLogged < 2)
        {
            e.earlyLogged += 1;
            LogSync("LV", e.netId, e.attackSeq, NameToString(anim) + "/" + NameToString(eventName) + "/"
                + FloatToStringPrec(animTime, 2));
        }
        if(!AnimOfThisAttack(e, animInfo))
        {
            return;
        }
        if(e.pendingTask != "")
        {
            CommitAttack(e);
        }
        NameAttack(e, eventName, animInfo);
    }


    // One of its other animated moves (a behavior-tree task that plays an animation: dodge, jump back, taunt,
    // shot, ...); every animation event of it arrives here, a new one is a new name or a restart.
    // A shared monster shot a projectile (arrow, bolt, spit, boulder, ...).
    public function OnEnemyProjectile(proj : W3AdvancedProjectile, angle : float, speed : float, target : Vector, range : float)
    {
        var e : r_CoopHostEnemy;

        if(!wasHost)
        {
            return;
        }
        e = FindHostEnemyByNpc(ShooterOf(proj));
        if(!e)
        {
            return;
        }
        e.projSeq += 1;
        e.projAt = theGame.GetEngineTimeAsSeconds();
        e.projTemplate = proj.GetReadableName();
        e.projFrom = proj.GetWorldPosition();
        e.projTo = target;
        e.projAngle = angle;
        e.projSpeed = speed;
        e.projRange = range;
        projectilesSeen += 1;
        lastHostSend = -999;
    }

    public function OnEnemyMove(task : CBTTaskPlayAnimationEventDecorator, animInfo : SAnimationEventAnimInfo)
    {
        var e : r_CoopHostEnemy;
        var npc : CNewNPC;
        var anim : name;
        var t : float;

        npc = task.GetNPC();
        anim = GetAnimNameFromEventAnimInfo(animInfo);
        if(!IsNameValid(anim))
        {
            return;
        }
        t = GetLocalAnimTimeFromEventAnimInfo(animInfo);
        if(!wasHost)
        {
            OnPuppetMoveAnim(npc, anim, CoopMoveKind(task, anim), t);
            return;
        }
        e = FindHostEnemyByNpc(npc);
        if(!e)
        {
            return;
        }
        if(anim == e.moveAnim && t >= e.moveAnimTime)
        {
            e.moveAnimTime = t;
            return;
        }
        e.moveSeq += 1;
        e.moveAnim = anim;
        e.moveAnimTime = t;
        e.moveStartTime = t;
        e.moveNamedAt = theGame.GetEngineTimeAsSeconds();
        e.moveKind = CoopMoveKind(task, anim);
        e.moveParam = CoopMoveParam(task);
        lastMoveTask = task.ToString();
        // a dodge or taunt is made facing its target
        if(UserOf(npc.GetTarget()) != "")
        {
            e.attackTarget = UserOf(npc.GetTarget());
        }
        movesSeen += 1;
        lastMoveAnim = anim;
        lastMoveKind = e.moveKind;
        LogSync("LMV", e.netId, e.moveSeq, e.moveKind + "/" + NameToString(anim));
        // right now, not on the next frame's tick
        HostSend();
        lastHostSend = theGame.GetEngineTimeAsSeconds();
    }

    // member: a move animation started on a puppet (a new one or a restart): the mirrored move it was to make, or
    // one of its own
    private function OnPuppetMoveAnim(npc : CNewNPC, anim : name, kind : string, t : float)
    {
        var p : r_CoopPuppet;

        moveAnimEvents += 1;
        p = FindPuppetByNpc(npc);
        if(!p)
        {
            return;
        }
        if(anim == p.moveAnimSeen && t >= p.moveAnimSeenTime)
        {
            p.moveAnimSeenTime = t;
            return;
        }
        p.moveAnimSeen = anim;
        p.moveAnimSeenTime = t;
        lastPuppetMoveAnim = anim;
        if(kind == "")
        {
            return;
        }
        if(p.moveKind == kind && !p.moveStarted && theGame.GetEngineTimeAsSeconds() < p.moveUntil)
        {
            MoveStarted(p);
        }
        else if(!(p.moveKind == kind && p.moveStarted))
        {
            puppetOwnMoves += 1;
            AddTrace("own " + NameToString(anim));
            return;
        }
        if(p.moveAnimAt < 0)
        {
            p.moveAnimAt = theGame.GetEngineTimeAsSeconds() - p.movePlayedAt;
            p.moveAnimName = anim;
            LogSync("MM", p.netId, p.moveSeq, NameToString(anim));
        }
        if(!p.moveAnimated)
        {
            p.moveAnimated = true;
            puppetMovesAnimated += 1;
            if(kind == "dodge")
            {
                puppetDodgesAnimated += 1;
            }
        }
    }

    // diagnostics: one entry per mirrored move once it is over (warnings sent, accepted by its CBTTaskDodge, when that
    // task activated and with what, its first animation), the newest last
    private function TraceMove(p : r_CoopPuppet, outcome : string)
    {
        var line : string;

        if(p.moveKind == "")
        {
            return;
        }
        line = p.moveKind + " " + outcome + " sig=" + p.moveSignals + " acc=" + p.moveAccepted + " retgt=" + p.moveRetargets;
        if(p.moveKind == "parry")
        {
            line += " guarded=" + p.npc.IsGuarded() + " attacking=" + p.npc.IsAttacking() + " sinceAttack="
                + FloatToStringPrec(p.movePlayedAt - p.attackPlayedAt, 1);
        }
        if(p.moveActivatedAt >= 0)
        {
            line += " act=+" + FloatToStringPrec(p.moveActivatedAt, 2) + "/" + p.moveActStatus;
        }
        if(p.moveAnimAt >= 0)
        {
            line += " anim=" + NameToString(p.moveAnimName) + "@+" + FloatToStringPrec(p.moveAnimAt, 2);
        }
        AddTrace(line);
    }

    private function AddTrace(line : string)
    {
        moveTrace += " [" + line + "]";
        if(StrLen(moveTrace) > 1500)
        {
            moveTrace = StrRight(moveTrace, 1200);
        }
    }

    // the puppet's CBTTaskDodge accepted a warning (activated false) or activated, returning `status`
    public function NotePuppetDodge(npc : CNewNPC, activated : bool, status : EBTNodeStatus)
    {
        var p : r_CoopPuppet;

        p = FindPuppetByNpc(npc);
        if(!p || p.moveKind == "")
        {
            return;
        }
        if(!activated)
        {
            p.moveAccepted += 1;
            return;
        }
        // the latest activation; the move lasts until its animation can be over
        p.moveActivatedAt = theGame.GetEngineTimeAsSeconds() - p.movePlayedAt;
        p.moveActStatus = "" + (int)status;
        p.moveUntil = MaxF(p.moveUntil, theGame.GetEngineTimeAsSeconds() + 1.5);
        p.reactUntil = MaxF(p.reactUntil, p.moveUntil);
        p.slotAnimAt = theGame.GetEngineTimeAsSeconds();
    }

    // the idle tree stays off until the move is over (a taunt takes longer)
    private function MoveStarted(p : r_CoopPuppet)
    {
        p.moveStarted = true;
        // its locomotion would take the leader's monster's dodge for a run and break the move off
        p.slotAnimAt = theGame.GetEngineTimeAsSeconds();
        if(p.moveKind == "taunt")
        {
            p.moveUntil = MaxF(p.moveUntil, theGame.GetEngineTimeAsSeconds() + 3.0);
        }
        else
        {
            p.moveUntil = MaxF(p.moveUntil, theGame.GetEngineTimeAsSeconds() + 1.2);
        }
        p.reactUntil = MaxF(p.reactUntil, p.moveUntil);
        puppetMovesStarted += 1;
        if(p.moveKind == "taunt")
        {
            puppetTauntsStarted += 1;
        }
        else if(p.moveKind == "parry")
        {
            puppetParriesStarted += 1;
        }
    }

    // A shared monster took damage here: members replay the hit reaction on its puppet (the hitter's own game
    // already played it).
    public function OnEnemyDamaged(npc : CNewNPC, action : W3DamageAction)
    {
        var e : r_CoopHostEnemy;
        var attacker : CActor;

        if(!wasHost || !action.DealsAnyDamage() || action.IsDoTDamage())
        {
            return;
        }
        e = FindHostEnemyByNpc(npc);
        if(!e)
        {
            return;
        }

        attacker = (CActor)action.attacker;
        e.hitBy = "";
        if(attacker == thePlayer)
        {
            e.hitBy = theGame.r_getMultiplayerClient().getUsername();
        }
        else if(attacker && attacker.HasTag('MPEntity'))
        {
            e.hitBy = GhostOwner(attacker);
        }
        e.hitSeq += 1;
        e.lastHitAt = theGame.GetEngineTimeAsSeconds();
        e.hitReaction = (int)action.GetHitReactionType();
        LogSync("LH", e.netId, e.attackSeq, IntToString(e.hitReaction));
        lastHostSend = -999;
    }

    public function PendingHurtCount() : int
    {
        return hurts.Size();
    }

    // ---------------------------------------------------------------- member

    // inbound COOP message from the client's pump; fields are read with WO_Str
    public function OnMessage()
    {
        var client : r_MultiplayerClient;
        var sender : string;
        var count : int;

        client = theGame.r_getMultiplayerClient();
        sender = WO_Str(-1);
        count = StringToInt(WO_Str(-3), 0);
        if(!client || sender == client.getUsername() || count < 1)
        {
            return;
        }

        EnsureIds();
        if(WO_Str(0) == "en")
        {
            OnSnapshot(sender, count);
        }
        else if(WO_Str(0) == "hit")
        {
            OnHits(sender, count);
        }
        else if(WO_Str(0) == "hurt")
        {
            OnHurts(sender, count);
        }
        else if(WO_Str(0) == "jr")
        {
            OnJournal(sender, count);
        }
        else if(WO_Str(0) == "fx")
        {
            OnFacts(sender, count);
        }
        else if(WO_Str(0) == "ps")
        {
            client.getCoopParty().OnLeaderState(sender, count);
        }
        else if(WO_Str(0) == "ms")
        {
            client.getCoopParty().OnMemberState(sender, count);
        }
    }

    private function OnSnapshot(sender : string, count : int)
    {
        var templates : array<string>;
        var seen : array<int>;
        var pos : Vector;
        var moveAnim : name;
        var hitBy, projTpl, attackTarget, attackTask, attackAnimText, moveText, moveKind : string;
        var attackAnimAt, moveAt : float;
        var animTime, moveAnimText : string;
        var attackCut : bool;
        var snapshotEpoch, n, i, idx, netId, tplIndex, attackSeq, hitSeq, hitReaction, moveSeq, moveParam, projSeq, projIndex : int;
        var hp, yaw, projAngle, projSpeed, projRange : float;
        var projFrom, projTo : Vector;
        var alive : bool;
        var app : string;

        if(GetRole() != 2 || sender != leaderName || count < 4)
        {
            return;
        }

        if(StringToInt(WO_Str(3), 0) != WO_CurrentAreaCode() || !LeaderNear())
        {
            ReleaseAll();
            return;
        }

        snapshotEpoch = StringToInt(WO_Str(1), 0);
        if(snapshotEpoch != leaderEpoch)
        {
            // the leader restarted: its enemy ids and hit acknowledgements start over
            ReleaseAll();
            pendingHits.Clear();
            hurtAck = 0;
            leaderEpoch = snapshotEpoch;
        }
        lastSnapshotAt = theGame.GetEngineTimeAsSeconds();

        idx = 4;
        n = StringToInt(WO_Str(idx), 0);
        idx += 1;
        for(i = 0; i < n && idx + 2 < count; i += 1)
        {
            if(WO_Str(idx) == theGame.r_getMultiplayerClient().getUsername() && StringToInt(WO_Str(idx + 1), 0) == session)
            {
                PruneHits(StringToInt(WO_Str(idx + 2), 0));
            }
            idx += 3;
        }

        n = StringToInt(WO_Str(idx), 0);
        idx += 1;
        for(i = 0; i < n && idx < count; i += 1)
        {
            templates.PushBack(CoopDecode(WO_Str(idx)));
            idx += 1;
        }

        n = StringToInt(WO_Str(idx), 0);
        idx += 1;
        for(i = 0; i < n && idx + 16 < count; i += 1)
        {
            netId = StringToInt(WO_Str(idx), 0);
            tplIndex = StringToInt(WO_Str(idx + 1), 0);
            app = CoopDecode(WO_Str(idx + 2));
            pos.X = StringToFloat(WO_Str(idx + 3), 0);
            pos.Y = StringToFloat(WO_Str(idx + 4), 0);
            pos.Z = StringToFloat(WO_Str(idx + 5), 0);
            pos.W = 1;
            yaw = StringToFloat(WO_Str(idx + 6), 0);
            hp = StringToFloat(WO_Str(idx + 7), 0);
            alive = WO_Str(idx + 8) == "1";
            attackSeq = StringToInt(WO_Str(idx + 9), 0);
            // "task|anim", or just the animation from an older leader (see AttackText)
            attackTask = "";
            attackAnimText = CoopDecode(WO_Str(idx + 10));
            if(StrFindFirst(attackAnimText, "|") >= 0)
            {
                attackTask = StrBeforeFirst(attackAnimText, "|");
                attackAnimText = StrAfterFirst(attackAnimText, "|");
            }
            attackAnimAt = 0;
            attackCut = false;
            if(StrFindFirst(attackAnimText, "|") >= 0 && StrAfterFirst(attackAnimText, "|") != "")
            {
                leaderNamesAnims = true;
            }
            if(StrFindFirst(attackAnimText, "|") >= 0)
            {
                animTime = StrAfterFirst(attackAnimText, "|");
                attackAnimText = StrBeforeFirst(attackAnimText, "|");
                if(StrFindFirst(animTime, "|") >= 0)
                {
                    attackCut = StrAfterFirst(animTime, "|") == "1";
                    animTime = StrBeforeFirst(animTime, "|");
                }
                attackAnimAt = StringToFloat(animTime, 0);
            }
            if(attackAnimText == "None")
            {
                attackAnimText = "";
            }
            hitSeq = StringToInt(WO_Str(idx + 11), 0);
            hitBy = CoopDecode(WO_Str(idx + 12));
            hitReaction = StringToInt(WO_Str(idx + 13), 0);
            moveSeq = StringToInt(WO_Str(idx + 14), 0);
            moveAnim = '';
            moveKind = "";
            moveParam = -1;
            moveAnimText = "";
            moveAt = 0;
            moveText = WO_Str(idx + 15);
            if(StrFindFirst(moveText, ":") >= 0)
            {
                // kind:param:anim (0.2.1 and older) or kind:param:anim:time
                moveKind = StrBeforeFirst(moveText, ":");
                moveText = StrAfterFirst(moveText, ":");
                moveParam = StringToInt(StrBeforeFirst(moveText, ":"), -1);
                moveAnimText = StrAfterFirst(moveText, ":");
                if(StrFindFirst(moveAnimText, ":") >= 0)
                {
                    moveAt = StringToFloat(StrAfterFirst(moveAnimText, ":"), 0);
                    moveAnimText = StrBeforeFirst(moveAnimText, ":");
                }
                if(moveAnimText == "None")
                {
                    moveAnimText = "";
                }
            }
            else if(moveText != "-")
            {
                moveAnim = WO_NameAt(idx + 15);
            }
            attackTarget = CoopDecode(WO_Str(idx + 16));
            idx += 17;
            projSeq = StringToInt(WO_Str(idx), 0);
            idx += 1;
            projTpl = "";
            if(projSeq != 0)
            {
                if(idx + 9 >= count)
                {
                    break;
                }
                projIndex = StringToInt(WO_Str(idx), 0);
                if(projIndex >= 0 && projIndex < templates.Size())
                {
                    projTpl = templates[projIndex];
                }
                projFrom = Vector(StringToFloat(WO_Str(idx + 1), 0), StringToFloat(WO_Str(idx + 2), 0), StringToFloat(WO_Str(idx + 3), 0));
                projTo = Vector(StringToFloat(WO_Str(idx + 4), 0), StringToFloat(WO_Str(idx + 5), 0), StringToFloat(WO_Str(idx + 6), 0));
                projAngle = StringToFloat(WO_Str(idx + 7), 0);
                projSpeed = StringToFloat(WO_Str(idx + 8), 0);
                projRange = StringToFloat(WO_Str(idx + 9), 0);
                idx += 10;
            }

            if(tplIndex >= 0 && tplIndex < templates.Size())
            {
                ApplyEnemy(netId, templates[tplIndex], app, pos, yaw, hp, alive, attackSeq, attackTask, attackAnimText, attackAnimAt, attackCut, hitSeq, hitBy, hitReaction,
                    moveSeq, moveAnim, moveKind, moveParam, moveAnimText, moveAt, attackTarget);
                if(projSeq != 0 && projTpl != "")
                {
                    ApplyProjectile(netId, projSeq, projTpl, projFrom, projTo, projAngle, projSpeed, projRange);
                }
                seen.PushBack(netId);
            }
        }

        for(i = puppets.Size() - 1; i >= 0; i -= 1)
        {
            if(!seen.Contains(puppets[i].netId))
            {
                ReleasePuppet(puppets[i]);
                puppets.Erase(i);
            }
        }

        SuppressUnmatched();
    }

    private function OnHurts(sender : string, count : int)
    {
        var me, user : string;
        var listed : bool;
        var h : r_CoopHurt;
        var p : r_CoopPuppet;
        var now : float;
        var n, i, j, idx, seq, typeCount, effectCount, effectsAt : int;

        if(GetRole() != 2 || sender != leaderName || leaderEpoch == 0 || count < 3 || StringToInt(WO_Str(1), 0) != leaderEpoch)
        {
            return;
        }

        me = theGame.r_getMultiplayerClient().getUsername();
        now = theGame.GetEngineTimeAsSeconds();
        n = StringToInt(WO_Str(2), 0);
        idx = 3;
        for(i = 0; i < n && idx + 6 < count; i += 1)
        {
            user = WO_Str(idx);
            seq = StringToInt(WO_Str(idx + 1), 0);
            typeCount = StringToInt(WO_Str(idx + 6), 0);
            effectsAt = idx + 7 + typeCount * 2;
            if(effectsAt >= count)
            {
                break;
            }
            effectCount = StringToInt(WO_Str(effectsAt), 0);
            if(effectsAt + 1 + effectCount > count)
            {
                break;
            }
            if(user == me)
            {
                listed = true;
                if(seq > hurtAck)
                {
                    h = new r_CoopHurt in this;
                    h.seq = seq;
                    h.netId = StringToInt(WO_Str(idx + 2), 0);
                    h.hitReaction = StringToInt(WO_Str(idx + 3), 0);
                    h.attackSeq = StringToInt(WO_Str(idx + 4), 0);
                    h.hitAnimTime = StringToFloat(WO_Str(idx + 5), 0);
                    for(j = 0; j < typeCount; j += 1)
                    {
                        h.types.PushBack(WO_NameAt(idx + 7 + j * 2));
                        h.values.PushBack(StringToFloat(WO_Str(idx + 8 + j * 2), 0));
                    }
                    for(j = 0; j < effectCount; j += 1)
                    {
                        h.effects.PushBack(StringToInt(WO_Str(effectsAt + 1 + j), 0));
                    }

                    // land it when this world's copy of the swing reaches the hit (immediately if this world
                    // missed that attack); a dodge before then avoids it
                    h.receivedAt = now;
                    h.due = now;
                    p = FindPuppet(h.netId);
                    if(p && p.alive && p.attackSeq == h.attackSeq && p.attackPlayedAt > 0)
                    {
                        h.due = MaxF(now, p.attackPlayedAt + MinF(h.hitAnimTime, 1.5));
                    }
                    delayedHurts.PushBack(h);
                    hurtAck = seq;
                }
            }
            idx = effectsAt + 1 + effectCount;
        }
        leaderListsMyHurts = listed;
    }

    private function ApplyDueHurts(now : float)
    {
        var i : int;

        for(i = 0; i < delayedHurts.Size(); i += 1)
        {
            if(delayedHurts[i].due <= now)
            {
                lastHurtDelay = now - delayedHurts[i].receivedAt;
                ApplyHurt(delayedHurts[i]);
                delayedHurts.Erase(i);
                i -= 1;
            }
        }
    }

    // The leader's monster hit this player's ghost: apply its raw damage here, with the monster's local copy
    // as attacker, so this game's armor, Quen and difficulty count. A hit landing mid-dodge misses.
    private function ApplyHurt(h : r_CoopHurt)
    {
        var action : W3DamageAction;
        var p : r_CoopPuppet;
        var attacker : CActor;
        var before : float;
        var i : int;

        if(thePlayer.IsCurrentlyDodging())
        {
            hurtsDodged += 1;
            return;
        }

        p = FindPuppet(h.netId);
        if(p && p.alive)
        {
            attacker = p.npc;
        }

        action = new W3DamageAction in theGame.damageMgr;
        action.Initialize(attacker, thePlayer, theGame, "W3CoopHurt", (EHitReactionType)h.hitReaction, CPS_AttackPower, true, false, false, false);
        for(i = 0; i < h.types.Size(); i += 1)
        {
            action.AddDamage(h.types[i], h.values[i]);
        }
        // the monster's buffs; this game's immunities and resistances decide whether they take hold
        for(i = 0; i < h.effects.Size(); i += 1)
        {
            action.AddEffectInfo((EEffectType)h.effects[i]);
        }
        hurtEffectsApplied += h.effects.Size();
        before = thePlayer.GetStat(BCS_Vitality);
        theGame.damageMgr.ProcessAction(action);
        delete action;
        hurtDamageTaken += MaxF(0, before - thePlayer.GetStat(BCS_Vitality));
        hurtsApplied += 1;
    }

    private function ApplyEnemy(netId : int, tpl : string, app : string, pos : Vector, yaw : float, hp : float, alive : bool,
        attackSeq : int, attackTask : string, attackAnimText : string, attackAnimAt : float, attackCut : bool, hitSeq : int, hitBy : string, hitReaction : int, moveSeq : int, moveAnim : name,
        moveKind : string, moveParam : int, moveAnimText : string, moveAt : float, attackTarget : string)
    {
        var p : r_CoopPuppet;
        var npc : CNewNPC;
        var spawned, played : bool;
        var now : float;

        now = theGame.GetEngineTimeAsSeconds();
        p = FindPuppet(netId);
        if(!p)
        {
            if(!alive || VecDistance(thePlayer.GetWorldPosition(), pos) > 70)
            {
                return;
            }

            npc = FindTwin(tpl, pos);
            if(npc)
            {
                twinsBound += 1;
            }
            else
            {
                npc = SpawnPuppet(tpl, app, pos, yaw);
                spawned = true;
            }
            if(!npc)
            {
                return;
            }
            p = MakePuppet(npc, netId, spawned);
            p.attackSeq = attackSeq;  // don't replay an attack, move or hit from before this puppet existed
            p.hitSeq = hitSeq;
            p.moveSeq = moveSeq;
        }

        // hits by others (this player's own hits already reacted here)
        if(hitSeq != p.hitSeq)
        {
            p.hitSeq = hitSeq;
            if(p.alive && hitBy != "" && hitBy != theGame.r_getMultiplayerClient().getUsername())
            {
                MirrorHit(p, hitBy, hitReaction);
            }
        }

        if(attackSeq != p.attackSeq)
        {
            p.attackSeq = attackSeq;
            // (one already cut short isn't played)
            if(p.alive && (attackTask != "" || attackAnimText != "") && !attackCut)
            {
                p.attackAnimAt = attackAnimAt;
                p.attackAnimGotAt = theGame.GetEngineTimeAsSeconds();
                PlayAttack(p, attackTask, attackAnimText, attackTarget);
            }
        }
        else if(attackAnimText != "" && attackAnimText != p.attackAnimText && !p.attackCut)
        {
            // the animation follows its task's start; a later one is the attack's next part (a counter: its dodge, then
            // its lunge)
            p.attackAnimAt = attackAnimAt;
            p.attackAnimGotAt = theGame.GetEngineTimeAsSeconds();
            if(p.attackAnimText == "")
            {
                p.attackAnimText = attackAnimText;
                CompareAttackAnims(p);
                SlotAttack(p, false);
            }
            else
            {
                p.attackAnimText = attackAnimText;
                SlotAttack(p, true);
            }
        }
        if(attackSeq == p.attackSeq && attackCut && !p.attackCut)
        {
            p.attackCut = true;
            if(p.slotAttackAt >= p.attackPlayedAt)
            {
                StopSlotAttack(p);
            }
        }

        // the newest of its attacks and moves plays, as on the leader
        if(moveSeq != p.moveSeq)
        {
            p.moveSeq = moveSeq;
            if(p.alive)
            {
                played = false;
                if(moveAnimText != "")
                {
                    played = SlotMove(p, moveAnimText, moveAt, moveKind);
                }
                if(!played && moveKind != "")
                {
                    PlayMove(p, moveKind, moveParam, attackTarget);
                }
                else if(!played && IsNameValid(moveAnim))
                {
                    PlayMoveAnim(p, moveAnim);
                }
            }
        }

        if(p.lastTargetAt > 0 && now - p.lastTargetAt > 0.02)
        {
            p.targetSpeed = 0.5 * p.targetSpeed + 0.5 * VecDistance2D(pos, p.target) / (now - p.lastTargetAt);
        }
        p.lastTargetAt = now;
        p.target = pos;
        p.yaw = yaw;
        // after a local hit the leader's health arrives a moment later; don't flash back up meanwhile
        if(now >= p.predictUntil || hp < p.hp)
        {
            p.hp = hp;
        }

        if(!alive && p.alive)
        {
            KillPuppet(p);
        }
    }

    private function FindTwin(tpl : string, pos : Vector) : CNewNPC
    {
        var entities : array<CGameplayEntity>;
        var npc, best : CNewNPC;
        var dist, bestDist : float;
        var i : int;

        bestDist = 10.0;
        FindGameplayEntitiesInSphere(entities, pos, 10.0, 32, '', FLAG_OnlyAliveActors, thePlayer);
        for(i = 0; i < entities.Size(); i += 1)
        {
            npc = (CNewNPC)entities[i];
            if(!npc || npc.HasTag('MPEntity') || IsPuppet(npc) || npc.GetReadableName() != tpl)
            {
                continue;
            }
            dist = VecDistance(npc.GetWorldPosition(), pos);
            if(dist < bestDist)
            {
                bestDist = dist;
                best = npc;
            }
        }

        if(best)
        {
            Unsuppress(best);
        }
        return best;
    }

    private function SpawnPuppet(tpl : string, app : string, pos : Vector, yaw : float) : CNewNPC
    {
        var template : CEntityTemplate;
        var ent : CEntity;
        var npc : CNewNPC;
        var rot : EulerAngles;

        template = (CEntityTemplate)LoadResource(tpl, true);
        if(!template)
        {
            spawnFailures += 1;
            lastError = "no template '" + tpl + "'";
            return NULL;
        }

        rot.Yaw = yaw;
        ent = theGame.CreateEntity(template, pos, rot, true, false, false, PM_DontPersist);
        npc = (CNewNPC)ent;
        if(!npc)
        {
            if(ent)
            {
                ent.Destroy();
            }
            spawnFailures += 1;
            lastError = "'" + tpl + "' did not spawn an NPC";
            return NULL;
        }

        if(app != "")
        {
            npc.ApplyAppearance(app);
        }
        puppetsSpawned += 1;
        return npc;
    }

    private function MakePuppet(npc : CNewNPC, netId : int, spawned : bool) : r_CoopPuppet
    {
        var p : r_CoopPuppet;

        p = new r_CoopPuppet in this;
        p.npc = npc;
        p.netId = netId;
        p.spawned = spawned;
        p.alive = true;
        p.hp = npc.GetHealthPercents();
        p.target = npc.GetWorldPosition();
        p.yaw = npc.GetHeading();
        p.aiId = ForceIdle(npc);
        p.attackRunningSince = -1;
        // a finisher would kill it here, outside the leader's say ('DisableFinishers' blocks the killing-blow
        // finisher, 'DisableFinisher' the one on a living target)
        BlockFinisher(p, 'DisableFinishers');
        BlockFinisher(p, 'DisableFinisher');
        puppets.PushBack(p);
        return p;
    }

    // Replays another player's hit on a puppet through the damage manager with a negligible damage, so the
    // vanilla reaction path runs (the leader's health is restored right after).
    // The forced idle tree swallows hit reactions; lift it briefly so the monster's own AI plays one. Its
    // attacks in that time do no damage here (OnBeforeDamage drops a puppet's own damage).
    private function OpenReactionWindow(p : r_CoopPuppet)
    {
        if(p.aiId != 0)
        {
            p.npc.CancelAIBehavior(p.aiId);
            p.aiId = 0;
        }
        p.reactUntil = theGame.GetEngineTimeAsSeconds() + 0.8;
    }

    private function MirrorHit(p : r_CoopPuppet, hitBy : string, hitReaction : int)
    {
        var action : W3DamageAction;

        OpenReactionWindow(p);
        p.hitMirroredAt = theGame.GetEngineTimeAsSeconds();
        LogSync("MH", p.netId, p.attackSeq, IntToString(hitReaction));
        // a hit that dealt damage got through a move (a dodged or parried one deals none): a move on its slot (a taunt,
        // a strafe) stops for its hit reaction
        if(p.slotMoveAt > p.slotAttackAt && p.hitMirroredAt - p.slotMoveAt < 3.0)
        {
            StopSlotAttack(p);
        }

        action = new W3DamageAction in theGame.damageMgr;
        action.Initialize(GhostOf(hitBy), p.npc, theGame, "W3CoopHitFx", (EHitReactionType)hitReaction, CPS_Undefined, true, false, false, false);
        action.AddDamage(theGame.params.DAMAGE_NAME_DIRECT, COOP_FX_DAMAGE());
        action.SetCannotReturnDamage(true);
        applyingHostState = true;
        theGame.damageMgr.ProcessAction(action);
        applyingHostState = false;
        delete action;
        hitReactionsMirrored += 1;
    }

    private function BlockFinisher(p : r_CoopPuppet, ability : name)
    {
        if(!p.npc.HasAbility(ability))
        {
            p.npc.AddAbility(ability, false);
            p.addedNoFinishers.PushBack(ability);
        }
    }

    // The puppet's own AI attacks the player the leader's monster attacks (this game's Geralt, or that player's character
    // here): its idle tree is off for the attack and it notices that player. A plain swing's exact animation plays on its
    // slot at once (SlotAttack); a spell or special attack is its own AI's same task. A puppet's own hits do no damage
    // (OnBeforeDamage).
    private function PlayAttack(p : r_CoopPuppet, task : string, anim : string, target : string)
    {
        var now : float;

        now = theGame.GetEngineTimeAsSeconds();
        p.attackPlayedAt = now;
        p.attackFrom = now;
        LogSync("R", p.netId, p.attackSeq, task);
        p.attackTask = task;
        p.attackAnimText = anim;
        p.attackTaskTaken = false;
        p.attackCut = false;
        p.puppetAnimText = "";
        p.animsCompared = false;
        // a spell or special attack is its own AI's: a swing still on its slot would hide it (and its animation's
        // events, which spawn the spell)
        if(task != "" && !CoopSlotSwing(task))
        {
            StopSlotAttack(p);
        }
        // a move waiting or under way comes first, as on the leader (a parry, then the counter-attack): the attack
        // follows once the move is over (EndMove), and the target switches only then
        if(p.moveKind != "" && now < p.moveUntil)
        {
            p.attackFrom = p.moveUntil;
        }
        if(FreeToAct(p, target, p.attackFrom - now + 2.5, p.attackFrom == now))
        {
            p.slotAnimAt = p.attackFrom;  // it stands for the attack (a lunge read as a run would break it off)
            attacksPlayed += 1;
            SlotAttack(p, false);
        }
    }

    // The leader's monster's exact attack animation, played straight on the puppet's graph slot as soon as it
    // arrives: its own AI would take a while to pick an attack, and a swing's variant at random. Only for plain swings
    // and attacks without a task (a spell's effect comes from its task), and not behind a move. `nextPart`: a later
    // animation of the same attack, after one already on the slot.
    private function SlotAttack(p : r_CoopPuppet, nextPart : bool)
    {
        var settings : SAnimatedComponentSlotAnimationSettings;
        var comp : CAnimatedComponent;
        var now : float;
        var playing, started : bool;

        now = theGame.GetEngineTimeAsSeconds();
        if(nextPart && (p.slotAttackAt < p.attackPlayedAt || now - p.slotAttackAt > 4.0))
        {
            return;
        }
        // (an older leader names it only at its hit window: by then the puppet may have started its own swing)
        if(!nextPart && (!slotAttacks || p.attackAnimText == "" || p.slotAttackAt >= p.attackPlayedAt || now - p.attackPlayedAt > 3.0
            || p.attackFrom > now || p.attackTaskTaken || (p.attackTask != "" && !CoopSlotSwing(p.attackTask))))
        {
            return;
        }
        comp = p.npc.GetRootAnimatedComponent();
        // a swing more than 1.2 s along (named only at a giant's late hit window) is mostly over
        if(!comp || slotless.Contains(p.npc.GetReadableName()) || p.attackAnimAt + now - p.attackAnimGotAt > 1.2)
        {
            return;
        }
        settings.blendIn = 0.1;
        settings.blendOut = 0.2;
        lastSlotState = p.npc.GetBehaviorGraphInstanceName();
        // already on the slot (a counter-attack came as a move first, then as an attack at its hit window): it goes on
        playing = p.slotAnim == p.attackAnimText && now - p.slotAnimStartAt < 1.5;
        if(!playing)
        {
            started = comp.PlaySlotAnimationAsync(WO_ToName(p.attackAnimText), attackSlot, settings);
        }
        if(playing || started)
        {
            if(started)
            {
                p.slotAnim = p.attackAnimText;
                p.slotAnimStartAt = now;
                CatchUp(p, comp, p.attackAnimAt + 0.03 + now - p.attackAnimGotAt);
            }
            p.slotAttackAt = now;
            // (one already going may have passed its hit window before it came as an attack: not checked)
            p.slotChecked = !started;
            slotAttacksPlayed += 1;
            LogSync("MS", p.netId, p.attackSeq, p.attackAnimText);
        }
        else
        {
            p.slotRefusedAt = now;
            slotAttacksRefused += 1;
            LogSync("MX", p.netId, p.attackSeq, p.attackAnimText);
        }
    }

    // Lifts the puppet's idle tree for `seconds` with the player `target` (a username) as its combat target, so its own
    // AI acts on that player. False if that player's character isn't here (or the monster isn't after a player yet).
    // Switching its target (`retarget`) restarts its combat tree, which delays or breaks off a move.
    private function FreeToAct(p : r_CoopPuppet, target : string, seconds : float, retarget : bool) : bool
    {
        var actor : CActor;

        if(target == theGame.r_getMultiplayerClient().getUsername())
        {
            actor = thePlayer;
        }
        else
        {
            actor = GhostOf(target);
        }
        if(!actor)
        {
            return false;
        }
        if(p.aiId != 0)
        {
            p.npc.CancelAIBehavior(p.aiId);
            p.aiId = 0;
        }
        if(p.animAiId != 0)
        {
            p.npc.CancelAIBehavior(p.animAiId);
            p.animAiId = 0;
        }
        p.reactUntil = MaxF(p.reactUntil, theGame.GetEngineTimeAsSeconds() + seconds);
        p.attackActor = actor;
        p.npc.SetAttitude(actor, AIA_Hostile);
        p.npc.NoticeActor(actor);
        if(retarget)
        {
            AimPuppet(p, actor);
        }
        return true;
    }

    // Its AI keeps the first hostile it noticed (often this player): its combat target selection is told to take
    // `actor` ('ForceTarget', as quests do). Forgetting the others instead restarted its combat tree each time, which
    // broke attacks and spells off.
    private function AimPuppet(p : r_CoopPuppet, actor : CActor)
    {
        p.aimedAt = theGame.GetEngineTimeAsSeconds();
        if(p.npc.GetTarget() == actor)
        {
            return;
        }
        p.npc.SignalGameplayEventParamObject('ForceTarget', actor);
        if(p.moveKind != "")
        {
            p.moveRetargets += 1;
        }
    }

    // The leader's monster fired a projectile (in the last 1.5 s): a harmless copy flies from this world's puppet
    // (the hit itself arrives as a hurt, and a puppet's own damage is dropped anyway).
    private function ApplyProjectile(netId : int, seq : int, tpl : string, from : Vector, to : Vector, angle : float, speed : float,
        range : float)
    {
        var p : r_CoopPuppet;
        var template : CEntityTemplate;
        var proj : W3AdvancedProjectile;

        p = FindPuppet(netId);
        if(!p || seq == p.projSeq)
        {
            return;
        }
        p.projSeq = seq;
        if(!p.alive)
        {
            return;
        }
        template = (CEntityTemplate)LoadResource(tpl, true);
        if(template)
        {
            proj = (W3AdvancedProjectile)theGame.CreateEntity(template, from, VecToRotation(to - from));
        }
        if(!proj)
        {
            projectileFailures += 1;
            lastError = "projectile '" + tpl + "' could not be fired";
            return;
        }
        proj.Init(p.npc);
        proj.projDMG = 0;
        proj.projSilverDMG = 0;
        proj.projEfect = EET_Undefined;
        firingProjectileCopy = true;
        proj.ShootProjectileAtPosition(angle, speed, to, range);
        firingProjectileCopy = false;
        projectilesFired += 1;
    }

    // A dodge, taunt or jump-back of the leader's monster: as for attacks, the puppet's own AI makes it, facing the same
    // player. The dodge warning repeats from 0.45 s on (once the combat tree runs) until a dodge animation starts
    // (OnPuppetMoveAnim). Where the move is a scripted task (CBTTaskDodge and the like), that task is the only one of
    // them the puppet may start, and a dodge skips its chance and checks (the wraps at the end of this file).
    private function PlayMove(p : r_CoopPuppet, kind : string, param : int, target : string)
    {
        var now, window : float;

        now = theGame.GetEngineTimeAsSeconds();
        StopSlotAttack(p);  // a swing still on its slot would hide the move
        if(p.moveKind != "" && !p.moveStarted)
        {
            puppetMovesMissed += 1;
            TraceMove(p, "replaced");
        }
        else if(p.moveKind != "")
        {
            TraceMove(p, "started,replaced");
        }
        // a combat tree takes its time to come to a taunt
        window = 1.5;
        if(kind == "taunt")
        {
            window = 2.5;
        }
        if(!FreeToAct(p, target, window + 0.2, false))
        {
            p.moveKind = "";
            return;
        }
        if(kind == "dodge")
        {
            dodgesMirrored += 1;
        }
        else if(kind == "taunt")
        {
            tauntsMirrored += 1;
        }
        else if(kind == "parry")
        {
            parriesMirrored += 1;
        }
        p.moveKind = kind;
        p.moveParam = param;
        p.movePlayedAt = now;
        p.moveUntil = now + window;
        p.moveStarted = false;
        p.moveAnimated = false;
        p.moveSignals = 0;
        p.moveAccepted = 0;
        p.moveActivatedAt = -1;
        p.moveAnimAt = -1;
        p.moveRetargets = 0;
        p.slotAnimAt = now;
        if((kind == "dodge" || kind == "jumpback") && param >= 0)
        {
            p.npc.SetBehaviorVariable('DodgeDirection', param);
        }
        movesPlayed += 1;
    }

    // whether the puppet `npc` is to make (`toStart`: still to start, its animation not seen yet and not under way) a
    // mirrored move of this kind now; its tasks ask (CoopIsPuppet and the task wraps below)
    public function PuppetMovePending(npc : CNewNPC, kind : string, toStart : bool) : bool
    {
        var p : r_CoopPuppet;

        p = FindPuppetByNpc(npc);
        if(!p || (toStart && (p.moveAnimated || npc.IsCurrentlyDodging())))
        {
            return false;
        }
        return p.moveKind == kind && theGame.GetEngineTimeAsSeconds() < p.moveUntil;
    }

    public function PuppetMoveParam(npc : CNewNPC) : int
    {
        var p : r_CoopPuppet;

        p = FindPuppetByNpc(npc);
        if(!p)
        {
            return -1;
        }
        return p.moveParam;
    }

    // member: another player's character swinging here warns no one (the puppets dodge or parry when the leader's
    // monster does); this player's own swings still do, so a puppet can dodge this player's blade here
    public function MutesSwingsOf(attacker : CActor) : bool
    {
        return GetRole() == 2 && puppets.Size() > 0 && attacker != thePlayer && UserOf(attacker) != "";
    }

    // a move is over: an attack of the leader's monster that came meanwhile follows now, at its player
    // how long a mirrored attack's window is open: 2.5 s until the puppet starts an attack (a golem's tree asks for
    // one only now and then), then 1.1 s (long enough to start an attack, short enough not to start a second)
    private function AttackWindow(p : r_CoopPuppet) : float
    {
        if(p.attackTaskTaken)
        {
            return 1.1;
        }
        return 2.5;
    }

    private function EndMove(p : r_CoopPuppet, now : float)
    {
        if(p.attackPlayedAt <= p.movePlayedAt || now - p.attackPlayedAt > 3.0)
        {
            return;
        }
        p.attackFrom = now;
        p.slotAnimAt = now;
        p.reactUntil = MaxF(p.reactUntil, now + 2.5);
        if(p.attackActor)
        {
            p.npc.NoticeActor(p.attackActor);
            AimPuppet(p, p.attackActor);
        }
    }

    // A puppet's attack tasks may start only during a mirrored attack, and not while a mirrored move waits or is under
    // way: the leader's monster's own attack task (the same spell or sign; for a plain swing any plain swing), or after
    // 0.6 s a plain swing (the same can be out of reach for it) - never a spell or special attack the leader's monster
    // didn't make. It never summons: what the leader's monster summons is shared.
    public function PuppetAttackAllowed(task : CBTTaskAttack) : bool
    {
        var p : r_CoopPuppet;
        var now : float;
        var offered : string;
        var plain : bool;

        p = FindPuppetByNpc(task.GetNPC());
        if(!p)
        {
            return true;
        }
        if((CBTTaskSummonCreatures)task || (CBTTaskSummonCreaturesWithLevel)task)
        {
            return false;
        }
        now = theGame.GetEngineTimeAsSeconds();
        // diagnostics while a mirrored attack is due: asked at all, held by a move, another task early
        if(now >= p.attackPlayedAt && now - p.attackFrom < 1.1)
        {
            gateAsked += 1;
        }
        if(p.moveKind != "" && now < p.moveUntil)
        {
            if(now >= p.attackPlayedAt && now - p.attackFrom < 1.1)
            {
                gateHeldByMove += 1;
            }
            return false;
        }
        if(now < p.attackFrom || now - p.attackFrom >= AttackWindow(p))
        {
            return false;
        }
        if(p.slotAttackAt >= p.attackPlayedAt || p.attackCut)
        {
            return false;
        }
        // the leader's plain swing (or attack without a task) plays on the slot once named (at its first animation event,
        // for some only at its hit window): its own swing never stands in, unless the slot refused it or the leader is
        // an older one that doesn't name them (then after 0.7 s)
        if(slotAttacks && (leaderNamesAnims || now - p.attackPlayedAt < 0.7) && p.slotRefusedAt < p.attackPlayedAt
            && !slotless.Contains(p.npc.GetReadableName()) && (p.attackTask == "" || CoopSlotSwing(p.attackTask)))
        {
            return false;
        }
        offered = task.CoopAttackId();
        plain = StrBeforeFirst(offered, ":") == "CBTTaskAttack";
        if(p.attackTask == "" || offered == p.attackTask || (plain && (now - p.attackFrom >= 0.6
            || StrBeforeFirst(p.attackTask, ":") == "CBTTaskAttack")))
        {
            return true;
        }
        gateOtherTask += 1;
        lastGateDenied = p.attackTask + "/" + task.CoopAttackId();
        return false;
    }

    // The leader's monster's attack was cut short (a hit ended it), the puppet died, or it is to make a move or spell
    // of its own AI: its slot animation stops (playing no animation on the slot ends the one there), so its own hit
    // reaction, death, move or spell shows.
    private function StopSlotAttack(p : r_CoopPuppet)
    {
        EndCatchUp(p);
        if(MaxF(p.slotAttackAt, p.slotMoveAt) <= 0 || theGame.GetEngineTimeAsSeconds() - MaxF(p.slotAttackAt, p.slotMoveAt) > 4.0
            || !p.npc.GetRootAnimatedComponent())
        {
            return;
        }
        p.npc.GetRootAnimatedComponent().PlaySlotAnimationAsync('', attackSlot);
        LogSync("MK", p.netId, p.attackSeq, "-");
    }

    // A slot attack named late (at its hit window: some animations have no event before it) starts that far behind
    // the leader's: it plays faster (at most twice as fast) until it has caught up, so the hit lands closer to the
    // leader's. `behind`: seconds (the transfer counted as 30 ms).
    private function CatchUp(p : r_CoopPuppet, comp : CAnimatedComponent, behind : float)
    {
        var speed : float;

        EndCatchUp(p);
        if(behind < 0.08)
        {
            return;
        }
        speed = MinF(2.0, 1 + behind / 0.3);
        p.catchUpId = comp.SetAnimationSpeedMultiplier(speed);
        p.catchUpUntil = theGame.GetEngineTimeAsSeconds() + behind / (speed - 1);
        slotCatchUps += 1;
        LogSync("MC", p.netId, p.attackSeq, FloatToStringPrec(behind, 2));
    }

    private function EndCatchUp(p : r_CoopPuppet)
    {
        if(p.catchUpUntil > 0 && p.npc.GetRootAnimatedComponent())
        {
            p.npc.GetRootAnimatedComponent().ResetAnimationSpeedMultiplier(p.catchUpId);
        }
        p.catchUpUntil = 0;
    }

    // A slot attack shows its hit window soon (its animation's own events). None in 2.5 s (unless a hit cut it short or
    // another attack followed): its graph may lack the slot, and after two misses in a row that monster's puppets swing
    // with their own AI again (gated as before).
    private function SlotAttackCheck(p : r_CoopPuppet, now : float)
    {
        var key : string;

        if(p.slotChecked || p.slotAttackAt < p.attackPlayedAt || p.attackCut || now - p.slotAttackAt < 2.5)
        {
            return;
        }
        p.slotChecked = true;
        key = p.npc.GetReadableName();
        if(p.puppetAnimText == p.attackAnimText)
        {
            slotMissedOnce.Remove(key);
            return;
        }
        if(p.hitMirroredAt >= p.slotAttackAt)
        {
            return;
        }
        slotAttacksMissed += 1;
        LogSync("MM", p.netId, p.attackSeq, p.attackAnimText);
        if(slotMissedOnce.Contains(key))
        {
            slotless.PushBack(key);
        }
        else
        {
            slotMissedOnce.PushBack(key);
        }
    }

    // Some swings have no event before their hit window (a bear's bite hits at 0.6 s). An attack not yet named is
    // looked at 0.12, 0.2 and 0.3 s after its task started: its bones (model space) against each swing its monster type
    // made before (PoseScore).
    private function PoseChecks(now : float)
    {
        var e : r_CoopHostEnemy;
        var toModel : Matrix;
        var i, b : int;
        var due : float;

        for(i = 0; i < hostEnemies.Size(); i += 1)
        {
            e = hostEnemies[i];
            due = 0.12;
            if(e.poseChecks == 1)
            {
                due = 0.2;
            }
            else if(e.poseChecks == 2)
            {
                due = 0.3;
            }
            if(e.poseChecks >= 3 || IsNameValid(e.attackAnim) || e.attackTask == "" || now - e.attackTaskAt < due
                || now - e.attackTaskAt > 0.6)
            {
                continue;
            }
            e.poseChecks += 1;
            e.poseSnapTime = now - e.attackTaskAt;
            e.poseSnap.Clear();
            toModel = MatrixGetInverted(e.npc.GetLocalToWorld());
            for(b = 1; b < 31; b += 2)
            {
                e.poseSnap.PushBack(VecTransform(toModel, MatrixGetTranslation(e.npc.GetBoneWorldMatrixByIndex(b))));
            }
            PoseScore(e);
        }
    }

    // the swings each monster type made (their hit windows name them)
    private function PoseLearn(e : r_CoopHostEnemy, anim : name)
    {
        var template : string;
        var i : int;

        template = e.npc.GetReadableName();
        for(i = 0; i < poseTemplates.Size(); i += 1)
        {
            if(poseTemplates[i] == template && poseAnims[i] == anim)
            {
                return;
            }
        }
        poseTemplates.PushBack(template);
        poseAnims.PushBack(anim);
    }

    // Each swing this monster type made before against the snapshot (bones about their centre; animation times from 0
    // to 0.4 s past the attack's age: a swing can start well before its task, during refused starts). A clear match
    // names the attack: error under 0.5 (summed over 15 bones, metres) with the next best 2.5 times that, or the next
    // best 4.5 times the best (over 200 test snapshots, no rule-passing wrong one; a wrong one would be put right at
    // the hit window). "LQ checkTime/best/bestError/secondError/candidates".
    private function PoseScore(e : r_CoopHostEnemy)
    {
        var template : string;
        var anims : array<name>;
        var i, k : int;
        var err, best, second, time, bestTime : float;
        var bestAnim : name;

        template = e.npc.GetReadableName();
        for(i = 0; i < poseTemplates.Size(); i += 1)
        {
            if(poseTemplates[i] == template)
            {
                anims.PushBack(poseAnims[i]);
            }
        }
        if(anims.Size() < 2)
        {
            return;
        }
        best = 999999;
        second = 999999;
        for(i = 0; i < anims.Size(); i += 1)
        {
            for(k = 0; 0.1 * k <= e.poseSnapTime + 0.4; k += 1)
            {
                time = 0.1 * k;
                err = PoseError(e, anims[i], time);
                if(err < best)
                {
                    if(anims[i] != bestAnim)
                    {
                        second = best;
                    }
                    best = err;
                    bestAnim = anims[i];
                    bestTime = time;
                }
                else if(err < second && anims[i] != bestAnim)
                {
                    second = err;
                }
            }
        }
        LogSync("LQ", e.netId, e.attackSeq, FloatToStringPrec(e.poseSnapTime, 2) + "/" + NameToString(bestAnim) + "/"
            + FloatToStringPrec(best, 2) + "/" + FloatToStringPrec(second, 2) + "/" + anims.Size());
        if(!((best < 0.5 && second >= 2.5 * best) || second >= 4.5 * best) || IsNameValid(e.attackAnim))
        {
            return;
        }
        e.attackAnim = bestAnim;
        e.attackAnimAt = bestTime;
        e.attackNamedAt = theGame.GetEngineTimeAsSeconds();
        poseNamed += 1;
        LogSync("LE", e.netId, e.attackSeq, NameToString(bestAnim) + "/pose");
        HostSend();
        lastHostSend = theGame.GetEngineTimeAsSeconds();
    }

    // how far the snapshot is from `anim` at `time` (bones about their centre, summed, in metres)
    private function PoseError(e : r_CoopHostEnemy, anim : name, time : float) : float
    {
        var comp : CAnimatedComponent;
        var at, withDelta : Matrix;
        var pose : array<Vector>;
        var centreA, centreB : Vector;
        var i, b : int;
        var err : float;

        comp = e.npc.GetRootAnimatedComponent();
        if(!comp || e.poseSnap.Size() == 0)
        {
            return 999999;
        }
        for(b = 1; b < 31; b += 2)
        {
            comp.GetBoneMatrixMovementModelSpaceInAnimation(b, anim, time, 0, at, withDelta);
            pose.PushBack(MatrixGetTranslation(at));
        }
        for(i = 0; i < pose.Size(); i += 1)
        {
            centreA += pose[i];
            centreB += e.poseSnap[i];
        }
        centreA = centreA / (float)pose.Size();
        centreB = centreB / (float)pose.Size();
        for(i = 0; i < pose.Size(); i += 1)
        {
            err += VecDistance(pose[i] - centreA, e.poseSnap[i] - centreB);
        }
        return err;
    }

    // tests: one attack-sync event; at most 400 kept until the test bot drains them
    private function LogSync(kind : string, netId : int, seq : int, what : string, optional wall : int)
    {
        if(syncLog.Size() >= 400)
        {
            syncLog.Erase(0);
        }
        if(what == "")
        {
            what = "-";
        }
        if(wall == 0)
        {
            wall = WO_ClockMs();
        }
        syncLog.PushBack(kind + " " + netId + " " + seq + " " + what + " " + FloatToStringPrec(theGame.GetEngineTimeAsSeconds(), 3)
            + " wall=" + wall);
    }

    // a spell of `npc` spawned its area entity: counted for a shared monster on the leader, a puppet on a member
    // (and on a member, whether the puppet aimed it at the player the leader's monster attacks)
    public function OnSpellSpawn(npc : CNewNPC)
    {
        var p : r_CoopPuppet;

        if(wasHost && FindHostEnemyByNpc(npc))
        {
            spellSpawns += 1;
            return;
        }
        p = FindPuppetByNpc(npc);
        if(!wasHost && p)
        {
            spellSpawns += 1;
            if(p.attackActor && npc.GetTarget() != p.attackActor)
            {
                spellWrongTargets += 1;
            }
        }
    }

    // diagnostics: once both the leader's monster's and the puppet's animation of a mirrored attack are known
    private function CompareAttackAnims(p : r_CoopPuppet)
    {
        if(p.animsCompared || p.attackAnimText == "" || p.puppetAnimText == "")
        {
            return;
        }
        p.animsCompared = true;
        attackAnimsCompared += 1;
        lastAnimPair = p.attackAnimText + "/" + p.puppetAnimText;
        if(p.attackAnimText == p.puppetAnimText)
        {
            puppetSameAnims += 1;
        }
    }

    // the NPC that fired `proj`: its caster, or the monster whose task is spawning it without one (dropped from above)
    private function ShooterOf(proj : W3AdvancedProjectile) : CNewNPC
    {
        if((CNewNPC)proj.caster)
        {
            return (CNewNPC)proj.caster;
        }
        return projectileSpawner;
    }

    // a puppet's plain animation task (a native dodge, a slam: CBTTaskPlayAnimationEventDecorator itself) only while
    // a mirrored move waits or plays (its AI is free while its monster fights)
    public function PuppetPlainMoveAllowed(npc : CNewNPC) : bool
    {
        var p : r_CoopPuppet;

        p = FindPuppetByNpc(npc);
        if(!p)
        {
            return true;
        }
        return p.moveKind != "" && theGame.GetEngineTimeAsSeconds() < p.moveUntil;
    }

    // member: a puppet's own projectile (its AI fired it) doesn't fly; the leader's monster's comes as a copy
    // (ApplyProjectile)
    public function MutesShot(proj : W3AdvancedProjectile) : bool
    {
        var npc : CNewNPC;

        npc = ShooterOf(proj);
        if(wasHost || firingProjectileCopy || !npc)
        {
            return false;
        }
        return IsPuppet(npc);
    }

    // from an older leader: just the animation
    private function PlayMoveAnim(p : r_CoopPuppet, anim : name)
    {
        if(!SlotMove(p, NameToString(anim), 0, ""))
        {
            movePlayFailures += 1;
            lastError = "move animation '" + NameToString(anim) + "' did not play";
        }
    }

    // The leader's monster's move (a dodge, taunt, jump-back, parry, or another animated move of its tree) with its exact
    // animation on the puppet's slot as soon as it arrives, caught up if it comes late (see SlotAttack); its own AI
    // would make a dodge half a second later, or not at all. Nothing is left for its AI to make (no mirrored move
    // pending), so an attack that follows plays at once. False if the slot refused it (then its AI makes the move).
    private function SlotMove(p : r_CoopPuppet, anim : string, at : float, kind : string) : bool
    {
        var settings : SAnimatedComponentSlotAnimationSettings;
        var comp : CAnimatedComponent;
        var now : float;

        comp = p.npc.GetRootAnimatedComponent();
        if(!slotMoves || !comp || slotless.Contains(p.npc.GetReadableName()))
        {
            return false;
        }
        settings.blendIn = 0.1;
        settings.blendOut = 0.2;
        if(!comp.PlaySlotAnimationAsync(WO_ToName(anim), attackSlot, settings))
        {
            slotMovesRefused += 1;
            LogSync("MVX", p.netId, p.moveSeq, anim);
            return false;
        }
        now = theGame.GetEngineTimeAsSeconds();
        if(p.moveKind != "")
        {
            TraceMove(p, "replaced by a slot move");
            p.moveKind = "";
        }
        p.slotAnimAt = now;
        p.slotMoveAt = now;
        p.slotAnim = anim;
        p.slotAnimStartAt = now;
        CatchUp(p, comp, at + 0.03);
        slotMovesPlayed += 1;
        movesPlayed += 1;
        if(kind == "dodge")
        {
            dodgesMirrored += 1;
            slotDodgesParries += 1;
        }
        else if(kind == "taunt")
        {
            tauntsMirrored += 1;
        }
        else if(kind == "parry")
        {
            parriesMirrored += 1;
            slotDodgesParries += 1;
        }
        else if(kind == "")
        {
            movesAnimOnly += 1;
        }
        LogSync("MV", p.netId, p.moveSeq, anim);
        return true;
    }

    // within sharing range of the leader, in the same area
    private function LeaderNear() : bool
    {
        var globals : array<r_RemotePlayer>;
        var i : int;

        globals = theGame.r_getMultiplayerClient().getGlobalPlayers();
        for(i = 0; i < globals.Size(); i += 1)
        {
            if(globals[i] && globals[i].username == leaderName)
            {
                return globals[i].area == WO_CurrentAreaCode()
                    && VecDistance(globals[i].pos, thePlayer.GetWorldPosition()) <= COOP_SHARE_RANGE();
            }
        }
        return false;
    }

    private function ForceIdle(npc : CNewNPC) : int
    {
        var tree : CAIDoNothingAction;

        tree = new CAIDoNothingAction in npc;
        tree.OnCreated();
        return npc.ForceAIBehavior(tree, BTAP_AboveCombat);
    }

    private function UpdatePuppets(now : float)
    {
        var p : r_CoopPuppet;
        var current : float;
        var i : int;

        for(i = puppets.Size() - 1; i >= 0; i -= 1)
        {
            p = puppets[i];
            if(!p.npc)
            {
                puppets.Erase(i);
                continue;
            }
            if(!p.alive)
            {
                continue;
            }

            MovePuppet(p);
            DrivePuppetLocomotion(p);
            if(!p.stride)
            {
                p.stride = new r_CoopStride in this;
            }
            p.stride.Update(p.npc, p.targetSpeed > 1.0, now);
            puppetMaxSwing = MaxF(puppetMaxSwing, p.stride.maxSwing);
            strideBone = p.stride.boneLabel + "/" + p.stride.pelvis;

            if(p.npc.IsInHitAnim() && !p.wasInHitAnim)
            {
                hitAnimsSeen += 1;
            }
            p.wasInHitAnim = p.npc.IsInHitAnim();
            SlotAttackCheck(p, now);
            if(p.catchUpUntil > 0 && now >= p.catchUpUntil)
            {
                EndCatchUp(p);
            }
            if(p.taskPending != "")
            {
                p.taskPendingFrames += 1;
                if(p.taskPendingFrames >= 2 && now - p.taskPendingAt >= 0.05)
                {
                    ConfirmPuppetTask(p);
                }
            }
            if(p.npc.IsCurrentlyDodging() && !p.wasDodging)
            {
                puppetDodgesSeen += 1;
            }
            p.wasDodging = p.npc.IsCurrentlyDodging();

            if(p.moveKind != "" && now >= p.moveUntil)
            {
                if(!p.moveStarted)
                {
                    puppetMovesMissed += 1;
                    TraceMove(p, "missed");
                }
                else
                {
                    TraceMove(p, "started");
                }
                p.moveKind = "";
                EndMove(p, now);
            }
            else if(p.moveKind == "dodge" && !p.moveAnimated && now - p.movePlayedAt >= 0.45)
            {
                // its CBTTaskDodge took the warning (a native dodge shows by its animation instead); a warning while
                // dodging would restart the dodge. Right after the idle tree goes, the task can activate without the
                // animation playing: then, 0.9 s on without it, it is warned again.
                if(p.npc.IsCurrentlyDodging())
                {
                    if(!p.moveStarted)
                    {
                        MoveStarted(p);
                    }
                }
                else if(p.moveActivatedAt < 0 || now - p.movePlayedAt - p.moveActivatedAt > 0.9)
                {
                    p.npc.SignalGameplayEventParamInt('Time2Dodge', (int)EDT_Attack_Light);
                    p.moveSignals += 1;
                }
            }
            else if(p.moveKind == "parry" && !p.moveAnimated && now - p.movePlayedAt >= 0.2)
            {
                // as the game does: the attack warning raises its guard (its parry task), then the blow is parried
                // (as by Npc.OnParry); again 0.5 s on if no parry animation started
                if(!p.npc.CanParryAttack())
                {
                    // by itself its guard came up only after about a second
                    p.npc.RaiseGuard();
                    p.npc.SignalGameplayEventParamInt('ParryStart', 0);
                    p.moveSignals += 1;
                }
                else if(p.moveActivatedAt < 0 || now - p.movePlayedAt - p.moveActivatedAt > 0.5)
                {
                    p.moveActivatedAt = now - p.movePlayedAt;
                    p.npc.SetBehaviorVariable('parryAttackType', (int)PAT_Light);
                    p.npc.SignalGameplayEventParamInt('ParryPerform', 0);
                    p.moveAccepted += 1;
                }
            }

            // an attack of its own AI that started in a window runs to its end (up to 6 s), standing (see MoveStarted)
            if(p.attackRunningSince >= 0 && now - p.attackRunningSince < 6.0)
            {
                p.reactUntil = MaxF(p.reactUntil, now + 0.1);
                p.slotAnimAt = now;
            }
            // while its monster fights (a mirrored attack in the last 6 s) its AI stays free: big monsters (golems,
            // giants) spend a short window turning and stepping into range, and a window's end restarted that every
            // time, so their puppets hardly ever attacked. The gates keep it to the leader's monster's attacks and moves.
            if(puppetAiFree && now - p.attackPlayedAt < 6.0)
            {
                p.reactUntil = MaxF(p.reactUntil, now + 0.1);
            }
            if(p.aiId == 0 && now >= p.reactUntil)
            {
                p.aiId = ForceIdle(p.npc);
            }
            // in a mirrored attack's window, before its attack starts: still at someone else, it is told again (not
            // during a move or an attack: a switch then would break it off)
            else if(p.aiId == 0 && p.moveKind == "" && p.attackRunningSince < 0 && p.attackActor
                && p.npc.GetTarget() != p.attackActor && now - p.aimedAt > 0.5)
            {
                AimPuppet(p, p.attackActor);
            }

            current = p.npc.GetHealthPercents();
            if(current >= 0 && p.hp > 0 && AbsF(current - p.hp) > 0.002)
            {
                applyingHostState = true;
                p.npc.SetHealthPerc(p.hp);
                applyingHostState = false;
            }
        }
    }

    // The slide keeps it on the leader's positions; the gameplay move speed and direction make its behavior graph
    // play the matching walk or run (as Witcher Online does for horses).
    private function DrivePuppetLocomotion(p : r_CoopPuppet)
    {
        var agent : CMovingAgentComponent;
        var speed, now : float;

        agent = p.npc.GetMovingAgentComponent();
        now = theGame.GetEngineTimeAsSeconds();
        // standing: slow target, a mirrored attack or move playing, or no snapshot lately (stalled link)
        if(!puppetLocomotion || p.targetSpeed < 0.4 || now - p.slotAnimAt < 1.2 || now - p.lastTargetAt > 0.5)
        {
            agent.SetGameplayRelativeMoveSpeed(0);
            return;
        }
        speed = 1;
        if(p.targetSpeed > 4.5)
        {
            speed = 3;
        }
        else if(p.targetSpeed > 2.0)
        {
            speed = 2;
        }
        agent.SetGameplayMoveDirection(VecHeading(p.target - p.npc.GetWorldPosition()));
        agent.SetGameplayRelativeMoveSpeed(speed);
    }

    private function MovePuppet(p : r_CoopPuppet)
    {
        var adjustor : CMovementAdjustor;
        var ticket : SMovementAdjustmentRequestTicket;
        var rot : EulerAngles;
        var dist : float;

        dist = VecDistance(p.npc.GetWorldPosition(), p.target);
        if(dist > 12)
        {
            rot = p.npc.GetWorldRotation();
            rot.Yaw = p.yaw;
            p.npc.TeleportWithRotation(p.target, rot);
            return;
        }
        if(dist < 0.1 && AbsF(AngleDistance(p.yaw, p.npc.GetHeading())) < 3)
        {
            return;
        }

        adjustor = p.npc.GetMovingAgentComponent().GetMovementAdjustor();
        adjustor.Cancel(adjustor.GetRequest('w3coop_puppet'));
        ticket = adjustor.CreateNewRequest('w3coop_puppet');
        adjustor.AdjustmentDuration(ticket, 0.15);
        adjustor.AdjustLocationVertically(ticket, true);
        adjustor.ScaleAnimationLocationVertically(ticket, true);
        adjustor.RotateTo(ticket, p.yaw);
        adjustor.SlideTo(ticket, p.target);
    }

    private function KillPuppet(p : r_CoopPuppet)
    {
        p.alive = false;
        puppetsKilled += 1;
        StopSlotAttack(p);
        if(p.animAiId != 0)
        {
            p.npc.CancelAIBehavior(p.animAiId);
            p.animAiId = 0;
        }
        if(p.aiId != 0)
        {
            p.npc.CancelAIBehavior(p.aiId);
            p.aiId = 0;
        }
        applyingHostState = true;
        p.npc.Kill('W3Coop', true);
        applyingHostState = false;
    }

    // a puppet the leader no longer reports: spawned ones go away, local twins get their own AI back
    private function ReleasePuppet(p : r_CoopPuppet)
    {
        var i : int;

        if(!p.npc || !p.alive)
        {
            return;
        }
        StopSlotAttack(p);
        if(p.animAiId != 0)
        {
            p.npc.CancelAIBehavior(p.animAiId);
            p.animAiId = 0;
        }
        if(p.aiId != 0)
        {
            p.npc.CancelAIBehavior(p.aiId);
            p.aiId = 0;
        }
        if(p.spawned)
        {
            p.npc.Destroy();
        }
        else
        {
            // a local twin picks its own targets again
            p.npc.SignalGameplayEvent('UnforceTarget');
            for(i = 0; i < p.addedNoFinishers.Size(); i += 1)
            {
                p.npc.RemoveAbility(p.addedNoFinishers[i]);
            }
        }
    }

    public function ReleaseAll()
    {
        var i : int;

        for(i = 0; i < puppets.Size(); i += 1)
        {
            ReleasePuppet(puppets[i]);
        }
        puppets.Clear();
        delayedHurts.Clear();

        for(i = suppressed.Size() - 1; i >= 0; i -= 1)
        {
            Unsuppress(suppressed[i].npc);
        }
        suppressed.Clear();
    }

    // local hostiles near this member that the leader's world doesn't have: hidden and idle while in the party
    private function SuppressUnmatched()
    {
        var actors : array<CActor>;
        var npc : CNewNPC;
        var s : r_CoopSuppressed;
        var i : int;

        for(i = suppressed.Size() - 1; i >= 0; i -= 1)
        {
            if(!suppressed[i].npc)
            {
                suppressed.Erase(i);
            }
        }

        actors = thePlayer.GetNPCsAndPlayersInRange(30, 48, '', FLAG_Attitude_Hostile + FLAG_OnlyAliveActors + FLAG_ExcludePlayer);
        for(i = 0; i < actors.Size(); i += 1)
        {
            npc = (CNewNPC)actors[i];
            if(!npc || npc.HasTag('MPEntity') || npc.IsHorse() || IsPuppet(npc) || IsSuppressed(npc))
            {
                continue;
            }

            s = new r_CoopSuppressed in this;
            s.npc = npc;
            s.aiId = ForceIdle(npc);
            npc.SetVisibility(false);
            npc.SetGameplayVisibility(false);
            npc.EnableCharacterCollisions(false);
            suppressed.PushBack(s);
        }
    }

    private function IsSuppressed(npc : CNewNPC) : bool
    {
        var i : int;

        for(i = 0; i < suppressed.Size(); i += 1)
        {
            if(suppressed[i].npc == npc)
            {
                return true;
            }
        }
        return false;
    }

    private function Unsuppress(npc : CNewNPC)
    {
        var i : int;

        for(i = suppressed.Size() - 1; i >= 0; i -= 1)
        {
            if(suppressed[i].npc == npc)
            {
                if(npc)
                {
                    npc.CancelAIBehavior(suppressed[i].aiId);
                    npc.SetVisibility(true);
                    npc.SetGameplayVisibility(true);
                    npc.EnableCharacterCollisions(true);
                }
                suppressed.Erase(i);
            }
        }
    }

    private function FindPuppet(netId : int) : r_CoopPuppet
    {
        var i : int;

        for(i = 0; i < puppets.Size(); i += 1)
        {
            if(puppets[i].netId == netId)
            {
                return puppets[i];
            }
        }
        return NULL;
    }

    private function FindPuppetByNpc(npc : CNewNPC) : r_CoopPuppet
    {
        var i : int;

        for(i = 0; i < puppets.Size(); i += 1)
        {
            if(puppets[i].npc == npc)
            {
                return puppets[i];
            }
        }
        return NULL;
    }

    public function IsPuppet(npc : CNewNPC) : bool
    {
        if(FindPuppetByNpc(npc))
        {
            return true;
        }
        return false;
    }

    // damage the local player dealt to a puppet (after this game's stats, resistances and crits) goes to the
    // leader as a fraction of max health; the caller then zeroes it here
    public function OnPuppetDamaged(npc : CNewNPC, action : W3DamageAction)
    {
        var p : r_CoopPuppet;
        var hit : r_CoopHit;
        var dmg, maxHp : float;

        p = FindPuppetByNpc(npc);
        if(!p || !p.alive)
        {
            return;
        }
        OpenReactionWindow(p);
        if(action.attacker != thePlayer)
        {
            return;
        }

        if(npc.UsesVitality())
        {
            dmg = action.processedDmg.vitalityDamage;
        }
        else
        {
            dmg = action.processedDmg.essenceDamage;
        }
        maxHp = npc.GetMaxHealth();
        if(dmg <= 0 || maxHp <= 0)
        {
            return;
        }

        hit = NewHit(p);
        hit.frac = MinF(1, dmg / maxHp);
        lastHitFrac = hit.frac;
        if(action.IsActionMelee())
        {
            meleeHitsSent += 1;
        }
        if(action.IsActionWitcherSign())
        {
            signHitsSent += 1;
        }
        // its effects are added after the damage; OnAfterDamage puts them on this hit
        lastPuppetAction = action;
        lastPuppetHit = hit;

        p.hp = MaxF(0.001, p.hp - hit.frac);
        p.predictUntil = theGame.GetEngineTimeAsSeconds() + 0.6;
    }

    // After this player's hit on a puppet was fully processed: the effects it applied (Igni's burning, Aard's
    // knockdown, ...) go to the leader with the hit, or alone if it did no damage. Damage over time stays here:
    // this world's effect ticks with this player's skills and its ticks are claimed, and the leader's copy of the
    // effect does no damage (a ghost's own damage is dropped there).
    public function OnAfterDamage(action : W3DamageAction)
    {
        var p : r_CoopPuppet;
        var hit : r_CoopHit;
        var effects : array<EEffectType>;
        var i : int;

        if(action.attacker != thePlayer || action.IsDoTDamage())
        {
            return;
        }
        p = FindPuppetByNpc((CNewNPC)action.victim);
        if(!p || !p.alive)
        {
            return;
        }
        action.GetEffectTypes(effects);
        if(effects.Size() == 0)
        {
            return;
        }
        if(action == lastPuppetAction && pendingHits.Contains(lastPuppetHit))
        {
            hit = lastPuppetHit;
        }
        else
        {
            hit = NewHit(p);
            if(action.IsActionWitcherSign())
            {
                signHitsSent += 1;
            }
        }
        for(i = 0; i < effects.Size(); i += 1)
        {
            hit.effects.PushBack((int)effects[i]);
        }
        hitEffectsSent += effects.Size();
    }

    private function NewHit(p : r_CoopPuppet) : r_CoopHit
    {
        var hit : r_CoopHit;

        hit = new r_CoopHit in this;
        hit.seq = nextHitSeq;
        hit.netId = p.netId;
        nextHitSeq += 1;
        pendingHits.PushBack(hit);
        if(pendingHits.Size() > 32)
        {
            pendingHits.Erase(0);
        }
        hitsSent += 1;
        lastHitSend = -999;
        return hit;
    }

    private function PruneHits(lastSeq : int)
    {
        var i : int;

        for(i = pendingHits.Size() - 1; i >= 0; i -= 1)
        {
            if(pendingHits[i].seq <= lastSeq)
            {
                pendingHits.Erase(i);
            }
        }
    }

    // resends every unacknowledged hit until the leader's snapshot acknowledges it
    private function SendHits(now : float)
    {
        var text : string;
        var i, j : int;

        if(pendingHits.Size() == 0 && lastHitSentCount == 0 && hurtAck == lastSentHurtAck && !leaderListsMyHurts)
        {
            return;
        }
        if(now - lastHitSend < COOP_SEND_INTERVAL())
        {
            return;
        }

        text = "coop hit " + leaderName + " " + leaderEpoch + " " + session + " " + hurtAck + " " + pendingHits.Size();
        for(i = 0; i < pendingHits.Size(); i += 1)
        {
            text += " " + pendingHits[i].seq + " " + pendingHits[i].netId + " " + FloatToStringPrec(pendingHits[i].frac, 4)
                + " " + pendingHits[i].effects.Size();
            for(j = 0; j < pendingHits[i].effects.Size(); j += 1)
            {
                text += " " + pendingHits[i].effects[j];
            }
        }
        WO_Send(text);
        lastHitSend = now;
        lastHitSentCount = pendingHits.Size();
        lastSentHurtAck = hurtAck;
    }

    // ---------------------------------------------------------------- journal (milestone 3)

    // Every game records its quest and objective updates (the HUD hears about all of them, also the quest
    // system's own); the leader sends them, and members apply the ones that move them forward.
    public function OnJournalChange(journalEntry : CJournalBase)
    {
        var tag : name;
        var status, i : int;

        if(!journalEntry || applyingJournal)
        {
            return;
        }
        tag = journalEntry.GetUniqueScriptTag();
        if(!IsNameValid(tag))
        {
            return;
        }
        status = (int)theGame.GetJournalManager().GetEntryStatus(journalEntry);

        i = journalTags.FindFirst(tag);
        if(i < 0)
        {
            journalTags.PushBack(tag);
            journalStatus.PushBack(status);
            if(journalTags.Size() > 48)
            {
                journalTags.Erase(0);
                journalStatus.Erase(0);
            }
        }
        else
        {
            journalStatus[i] = status;
        }
        lastJournalSend = -999;
    }

    private function TrackingChanged() : bool
    {
        var manager : CWitcherJournalManager;
        var trackedTag, highlightedTag : name;

        manager = theGame.GetJournalManager();
        if(manager.GetTrackedQuest())
        {
            trackedTag = manager.GetTrackedQuest().GetUniqueScriptTag();
        }
        if(manager.GetHighlightedObjective())
        {
            highlightedTag = manager.GetHighlightedObjective().GetUniqueScriptTag();
        }
        if(trackedTag == sentTrackedQuest && highlightedTag == sentHighlighted)
        {
            return false;
        }
        sentTrackedQuest = trackedTag;
        sentHighlighted = highlightedTag;
        return true;
    }

    // "jr epoch tick trackedQuest highlightedObjective scene skipSeq skipValue count {tag status}"; the tick
    // changes every send so a member that joins later still gets it (the client passes unchanged state once)
    private function SendJournal(now : float)
    {
        var text : string;
        var i : int;

        if(now - lastJournalSend < 1.0)
        {
            return;
        }
        journalTick += 1;
        text = "coop jr " + epoch + " " + journalTick + " " + CoopEncode(NameToString(sentTrackedQuest))
            + " " + CoopEncode(NameToString(sentHighlighted)) + " " + CoopEncode(currentScene) + " " + sceneSkipSeq
            + " " + sceneSkipValue + " " + journalTags.Size();
        for(i = 0; i < journalTags.Size(); i += 1)
        {
            // tags can contain spaces ("Win unique card from crossroads innkeeper A485F434-...")
            text += " " + CoopEncode(NameToString(journalTags[i])) + " " + journalStatus[i];
        }
        WO_Send(text);
        lastJournalSend = now;
    }

    private function OnJournal(sender : string, count : int)
    {
        var manager : CWitcherJournalManager;
        var journalEntry : CJournalBase;
        var tag, trackedTag, highlightedTag : name;
        var status, current, n, i, idx : int;

        if(GetRole() != 2 || sender != leaderName || leaderEpoch == 0 || count < 9 || StringToInt(WO_Str(1), 0) != leaderEpoch)
        {
            return;
        }

        manager = theGame.GetJournalManager();
        journalMessages += 1;
        if(WO_Str(3) != "-")
        {
            trackedTag = WO_NameAt(3);
        }
        if(WO_Str(4) != "-")
        {
            highlightedTag = WO_NameAt(4);
        }
        ApplyLeaderSkip(CoopDecode(WO_Str(5)), StringToInt(WO_Str(6), 0), StringToInt(WO_Str(7), 0));

        n = StringToInt(WO_Str(8), 0);
        idx = 9;
        for(i = 0; i < n && idx + 1 < count; i += 1)
        {
            // the client restores the spaces of encoded fields, so this is the exact tag
            tag = WO_NameAt(idx);
            status = StringToInt(WO_Str(idx + 1), 0);
            idx += 2;

            lastJournalSeen = NameToString(tag) + "=" + status;
            journalEntry = FindJournalEntry(tag);
            if(!journalEntry)
            {
                journalMissing += 1;
                continue;
            }
            current = (int)manager.GetEntryStatus(journalEntry);
            if(JournalAdvances(current, status))
            {
                applyingJournal = true;
                manager.ActivateEntry(journalEntry, (EJournalStatus)status, true, true);
                applyingJournal = false;
                journalApplied += 1;
                lastJournalApplied = tag;
                lastJournalAppliedStatus = status;
            }
        }

        // after the statuses: a quest the leader just activated can be tracked here too
        ApplyLeaderTracking(trackedTag, highlightedTag);
    }

    // The leader's tracked quest and highlighted objective, applied when the leader changes them (so a member
    // can still track something else in between) and only for quests that are active here.
    private function ApplyLeaderTracking(trackedTag : name, highlightedTag : name)
    {
        var manager : CWitcherJournalManager;
        var journalQuest : CJournalQuest;
        var journalObjective : CJournalQuestObjective;

        manager = theGame.GetJournalManager();
        if(trackedTag != leaderTrackedQuest)
        {
            journalQuest = (CJournalQuest)FindJournalEntry(trackedTag);
            if(!IsNameValid(trackedTag) || (journalQuest && manager.GetEntryStatus(journalQuest) == JS_Active))
            {
                leaderTrackedQuest = trackedTag;
            }
            if(journalQuest && manager.GetEntryStatus(journalQuest) == JS_Active && manager.GetTrackedQuest() != journalQuest)
            {
                manager.SetTrackedQuest(journalQuest);
                trackedApplied += 1;
                lastTrackedApplied = trackedTag;
            }
        }
        if(highlightedTag != leaderHighlighted)
        {
            journalObjective = (CJournalQuestObjective)FindJournalEntry(highlightedTag);
            if(!IsNameValid(highlightedTag) || (journalObjective && manager.GetEntryStatus(journalObjective) == JS_Active))
            {
                leaderHighlighted = highlightedTag;
            }
            if(journalObjective && manager.GetEntryStatus(journalObjective) == JS_Active)
            {
                manager.SetHighlightedObjective(journalObjective);
            }
        }
    }

    // ---------------------------------------------------------------- quest facts

    // A save was loaded: fact changes count from here (the journal list works the same way).
    public function OnSessionStart()
    {
        factsReady = WO_FactsBaseline();
        nextFactsTry = theGame.GetEngineTimeAsSeconds() + 2;
    }

    // the facts DB may not be readable yet when the player spawns
    private function RetryFactsBaseline(now : float)
    {
        if(!factsReady && now >= nextFactsTry)
        {
            factsReady = WO_FactsBaseline();
            nextFactsTry = now + 2;
        }
    }

    public function FactsReady() : bool
    {
        return factsReady;
    }

    // "fx epoch tick page pages count {id sum}": one page of the facts this session changed, in turn
    private function SendFacts(now : float)
    {
        var page : string;

        if(!factsReady || now - lastFactsSend < 0.5)
        {
            return;
        }
        lastFactsSend = now;
        page = WO_FactsPage(40);
        if(page != "")
        {
            factsTick += 1;
            WO_Send("coop fx " + epoch + " " + factsTick + " " + page);
        }
    }

    // Forward only, like the journal: a fact goes up to the leader's sum, never down (a member that is
    // further along keeps its own value).
    private function OnFacts(sender : string, count : int)
    {
        var id : string;
        var sum, current, n, i, idx : int;

        if(GetRole() != 2 || sender != leaderName || leaderEpoch == 0 || count < 6 || StringToInt(WO_Str(1), 0) != leaderEpoch)
        {
            return;
        }

        n = StringToInt(WO_Str(5), 0);
        idx = 6;
        for(i = 0; i < n && idx + 1 < count; i += 1)
        {
            id = WO_Str(idx);
            sum = StringToInt(WO_Str(idx + 1), 0);
            idx += 2;

            current = FactsQuerySum(id);
            if(sum > current)
            {
                FactsAdd(id, sum - current);
                factsApplied += 1;
                lastFactApplied = id;
            }
        }
    }

    // ---------------------------------------------------------------- scenes

    public function OnSceneStarted(scene : CStoryScene)
    {
        if(scene)
        {
            currentScene = scene.GetPath();
        }
    }

    public function OnSceneEnded()
    {
        currentScene = "";
    }

    // the bots have no quest scene to share; they name one
    public function SetSceneForTest(path : string)
    {
        currentScene = path;
    }

    // The leader skipped a line or cutscene: members in the same scene skip with it.
    public function OnLocalSkip(value : int)
    {
        if(!wasHost || applyingSkip)
        {
            return;
        }
        sceneSkipSeq += 1;
        sceneSkipValue = value;
        lastJournalSend = -999;
    }

    private function ApplyLeaderSkip(scene : string, skipSeq : int, skipValue : int)
    {
        var count, i : int;

        // a new scene of the leader's: its earlier skips belong to another scene
        if(scene != leaderSceneSeen)
        {
            leaderSceneSeen = scene;
            leaderSkipSeen = skipSeq;
            return;
        }
        if(skipSeq <= leaderSkipSeen)
        {
            return;
        }
        count = Min(skipSeq - leaderSkipSeen, 3);
        leaderSkipSeen = skipSeq;
        if(scene == "" || scene != currentScene)
        {
            return;
        }

        applyingSkip = true;
        for(i = 0; i < count; i += 1)
        {
            theGame.GetStorySceneSystem().SendSignal(SSST_Skip, skipValue);
        }
        applyingSkip = false;
        skipsApplied += count;
    }

    private function FindJournalEntry(tag : name) : CJournalBase
    {
        var journalEntry : CJournalBase;
        var i : int;

        journalEntry = theGame.GetJournalManager().GetEntryByTag(tag);
        if(journalEntry)
        {
            return journalEntry;
        }

        i = journalIndexTags.FindFirst(tag);
        if(i < 0 && theGame.GetEngineTimeAsSeconds() - journalIndexBuiltAt > 5.0)
        {
            BuildJournalIndex();
            i = journalIndexTags.FindFirst(tag);
        }
        if(i >= 0)
        {
            return journalIndexEntries[i];
        }
        return NULL;
    }

    // Quests this game knows and their objectives, by unique tag: GetEntryByTag doesn't find objectives that
    // are still inactive here (the map menu walks the same hierarchy).
    private function BuildJournalIndex()
    {
        var quests : array<CJournalBase>;
        var journalQuest : CJournalQuest;
        var phase : CJournalQuestPhase;
        var child : CJournalBase;
        var i, j, k : int;

        journalIndexTags.Clear();
        journalIndexEntries.Clear();
        theGame.GetJournalManager().GetActivatedOfType('CJournalQuest', quests);
        for(i = 0; i < quests.Size(); i += 1)
        {
            journalQuest = (CJournalQuest)quests[i];
            if(!journalQuest)
            {
                continue;
            }
            journalIndexTags.PushBack(journalQuest.GetUniqueScriptTag());
            journalIndexEntries.PushBack(journalQuest);
            for(j = 0; j < journalQuest.GetNumChildren(); j += 1)
            {
                phase = (CJournalQuestPhase)journalQuest.GetChild(j);
                if(!phase)
                {
                    continue;
                }
                for(k = 0; k < phase.GetNumChildren(); k += 1)
                {
                    child = phase.GetChild(k);
                    if((CJournalQuestObjective)child)
                    {
                        journalIndexTags.PushBack(child.GetUniqueScriptTag());
                        journalIndexEntries.PushBack(child);
                    }
                }
            }
        }
        journalIndexBuiltAt = theGame.GetEngineTimeAsSeconds();
    }

    // inactive -> active -> succeeded/failed; never back, never from one outcome to the other
    private function JournalAdvances(current : int, wanted : int) : bool
    {
        if(current == (int)JS_Inactive)
        {
            return wanted != (int)JS_Inactive;
        }
        if(current == (int)JS_Active)
        {
            return wanted == (int)JS_Success || wanted == (int)JS_Failed;
        }
        return false;
    }

    public function JournalStatusOf(tag : name) : int
    {
        var journalEntry : CJournalBase;

        journalEntry = FindJournalEntry(tag);
        if(!journalEntry)
        {
            return -1;
        }
        return (int)theGame.GetJournalManager().GetEntryStatus(journalEntry);
    }

    public function JournalRecorded(tag : name) : bool
    {
        return journalTags.Contains(tag);
    }

    // ---------------------------------------------------------------- diagnostics

    public function HostEnemyCount() : int
    {
        return hostEnemies.Size();
    }

    public function HostEnemyAt(i : int) : CNewNPC
    {
        return hostEnemies[i].npc;
    }

    public function HostNetIdOf(npc : CNewNPC) : int
    {
        var e : r_CoopHostEnemy;

        e = FindHostEnemyByNpc(npc);
        if(e)
        {
            return e.netId;
        }
        return 0;
    }

    public function PuppetCount() : int
    {
        return puppets.Size();
    }

    public function PuppetAt(i : int) : CNewNPC
    {
        return puppets[i].npc;
    }

    public function PuppetHostHp(i : int) : float
    {
        return puppets[i].hp;
    }

    public function PuppetAlive(i : int) : bool
    {
        return puppets[i].alive;
    }

    public function PuppetSpawned(i : int) : bool
    {
        return puppets[i].spawned;
    }

    public function PuppetTarget(i : int) : Vector
    {
        return puppets[i].target;
    }

    public function PuppetInHitAnim(i : int) : bool
    {
        return puppets[i].npc.IsInHitAnim();
    }

    public function SuppressedCount() : int
    {
        return suppressed.Size();
    }

    public function PendingHitCount() : int
    {
        return pendingHits.Size();
    }
}

// what a puppet keeps of a hit, so the vanilla hit reaction runs (its health is the leader's anyway)
function COOP_FX_DAMAGE() : float
{
    return 0.01;
}

// an attack task (CoopAttackId) that is just a swing, played on a puppet's slot: no effect of its own comes from its
// animation's events (a spell's does)
function CoopSlotSwing(task : string) : bool
{
    var kind : string;

    kind = StrBeforeFirst(task, ":");
    return kind == "CBTTaskAttack" || kind == "CBTTaskTrollAttack";
}

// players farther apart than this run their own monsters (the leader's world doesn't simulate far away)
function COOP_SHARE_RANGE() : float
{
    return 60.0;
}

// seconds between enemy snapshots, hit claims and hurts; 0.1 was tuned for Steam relay, a home network takes 0.05
function COOP_SEND_INTERVAL() : float
{
    return 0.05;
}

// enum events ('RotateEvent': an attacker turns to its target) also name a shared monster's attack animation
@wrapMethod(CActor)
function OnEnumAnimEvent(animEventName : name, variant : SEnumVariant, animEventType : EAnimationEventType, animEventDuration : float,
    animInfo : SAnimationEventAnimInfo)
{
    var coop : r_CoopEnemies;

    coop = CoopEnemiesHere();
    if(coop && animEventType != AET_DurationEnd)
    {
        coop.OnEarlyAnimEvent((CNewNPC)this, animEventName, animInfo);
    }
    return wrappedMethod(animEventName, variant, animEventType, animEventDuration, animInfo);
}

@wrapMethod(CNewNPC)
function OnPreAttackEvent(animEventName : name, animEventType : EAnimationEventType, data : CPreAttackEventData, animInfo : SAnimationEventAnimInfo)
{
    var client : r_MultiplayerClient;

    client = theGame.r_getMultiplayerClient();
    if(client)
    {
        client.getCoopEnemies().OnEnemyAttack(this, animEventType, animInfo);
    }
    return wrappedMethod(animEventName, animEventType, data, animInfo);
}

// a puppet's own projectile on a member: it doesn't fly and goes (see MutesShot)
function CoopMutesShot(proj : W3AdvancedProjectile) : bool
{
    var coop : r_CoopEnemies;

    coop = CoopEnemiesHere();
    if(coop && coop.MutesShot(proj))
    {
        coop.projectilesMuted += 1;
        proj.DestroyAfter(0.1);
        return true;
    }
    return false;
}

function CoopProjectileShot(proj : W3AdvancedProjectile, angle : float, speed : float, target : Vector, range : float)
{
    var client : r_MultiplayerClient;

    client = theGame.r_getMultiplayerClient();
    if(client)
    {
        client.getCoopEnemies().OnEnemyProjectile(proj, angle, speed, target, range);
    }
}

@wrapMethod(W3AdvancedProjectile)
function ShootProjectileAtPosition(angle : float, velocity : float, target : Vector, optional range : float, optional collisionGroups : array<name>)
{
    if(CoopMutesShot(this))
    {
        return;
    }
    wrappedMethod(angle, velocity, target, range, collisionGroups);
    CoopProjectileShot(this, angle, velocity, target, range);
}

@wrapMethod(W3AdvancedProjectile)
function ShootProjectileAtNode(angle : float, velocity : float, target : CNode, optional range : float, optional collisionGroups : array<name>)
{
    if(CoopMutesShot(this))
    {
        return;
    }
    wrappedMethod(angle, velocity, target, range, collisionGroups);
    CoopProjectileShot(this, angle, velocity, target.GetWorldPosition(), range);
}

@wrapMethod(W3AdvancedProjectile)
function ShootProjectileAtBone(angle : float, velocity : float, target : CEntity, targetBone : name, optional range : float, optional collisionGroups : array<name>)
{
    if(CoopMutesShot(this))
    {
        return;
    }
    wrappedMethod(angle, velocity, target, targetBone, range, collisionGroups);
    CoopProjectileShot(this, angle, velocity, target.GetWorldPosition(), range);
}

@wrapMethod(W3AdvancedProjectile)
function ShootCakeProjectileAtPosition(cakeAngle : float, cakeHeight : float, shootAngle : float, velocity : float, target : Vector, range : float, optional collisionGroups : array<name>)
{
    if(CoopMutesShot(this))
    {
        return;
    }
    wrappedMethod(cakeAngle, cakeHeight, shootAngle, velocity, target, range, collisionGroups);
    CoopProjectileShot(this, shootAngle, velocity, target, range);
}

@wrapMethod(CBTTaskPlayAnimationEventDecorator)
function OnAnimEvent(animEventName : name, animEventType : EAnimationEventType, animInfo : SAnimationEventAnimInfo) : bool
{
    var client : r_MultiplayerClient;
    var attack : CBTTaskAttack;
    var reaction : CBTTaskHitReactionDecorator;

    // attacks and hit reactions are mirrored on their own
    attack = (CBTTaskAttack)this;
    reaction = (CBTTaskHitReactionDecorator)this;
    if(attack)
    {
        client = theGame.r_getMultiplayerClient();
        if(client)
        {
            client.getCoopEnemies().OnAttackAnimEvent(attack, animEventName, animInfo);
        }
    }
    else if(!reaction)
    {
        client = theGame.r_getMultiplayerClient();
        if(client)
        {
            client.getCoopEnemies().OnEnemyMove(this, animInfo);
        }
    }
    return wrappedMethod(animEventName, animEventType, animInfo);
}

// the moves members' copies make themselves ("" for the rest: shots, spells, ...). Monsters' trees often play them
// through the plain decorator (a nekker's dodge does), so then by the animation's name.
function CoopMoveKind(task : CBTTaskPlayAnimationEventDecorator, anim : name) : string
{
    var text : string;

    if((CBTTaskDodge)task)
    {
        return "dodge";
    }
    if((CBTTaskTaunt)task || (CBTTask3StateTaunt)task)
    {
        return "taunt";
    }
    if((CBTTaskJumpBack)task)
    {
        return "jumpback";
    }
    text = StrLower(NameToString(anim));
    // the parry task also raises the guard and plays counter-attacks (those come as attacks)
    if((CBTTaskPerformParry)task)
    {
        if(StrFindFirst(text, "parry") >= 0)
        {
            return "parry";
        }
        return "";
    }
    if(StrFindFirst(text, "dodge") >= 0 || StrFindFirst(text, "evade") >= 0)
    {
        return "dodge";
    }
    if(StrFindFirst(text, "taunt") >= 0)
    {
        return "taunt";
    }
    if(StrFindFirst(text, "jump_back") >= 0 || StrFindFirst(text, "jumpback") >= 0)
    {
        return "jumpback";
    }
    return "";
}

// a taunt's type, else the dodge direction its graph uses
function CoopMoveParam(task : CBTTaskPlayAnimationEventDecorator) : int
{
    var taunt : CBTTaskTaunt;

    taunt = (CBTTaskTaunt)task;
    if(taunt)
    {
        return (int)taunt.tauntType;
    }
    return (int)task.GetNPC().GetBehaviorVariable('DodgeDirection');
}

function CoopEnemiesHere() : r_CoopEnemies
{
    var client : r_MultiplayerClient;

    client = theGame.r_getMultiplayerClient();
    if(client)
    {
        return client.getCoopEnemies();
    }
    return NULL;
}

// A puppet (a member's copy of the leader's monster) dodges, taunts, jumps back and attacks only when the leader's
// monster does (r_CoopEnemies.PlayMove/PlayAttack); everyone else as usual.
function CoopIsPuppet(npc : CNewNPC) : bool
{
    var coop : r_CoopEnemies;

    coop = CoopEnemiesHere();
    if(coop)
    {
        return coop.IsPuppet(npc);
    }
    return false;
}

@wrapMethod(CBTTaskDodge)
function IsAvailable() : bool
{
    if(CoopIsPuppet(GetNPC()))
    {
        // a dodge turned into a counter-attack plays nothing on a puppet (its attacks wait for the leader's monster's)
        interruptTaskToExecuteCounter = false;
        if(!CoopEnemiesHere().PuppetMovePending(GetNPC(), "dodge", false))
        {
            return false;
        }
    }
    return wrappedMethod();
}

// on a warning: a puppet dodges for sure (in the leader's monster's direction) while a mirrored dodge waits, else never
@wrapMethod(CBTTaskDodge)
function Dodge() : bool
{
    var coop : r_CoopEnemies;
    var npc : CNewNPC;

    npc = GetNPC();
    if(!CoopIsPuppet(npc))
    {
        return wrappedMethod();
    }
    coop = CoopEnemiesHere();
    if(!coop.PuppetMovePending(npc, "dodge", true))
    {
        return false;
    }
    dodgeDirection = (EDodgeDirection)Max(0, coop.PuppetMoveParam(npc));
    npc.SetBehaviorVariable('DodgeDirection', (int)dodgeDirection);
    coop.NotePuppetDodge(npc, false, BTNS_Active);
    return true;
}

@wrapMethod(CBTTaskDodge)
function OnActivate() : EBTNodeStatus
{
    var status : EBTNodeStatus;
    var coop : r_CoopEnemies;

    status = wrappedMethod();
    coop = CoopEnemiesHere();
    if(coop)
    {
        coop.NotePuppetDodge(GetNPC(), true, status);
    }
    return status;
}

// a puppet parries when the leader's monster did, for sure then (no chance roll, no counter-attack instead), and
// never by itself
@wrapMethod(CBTTaskPerformParry)
function IsAvailable() : bool
{
    if(CoopIsPuppet(GetNPC()))
    {
        checkParryChance = false;
        interruptTaskToExecuteCounter = false;
        if(!CoopEnemiesHere().PuppetMovePending(GetNPC(), "parry", false))
        {
            GetNPC().SetParryEnabled(false);
            return false;
        }
    }
    return wrappedMethod();
}

@wrapMethod(CBTTaskTaunt)
function IsAvailable() : bool
{
    var coop : r_CoopEnemies;
    var param : int;

    if(!CoopIsPuppet(GetNPC()))
    {
        return wrappedMethod();
    }
    coop = CoopEnemiesHere();
    param = coop.PuppetMoveParam(GetNPC());
    return coop.PuppetMovePending(GetNPC(), "taunt", false) && (param < 0 || param == (int)tauntType);
}

@wrapMethod(CBTTaskJumpBack)
function IsAvailable() : bool
{
    if(CoopIsPuppet(GetNPC()))
    {
        return CoopEnemiesHere().PuppetMovePending(GetNPC(), "jumpback", false);
    }
    return wrappedMethod();
}

// the attack data of another player's swing on a member's screen (it warns no one, see MutesSwingsOf)
@wrapMethod(CActor)
function SetAttackData(data : CPreAttackEventData)
{
    var coop : r_CoopEnemies;

    coop = CoopEnemiesHere();
    if(coop && coop.MutesSwingsOf(this))
    {
        if(!IsNameValid(attackActionName))
        {
            attackActionName = data.attackName;
        }
        return;
    }
    wrappedMethod(data);
}

@wrapMethod(CBTTaskAttack)
function IsAvailable() : bool
{
    if(!CoopPuppetMayAttack(this, isActive))
    {
        return false;
    }
    return wrappedMethod();
}

// Spaces separate fields on the wire; '*' can't appear in depot paths or appearance names.
function CoopEncode(text : string) : string
{
    if(text == "")
    {
        return "-";
    }
    return StrReplaceAll(text, " ", "*");
}

function CoopDecode(text : string) : string
{
    if(text == "-")
    {
        return "";
    }
    return StrReplaceAll(text, "*", " ");
}

@wrapMethod(W3DamageManagerProcessor)
function ProcessAction(act : W3DamageAction)
{
    var client : r_MultiplayerClient;
    var coop : r_CoopEnemies;

    client = theGame.r_getMultiplayerClient();
    if(client)
    {
        coop = client.getCoopEnemies();
    }
    if(coop && coop.OnBeforeDamage(act))
    {
        return;
    }

    wrappedMethod(act);
    if(coop)
    {
        coop.OnAfterDamage(act);
    }
}

// Damage to a puppet is computed here as usual, sent to the leader, and not applied locally: the leader's
// health comes back in its next snapshot.
@wrapMethod(CNewNPC)
function OnTakeDamage(action : W3DamageAction)
{
    var client : r_MultiplayerClient;
    var coop : r_CoopEnemies;

    client = theGame.r_getMultiplayerClient();
    if(client)
    {
        coop = client.getCoopEnemies();
    }
    if(coop && !coop.applyingHostState && coop.IsPuppet(this))
    {
        coop.OnPuppetDamaged(this, action);
        // a negligible remainder instead of zero keeps the vanilla hit reaction (it needs damage dealt)
        action.SetAllProcessedDamageAs(0);
        action.processedDmg.vitalityDamage = COOP_FX_DAMAGE();
        action.processedDmg.essenceDamage = COOP_FX_DAMAGE();
    }
    else if(coop)
    {
        coop.OnEnemyDamaged(this, action);
        client.getCoopParty().OnNpcDamaged(this, action);
    }

    wrappedMethod(action);
}

@wrapMethod(CR4ScriptedHud)
function OnQuestEvent(journalQuest : CJournalQuest)
{
    var client : r_MultiplayerClient;

    client = theGame.r_getMultiplayerClient();
    if(client)
    {
        client.getCoopEnemies().OnJournalChange(journalQuest);
    }
    return wrappedMethod(journalQuest);
}

@wrapMethod(CR4ScriptedHud)
function OnQuestObjectiveEvent(journalQuest : CJournalQuest, journalObjective : CJournalQuestObjective)
{
    var client : r_MultiplayerClient;

    client = theGame.r_getMultiplayerClient();
    if(client)
    {
        client.getCoopEnemies().OnJournalChange(journalQuest);
        client.getCoopEnemies().OnJournalChange(journalObjective);
    }
    return wrappedMethod(journalQuest, journalObjective);
}

// Which attack it is, the same in every copy of a monster: the task's class and attack type (its animation set)
@addMethod(CBTTaskAttack)
function CoopAttackId() : string
{
    return ToString() + ":" + (int)attackType;
}

// true unless a puppet's attack task may not start now (r_CoopEnemies.PuppetAttackAllowed)
// (an attack under way, `running`, goes on: the tree asks again while it runs, and a spell's loop outlasts the window)
function CoopPuppetMayAttack(task : CBTTaskAttack, running : bool) : bool
{
    var coop : r_CoopEnemies;

    coop = CoopEnemiesHere();
    if(!coop || running)
    {
        return true;
    }
    return coop.PuppetAttackAllowed(task);
}

@wrapMethod(CBTTaskAttack)
function OnActivate() : EBTNodeStatus
{
    var status : EBTNodeStatus;
    var coop : r_CoopEnemies;

    coop = CoopEnemiesHere();
    // a puppet's swing the gate holds: human trees start their attack tasks without asking IsAvailable
    if(coop && !coop.PuppetAttackAllowed(this))
    {
        return BTNS_Failed;
    }
    status = wrappedMethod();
    if(coop)
    {
        coop.OnAttackTask(this, true);
    }
    return status;
}

@wrapMethod(CBTTaskAttack)
function OnDeactivate()
{
    var coop : r_CoopEnemies;

    coop = CoopEnemiesHere();
    if(coop)
    {
        coop.OnAttackTask(this, false);
    }
    wrappedMethod();
}

// these attack tasks decide their availability without CBTTaskAttack.IsAvailable

@wrapMethod(CBTTask3StateCharge)
function IsAvailable() : bool
{
    if(!CoopPuppetMayAttack(this, isActive))
    {
        return false;
    }
    return wrappedMethod();
}

@wrapMethod(CBTTask3StateLightCharge)
function IsAvailable() : bool
{
    if(!CoopPuppetMayAttack(this, isActive))
    {
        return false;
    }
    return wrappedMethod();
}

@wrapMethod(CBTTaskBiesCharge)
function IsAvailable() : bool
{
    if(!CoopPuppetMayAttack(this, isActive))
    {
        return false;
    }
    return wrappedMethod();
}

@wrapMethod(CBTTaskCastSign)
function IsAvailable() : bool
{
    if(!CoopPuppetMayAttack(this, isActive))
    {
        return false;
    }
    return wrappedMethod();
}

@wrapMethod(CBTTaskCastAard)
function IsAvailable() : bool
{
    if(!CoopPuppetMayAttack(this, isActive))
    {
        return false;
    }
    return wrappedMethod();
}

@wrapMethod(CBTTaskCastIgni)
function IsAvailable() : bool
{
    if(!CoopPuppetMayAttack(this, isActive))
    {
        return false;
    }
    return wrappedMethod();
}

@wrapMethod(CBTTaskCastQuen)
function IsAvailable() : bool
{
    if(!CoopPuppetMayAttack(this, isActive))
    {
        return false;
    }
    return wrappedMethod();
}

@wrapMethod(CBTTaskDettlaffDash)
function IsAvailable() : bool
{
    if(!CoopPuppetMayAttack(this, isActive))
    {
        return false;
    }
    return wrappedMethod();
}

@wrapMethod(CBTTaskIceGiantFallingIcicles)
function IsAvailable() : bool
{
    if(!CoopPuppetMayAttack(this, isActive))
    {
        return false;
    }
    return wrappedMethod();
}

@wrapMethod(CBTTaskMagicFXAttack)
function IsAvailable() : bool
{
    if(!CoopPuppetMayAttack(this, isActive))
    {
        return false;
    }
    return wrappedMethod();
}

@wrapMethod(CBTTaskMagicMeleeAttack)
function IsAvailable() : bool
{
    if(!CoopPuppetMayAttack(this, isActive))
    {
        return false;
    }
    return wrappedMethod();
}

@wrapMethod(CBTTaskPlaySyncAnimAttack)
function IsAvailable() : bool
{
    if(!CoopPuppetMayAttack(this, isActive))
    {
        return false;
    }
    return wrappedMethod();
}

@wrapMethod(CBTTaskProjectileAttack)
function IsAvailable() : bool
{
    if(!CoopPuppetMayAttack(this, isActive))
    {
        return false;
    }
    return wrappedMethod();
}

@wrapMethod(CBTTaskSummonCreatures)
function IsAvailable() : bool
{
    if(!CoopPuppetMayAttack(this, isActive))
    {
        return false;
    }
    return wrappedMethod();
}

@wrapMethod(CBTTaskSummonCreaturesWithLevel)
function IsAvailable() : bool
{
    if(!CoopPuppetMayAttack(this, isActive))
    {
        return false;
    }
    return wrappedMethod();
}

@wrapMethod(CBTTaskThrowBomb)
function IsAvailable() : bool
{
    if(!CoopPuppetMayAttack(this, isActive))
    {
        return false;
    }
    return wrappedMethod();
}

// area spells, counted (OnSpellSpawn)
function CoopSpellSpawn(npc : CNewNPC)
{
    var coop : r_CoopEnemies;

    coop = CoopEnemiesHere();
    if(coop)
    {
        coop.OnSpellSpawn(npc);
    }
}

@wrapMethod(CBTTaskSpawnEntityAttack)
function SpawnEntity()
{
    wrappedMethod();
    CoopSpellSpawn(GetNPC());
}

@wrapMethod(CBTTaskLeshyRootAttack)
function ShootProjectile()
{
    wrappedMethod();
    CoopSpellSpawn(GetNPC());
}

@wrapMethod(CBTTaskElementalDaoStoneSmash)
function OnAnimEvent(animEventName : name, animEventType : EAnimationEventType, animInfo : SAnimationEventAnimInfo) : bool
{
    var res : bool;

    res = wrappedMethod(animEventName, animEventType, animInfo);
    if(animEventName == 'Prepare')
    {
        CoopSpellSpawn(GetNPC());
    }
    return res;
}

@wrapMethod(CBTTaskElementalThrowFire)
function OnAnimEvent(animEventName : name, animEventType : EAnimationEventType, animInfo : SAnimationEventAnimInfo) : bool
{
    var res : bool;

    res = wrappedMethod(animEventName, animEventType, animInfo);
    if(animEventName == 'Prepare')
    {
        CoopSpellSpawn(GetNPC());
    }
    return res;
}

@wrapMethod(CBTTaskSpawnMultipleEntitiesAttack)
function CreateEntity(_SpawnPos : Vector, _Rotation : EulerAngles) : CEntity
{
    var entity : CEntity;

    entity = wrappedMethod(_SpawnPos, _Rotation);
    if(entity)
    {
        CoopSpellSpawn(GetNPC());
    }
    return entity;
}

// an effect entity of a monster's or mage's special (lightning, tornado, ground blast, ...), not an attack task
@wrapMethod(CBTTaskSpawnFXEntity)
function OnDeactivate()
{
    var coop : r_CoopEnemies;

    if(spawned)
    {
        CoopSpellSpawn(GetNPC());
        coop = CoopEnemiesHere();
        if(coop)
        {
            coop.lastFxSpawn = NameToString(resourceName);
        }
    }
    wrappedMethod();
}

@wrapMethod(CBTTaskSpawnFXEntity)
function OnActivate() : EBTNodeStatus
{
    var coop : r_CoopEnemies;

    coop = CoopEnemiesHere();
    if(coop && coop.IsPuppet(GetNPC()))
    {
        coop.puppetFxTasks += 1;
    }
    return wrappedMethod();
}

// projectiles dropped from above get no caster: the monster spawning them stands in meanwhile (ShooterOf)
@wrapMethod(CBTTaskDropProjectilesFromAbove)
function Spawn(position : Vector)
{
    var coop : r_CoopEnemies;

    coop = CoopEnemiesHere();
    if(coop)
    {
        coop.projectileSpawner = GetNPC();
    }
    wrappedMethod(position);
    if(coop)
    {
        coop.projectileSpawner = NULL;
        CoopSpellSpawn(GetNPC());
    }
}

// subclasses (attacks, dodges, taunts, hit reactions, ...) have their own rules: only the plain task is held here
@wrapMethod(CBTTaskPlayAnimationEventDecorator)
function IsAvailable() : bool
{
    var coop : r_CoopEnemies;

    coop = CoopEnemiesHere();
    if(coop && coop.IsPuppet(GetNPC()) && ToString() == "CBTTaskPlayAnimationEventDecorator"
        && !coop.PuppetPlainMoveAllowed(GetNPC()))
    {
        return false;
    }
    return wrappedMethod();
}

@wrapMethod(CBTTaskSpawnMultipleEntities3StateAttack)
function CreateEntity(_SpawnPos : Vector, _Rotation : EulerAngles) : CEntity
{
    var entity : CEntity;

    entity = wrappedMethod(_SpawnPos, _Rotation);
    if(entity)
    {
        CoopSpellSpawn(GetNPC());
    }
    return entity;
}

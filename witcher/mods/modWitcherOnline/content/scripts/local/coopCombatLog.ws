// The combat log names fighters with GetDisplayName(), which is "Geralt" for this player and for every ghost.
// In co-op it names players by their usernames and also lists the other player's hits.

function WO_CombatName(entity : CGameplayEntity) : string
{
    var client : r_MultiplayerClient;
    var remote : r_RemotePlayer;

    if(!entity)
    {
        return "";
    }

    client = theGame.r_getMultiplayerClient();
    if(client)
    {
        if(entity == thePlayer && client.getUsername() != "")
        {
            return client.getUsername();
        }
        remote = mpghosts_getPlayerFromActor((CActor)entity);
        if(remote && remote.username != "")
        {
            return remote.username;
        }
    }
    return entity.GetDisplayName();
}

function WO_IsGhostEntity(entity : CGameplayEntity) : bool
{
    if(!entity || !theGame.r_getMultiplayerClient())
    {
        return false;
    }
    if(mpghosts_getPlayerFromActor((CActor)entity))
    {
        return true;
    }
    return false;
}

@wrapMethod(W3GameLog)
function ShouldShowCombatMessage(attacker : CGameplayEntity, victim : CGameplayEntity) : bool
{
    if(wrappedMethod(attacker, victim))
    {
        return true;
    }
    return (thePlayer.IsThreatened() || thePlayer.IsInCombat()) && (WO_IsGhostEntity(attacker) || WO_IsGhostEntity(victim));
}

@wrapMethod(W3GameLog)
function CreateCombatMessage(cachedDamageIndex : int) : string
{
    var text, original, renamed : string;
    var msg : SCachedCombatMessage;

    text = wrappedMethod(cachedDamageIndex);
    if(text == "")
    {
        return text;
    }

    // swap the attacker's then the victim's display name for the player name, in the order the log prints them
    msg = cachedCombatMessages[cachedDamageIndex];
    if(msg.attacker)
    {
        original = msg.attacker.GetDisplayName();
        renamed = WO_CombatName(msg.attacker);
        if(original != "" && renamed != original)
        {
            text = StrReplace(text, original, renamed);
        }
    }
    if(msg.victim)
    {
        original = msg.victim.GetDisplayName();
        renamed = WO_CombatName(msg.victim);
        if(original != "" && renamed != original)
        {
            text = StrReplace(text, original, renamed);
        }
    }
    return text;
}

// The member's own character in the host's world. The member plays a copy of the host's save, which brings the host's
// level, skills and inventory; this keeps the member's own instead. Captured while the member plays their own
// character, stored in user settings (they survive loading a save), and put back after every load of a host save.
//
// World marks (facts, so every save carries them):
//   w3coop_host_world    set by the host's game: this world is the host's
//   w3coop_member_world  set by `coopprofile` in the member's own world
//   w3coop_member_char   set once the member's character has been put into a copy of the host's world

function WO_PROFILE_CHUNKS() : int
{
    return 40;
}

function WO_PROFILE_CHUNK_SIZE() : int
{
    return 2000;
}

function WO_ProfileVar(i : int) : name
{
    if(i < 10)
    {
        return WO_ToName("WO_P0" + i);
    }
    return WO_ToName("WO_P" + i);
}

// fields are split by ';' '/' '+'; names keep their spaces as '~'
function WO_ProfileEnc(text : string) : string
{
    text = StrReplaceAll(text, " ", "~");
    text = StrReplaceAll(text, ";", "_");
    text = StrReplaceAll(text, "/", "_");
    return StrReplaceAll(text, "+", "_");
}

function WO_ProfileDec(text : string) : string
{
    return StrReplaceAll(text, "~", " ");
}

function WO_ProfileSplit(text : string, separator : string) : array<string>
{
    var parts : array<string>;
    var rest : string;

    rest = text;
    while(StrFindFirst(rest, separator) >= 0)
    {
        parts.PushBack(StrBeforeFirst(rest, separator));
        rest = StrAfterFirst(rest, separator);
    }
    parts.PushBack(rest);
    return parts;
}

function WO_SaveProfileString(text : string)
{
    var cfg : CInGameConfigWrapper;
    var i : int;

    cfg = theGame.GetInGameConfigWrapper();
    for(i = 0; i < WO_PROFILE_CHUNKS(); i += 1)
    {
        if(i * WO_PROFILE_CHUNK_SIZE() < StrLen(text))
        {
            cfg.SetVarValue('MPGhosts_Profile', WO_ProfileVar(i), StrMid(text, i * WO_PROFILE_CHUNK_SIZE(), WO_PROFILE_CHUNK_SIZE()));
        }
        else
        {
            cfg.SetVarValue('MPGhosts_Profile', WO_ProfileVar(i), "");
        }
    }
    theGame.SaveUserSettings();
}

function WO_LoadProfileString() : string
{
    var cfg : CInGameConfigWrapper;
    var text, chunk : string;
    var i : int;

    cfg = theGame.GetInGameConfigWrapper();
    for(i = 0; i < WO_PROFILE_CHUNKS(); i += 1)
    {
        chunk = cfg.GetVarValue('MPGhosts_Profile', WO_ProfileVar(i));
        if(chunk == "")
        {
            break;
        }
        text += chunk;
    }
    return text;
}

// Items that belong to the world rather than the character stay as they are: quest items, hidden and undroppable
// system items (fists, body, hair, medallion and the like) and money (handled as a number).
function WO_ProfileKeepsItem(inv : CInventoryComponent, id : SItemUniqueId) : bool
{
    var category : name;

    if(inv.IsItemQuest(id) || inv.ItemHasTag(id, 'NoShow') || inv.ItemHasTag(id, 'NoDrop'))
    {
        return false;
    }
    category = inv.GetItemCategory(id);
    if(category == 'body' || category == 'hair' || category == 'fist' || category == 'money' || inv.GetItemName(id) == 'Crowns')
    {
        return false;
    }
    return true;
}

@addMethod(W3LevelManager)
public function WO_SetProgress(lvl : int, xp : int, skillFree : int, skillUsed : int)
{
    level = lvl;
    points[EExperiencePoint].free = xp;
    points[EExperiencePoint].used = 0;
    points[ESkillPoint].free = skillFree;
    points[ESkillPoint].used = skillUsed;
}

class r_CoopProfile
{
    private var sessionStartAt : float;
    private var decided : bool;
    private var live : bool;
    private var notedUnknown : bool;
    private var lastCaptureAt : float;
    private var lastTickAt : float;

    private function IsMemberPC() : bool
    {
        return WO_AutoJoinTarget() != "";
    }

    private function Note(text : string)
    {
        theGame.GetGuiManager().ShowNotification("Co-op: " + text);
    }

    public function OnSessionStart()
    {
        sessionStartAt = theGame.GetEngineTimeAsSeconds();
        decided = false;
        live = false;
        notedUnknown = false;
        lastCaptureAt = sessionStartAt;

        // the host's world carries its mark into every save made from now on
        if(!IsMemberPC() && FactsQuerySum("w3coop_host_world") == 0)
        {
            FactsAdd("w3coop_host_world", 1);
        }
    }

    public function Tick()
    {
        var now : float;
        var stored : string;

        if(!IsMemberPC() || !GetWitcherPlayer() || !GetWitcherPlayer().abilityManager || !GetWitcherPlayer().abilityManager.IsInitialized())
        {
            return;
        }
        now = theGame.GetEngineTimeAsSeconds();
        if(now - lastTickAt < 0.5 || now - sessionStartAt < 3.0)
        {
            return;
        }
        lastTickAt = now;

        if(!decided)
        {
            if(FactsQuerySum("w3coop_member_char") > 0 || FactsQuerySum("w3coop_member_world") > 0)
            {
                decided = true;
                live = true;
            }
            else if(FactsQuerySum("w3coop_host_world") > 0 || theGame.r_getMultiplayerClient().getCoopEnemies().GetRole() == 2)
            {
                decided = true;
                stored = WO_LoadProfileString();
                if(StrLeft(stored, 3) == "v1;")
                {
                    Apply(stored);
                    FactsAdd("w3coop_member_char", 1);
                    live = true;
                    lastCaptureAt = now;
                    Note("tvoje postava je zpět: level " + GetWitcherPlayer().GetLevel() + ".");
                }
                else
                {
                    Note("tvoje postava ještě není uložená. Načti jednou svou vlastní uloženou hru a napiš do konzole coopprofile.");
                }
            }
            else if(!notedUnknown && now - sessionStartAt > 20.0)
            {
                notedUnknown = true;
                Note("jestli hraješ svou vlastní postavu, napiš do konzole coopprofile, ať si ji mod zapamatuje.");
            }
        }

        if(live && now - lastCaptureAt > 60.0)
        {
            Capture();
            lastCaptureAt = now;
        }
    }

    public function OnSaveCompleted()
    {
        if(live && IsMemberPC())
        {
            Capture();
            lastCaptureAt = theGame.GetEngineTimeAsSeconds();
        }
    }

    // `coopprofile` in the member's own save: this world is the member's, remember this character
    public function MarkOwnWorld()
    {
        if(!IsMemberPC())
        {
            Note("profil postavy je jen pro hráče, který se připojuje.");
            return;
        }
        if(FactsQuerySum("w3coop_host_world") > 0 && FactsQuerySum("w3coop_member_char") == 0)
        {
            Note("tohle je svět hosta s jeho postavou. Načti svou vlastní uloženou hru.");
            return;
        }
        FactsAdd("w3coop_member_world", 1);
        decided = true;
        live = true;
        Capture();
        lastCaptureAt = theGame.GetEngineTimeAsSeconds();
        Note("postava uložená: level " + GetWitcherPlayer().GetLevel() + ".");
    }

    // "v1;L/level/xp/skillFree/skillUsed/money;S/skill+level...;Q/slot+skill...;I/name+qty+slot+rune+rune...;A/recipe...;C/schematic..."
    public function Capture()
    {
        var w : W3PlayerWitcher;
        var inv : CInventoryComponent;
        var ids : array<SItemUniqueId>;
        var skills : array<SSkill>;
        var runes, recipes : array<name>;
        var text : string;
        var i, j, slotID : int;
        var skill : ESkill;

        w = GetWitcherPlayer();
        if(!w || !w.levelManager)
        {
            return;
        }
        inv = w.GetInventory();

        text = "v1;L/" + w.levelManager.GetLevel() + "/" + w.levelManager.GetPointsTotal(EExperiencePoint) + "/"
            + w.levelManager.GetPointsFree(ESkillPoint) + "/" + w.levelManager.GetPointsUsed(ESkillPoint) + "/" + inv.GetMoney();

        text += ";S";
        skills = w.GetPlayerSkills();
        for(i = 0; i < skills.Size(); i += 1)
        {
            if(skills[i].level > 0 && !skills[i].isTemporary)
            {
                text += "/" + (int)skills[i].skillType + "+" + skills[i].level;
            }
        }

        text += ";Q";
        for(i = 0; i < w.GetSkillSlotsCount(); i += 1)
        {
            slotID = w.GetSkillSlotIDFromIndex(i);
            if(w.GetSkillOnSlot(slotID, skill) && skill != S_SUndefined)
            {
                text += "/" + slotID + "+" + (int)skill;
            }
        }

        text += ";I";
        inv.GetAllItems(ids);
        for(i = 0; i < ids.Size(); i += 1)
        {
            if(!WO_ProfileKeepsItem(inv, ids[i]))
            {
                continue;
            }
            text += "/" + WO_ProfileEnc(NameToString(inv.GetItemName(ids[i]))) + "+" + inv.GetItemQuantity(ids[i]) + "+" + (int)w.GetItemSlot(ids[i]);
            runes.Clear();
            inv.GetItemEnhancementItems(ids[i], runes);
            for(j = 0; j < runes.Size(); j += 1)
            {
                text += "+" + WO_ProfileEnc(NameToString(runes[j]));
            }
        }

        text += ";A";
        recipes = w.GetAlchemyRecipes();
        for(i = 0; i < recipes.Size(); i += 1)
        {
            text += "/" + WO_ProfileEnc(NameToString(recipes[i]));
        }

        text += ";C";
        recipes = w.GetCraftingSchematicsNames();
        for(i = 0; i < recipes.Size(); i += 1)
        {
            text += "/" + WO_ProfileEnc(NameToString(recipes[i]));
        }

        if(StrLen(text) > WO_PROFILE_CHUNKS() * WO_PROFILE_CHUNK_SIZE())
        {
            Note("postava se nevejde do profilu (" + StrLen(text) + " znaků), neukládám.");
            return;
        }
        WO_SaveProfileString(text);
    }

    private function Apply(text : string)
    {
        var w : W3PlayerWitcher;
        var inv : CInventoryComponent;
        var sections, fields, bits : array<string>;
        var ids, added, rune : array<SItemUniqueId>;
        var mutagenIds : array<SItemUniqueId>;
        var mutagenSlots : array<EEquipmentSlots>;
        var level, xp, skillFree, skillUsed, money, target, guard, i, j, k : int;
        var slot : EEquipmentSlots;
        var skill : ESkill;
        var lvlAbility : name;

        w = GetWitcherPlayer();
        inv = w.GetInventory();
        sections = WO_ProfileSplit(text, ";");
        level = w.levelManager.GetLevel();
        xp = w.levelManager.GetPointsTotal(EExperiencePoint);
        skillFree = w.levelManager.GetPointsFree(ESkillPoint);
        skillUsed = w.levelManager.GetPointsUsed(ESkillPoint);

        // the host's character out: skills refunded, everything that is the character's taken off and removed
        w.ResetCharacterDev();
        ids = w.GetEquippedItems();
        for(i = 0; i < ids.Size(); i += 1)
        {
            if(inv.IsIdValid(ids[i]) && WO_ProfileKeepsItem(inv, ids[i]))
            {
                w.UnequipItemFromSlot(w.GetItemSlot(ids[i]));
            }
        }
        ids.Clear();
        inv.GetAllItems(ids);
        for(i = 0; i < ids.Size(); i += 1)
        {
            if(WO_ProfileKeepsItem(inv, ids[i]))
            {
                inv.RemoveItem(ids[i], inv.GetItemQuantity(ids[i]));
            }
        }

        for(i = 1; i < sections.Size(); i += 1)
        {
            fields = WO_ProfileSplit(sections[i], "/");
            if(fields[0] == "L" && fields.Size() >= 6)
            {
                level = StringToInt(fields[1], 1);
                xp = StringToInt(fields[2], 0);
                skillFree = StringToInt(fields[3], 0);
                skillUsed = StringToInt(fields[4], 0);
                money = StringToInt(fields[5], 0);

                // every point free first, so re-learning the skills below can spend them
                w.levelManager.WO_SetProgress(level, xp, skillFree + skillUsed, 0);
                for(k = 1; k <= w.levelManager.GetMaxLevel(); k += 1)
                {
                    lvlAbility = w.GetLevelupAbility(k);
                    if(!IsNameValid(lvlAbility))
                    {
                        continue;
                    }
                    if(k <= level && !w.HasAbility(lvlAbility))
                    {
                        w.AddAbility(lvlAbility, false);
                    }
                    else if(k > level && w.HasAbility(lvlAbility))
                    {
                        w.RemoveAbilityAll(lvlAbility);
                    }
                }
                ((W3PlayerAbilityManager)w.abilityManager).UpdateSkillSlots();

                if(money > inv.GetMoney())
                {
                    inv.AddMoney(money - inv.GetMoney());
                }
                else if(money < inv.GetMoney())
                {
                    inv.RemoveMoney(inv.GetMoney() - money);
                }
            }
            else if(fields[0] == "S")
            {
                for(j = 1; j < fields.Size(); j += 1)
                {
                    bits = WO_ProfileSplit(fields[j], "+");
                    if(bits.Size() < 2)
                    {
                        continue;
                    }
                    skill = (ESkill)StringToInt(bits[0], 0);
                    target = StringToInt(bits[1], 0);
                    for(guard = 0; guard < 10 && w.GetSkillLevel(skill) < target; guard += 1)
                    {
                        w.AddSkill(skill, false);
                    }
                }
            }
            else if(fields[0] == "Q")
            {
                for(j = 1; j < fields.Size(); j += 1)
                {
                    bits = WO_ProfileSplit(fields[j], "+");
                    if(bits.Size() >= 2)
                    {
                        w.EquipSkill((ESkill)StringToInt(bits[1], 0), StringToInt(bits[0], 0));
                    }
                }
            }
            else if(fields[0] == "I")
            {
                for(j = 1; j < fields.Size(); j += 1)
                {
                    bits = WO_ProfileSplit(fields[j], "+");
                    if(bits.Size() < 3)
                    {
                        continue;
                    }
                    added = inv.AddAnItem(WO_ToName(WO_ProfileDec(bits[0])), StringToInt(bits[1], 1), true, true);
                    if(added.Size() == 0)
                    {
                        continue;
                    }
                    for(k = 3; k < bits.Size(); k += 1)
                    {
                        rune = inv.AddAnItem(WO_ToName(WO_ProfileDec(bits[k])), 1, true, true);
                        if(rune.Size() > 0)
                        {
                            inv.EnhanceItemScript(added[0], rune[0]);
                        }
                    }
                    slot = (EEquipmentSlots)StringToInt(bits[2], 0);
                    if(slot == EES_SkillMutagen1 || slot == EES_SkillMutagen2 || slot == EES_SkillMutagen3 || slot == EES_SkillMutagen4)
                    {
                        mutagenIds.PushBack(added[0]);
                        mutagenSlots.PushBack(slot);
                    }
                    else if(slot != EES_InvalidSlot)
                    {
                        w.EquipItemInGivenSlot(added[0], slot, false);
                    }
                }
            }
            else if(fields[0] == "A")
            {
                for(j = 1; j < fields.Size(); j += 1)
                {
                    if(fields[j] != "")
                    {
                        w.AddAlchemyRecipe(WO_ToName(WO_ProfileDec(fields[j])), true, true);
                    }
                }
            }
            else if(fields[0] == "C")
            {
                for(j = 1; j < fields.Size(); j += 1)
                {
                    if(fields[j] != "")
                    {
                        w.AddCraftingSchematic(WO_ToName(WO_ProfileDec(fields[j])), true, true);
                    }
                }
            }
        }

        // mutagens go into their slots once the skill slots they colour are in place
        for(i = 0; i < mutagenIds.Size(); i += 1)
        {
            w.EquipItemInGivenSlot(mutagenIds[i], mutagenSlots[i], false);
        }

        // the points exactly as the member had them
        w.levelManager.WO_SetProgress(level, xp, skillFree, skillUsed);
    }
}

exec function coopprofile()
{
    theGame.r_getMultiplayerClient().getCoopParty().GetProfile().MarkOwnWorld();
}

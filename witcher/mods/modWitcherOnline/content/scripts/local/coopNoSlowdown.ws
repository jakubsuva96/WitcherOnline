// Slow motion slows only the local world while the other player's keeps running, so co-op runs at 1x.
// SetTimeScale is native and can't be wrapped; the tick loop strips these sources every frame instead.
// Kept: meditation (speeds time up; handled separately), debug input, skating and quest-scripted time scales.
function WO_RemoveCoopSlowdowns()
{
    theGame.RemoveTimeScale(theGame.GetTimescaleSource(ETS_PotionBlizzard));
    theGame.RemoveTimeScale(theGame.GetTimescaleSource(ETS_SlowMoTask));
    theGame.RemoveTimeScale(theGame.GetTimescaleSource(ETS_HeavyAttack));
    theGame.RemoveTimeScale(theGame.GetTimescaleSource(ETS_ThrowingAim));
    theGame.RemoveTimeScale(theGame.GetTimescaleSource(ETS_RadialMenu));
    theGame.RemoveTimeScale(theGame.GetTimescaleSource(ETS_CFM_PlayAnim));
    theGame.RemoveTimeScale(theGame.GetTimescaleSource(ETS_CFM_On));
    theGame.RemoveTimeScale(theGame.GetTimescaleSource(ETS_SkillFrenzy));
    theGame.RemoveTimeScale(theGame.GetTimescaleSource(ETS_RaceSlowMo));
    theGame.RemoveTimeScale(theGame.GetTimescaleSource(ETS_HorseMelee));
    theGame.RemoveTimeScale(theGame.GetTimescaleSource(ETS_FinisherInput));
    theGame.RemoveTimeScale(theGame.GetTimescaleSource(ETS_TutorialFight));
    theGame.RemoveTimeScale(theGame.GetTimescaleSource(ETS_InstantKill));
    theGame.RemoveTimeScale('AnimEventSlomoMo');
    theGame.RemoveTimeScale('CiriSpecialAttackHeavy');
    theGame.RemoveTimeScale('CiriPhantom');
}

// The Esc menu pauses the world, which in co-op freezes the shared monsters for the other player too. The pause comes
// from the menu definition (not from script), so its reason isn't known for sure: every likely one is released.
// Releasing a reason that isn't held does nothing.
@wrapMethod(CR4CommonIngameMenu)
function OnConfigUI()
{
    wrappedMethod();
    if(theGame.r_getMultiplayerClient() && theGame.r_getMultiplayerClient().getCoopEnemies().GetRole() != 0)
    {
        theGame.Unpause("CommonIngameMenu");
        theGame.Unpause("IngameMenu");
        theGame.Unpause("menus");
        theGame.Unpause("Menu");
        theGame.Unpause("menu");
        theGame.Unpause("GUI");
        theGame.Unpause("gui");
        theGame.Unpause("UI");
    }
}

// The wheel opens on input, between ticks; strip its slow motion right away so it never shows for a frame.
@wrapMethod(CR4HudModuleRadialMenu)
function ShowRadialMenu()
{
    wrappedMethod();
    theGame.RemoveTimeScale(theGame.GetTimescaleSource(ETS_RadialMenu));
}

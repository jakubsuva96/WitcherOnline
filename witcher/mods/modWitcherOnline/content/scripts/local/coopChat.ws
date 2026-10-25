// Chat: F6 (input action WO_Chat) opens the game's text input; messages go to the on-screen log (the panel the
// combat log uses) and above the sender's head like NPC lines. The console command `chat <text>` still works.

function WO_CHAT_MAX_LENGTH() : int
{
    return 120;
}

// how long a line stays above a head: like NPC lines, longer text stays longer
function WO_ChatDuration(msg : string) : float
{
    return MinF(12.0, 4.0 + 0.08 * StrLen(msg));
}

function WO_ChatFontSize() : string
{
    return IntToString(25 + StringToInt(theGame.GetInGameConfigWrapper().GetVarValue('Hud', 'OnelinerScale')));
}

function WO_ChatLog(user : string, msg : string)
{
    if(msg == "" || msg == "reserved_string")
    {
        return;
    }
    theGame.witcherLog.AddMessage("<font color=\"#E0B050\">" + user + ":</font> " + msg);
}

// the chat travels between "_s" and "_e" words in the player packet; those can't appear inside it
function WO_ChatClean(msg : string) : string
{
    msg = StrReplaceAll(msg, "_s", "-s");
    msg = StrReplaceAll(msg, "_e", "-e");
    if(StrLen(msg) > WO_CHAT_MAX_LENGTH())
    {
        msg = StrLeft(msg, WO_CHAT_MAX_LENGTH());
    }
    return msg;
}

statemachine class r_ChatInput
{
    default autoState = 'WO_ChatIdle';

    public function Open()
    {
        if(GetCurrentStateName() != 'WO_ChatTyping')
        {
            GotoState('WO_ChatTyping');
        }
    }
}

state WO_ChatIdle in r_ChatInput
{
}

state WO_ChatTyping in r_ChatInput
{
    event OnEnterState(prevStateName : name)
    {
        super.OnEnterState(prevStateName);
        Type();
    }

    entry function Type()
    {
        var config : SVirtualKeyboardConfig;
        var text : string;

        config.titleStr = "Zpráva pro spoluhráče";
        config.defaultStr = "";
        text = theInput.OpenVirtualKeyboard(config);

        if(theGame.GetPlatform() == Platform_PC || theGame.GetPlatform() == Platform_PC_GDK)
        {
            Sleep(0.1);
            while(theInput.IsVirtualKeyboardActive())
            {
                Sleep(0.1);
            }
        }

        if(StrReplaceAll(text, " ", "") != "")
        {
            mpghosts_chat(text);
        }
        parent.GotoState('WO_ChatIdle');
    }
}

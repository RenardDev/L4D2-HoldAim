#pragma semicolon 1
#pragma newdecls required

// ================================================================
// Includes
// ================================================================

#include <sourcemod>
#include <dhooks>
#include <sdkhooks>

// ================================================================
// Info
// ================================================================

public Plugin myinfo = {
    name        = "HoldAim",
    author      = "RenardDev",
    description = "HoldAim",
    version     = "1.0.0",
    url         = "https://github.com/RenardDev/L4D2-HoldAim"
};

// ================================================================
// Constants
// ================================================================

enum {
    ANGLE_PITCH = 0,
    ANGLE_YAW = 1,
    ANGLE_ROLL = 2
};

// ================================================================
// ConVars
// ================================================================

ConVar g_ConVarEnable;
ConVar g_ConVarForceTicks;
ConVar g_ConVarForceDelta;

// ================================================================
// DHooks
// ================================================================

GameData g_hGameData;
DynamicHook g_hHookPlayerRunCommand;

int g_nHookIDPre[MAXPLAYERS + 1] = { INVALID_HOOK_ID, ... };
int g_nHookIDPost[MAXPLAYERS + 1] = { INVALID_HOOK_ID, ... };

// ================================================================
// Netvar offsets (resolved by netclass)
// ================================================================

bool g_bEyeOffsetsReady = false;
int  g_nEyePitchOffset = -1;
int  g_nEyeYawOffset = -1;
int  g_nEyeRollOffset = -1;

// ================================================================
// State
// ================================================================

float g_flEyeAnglesPre[MAXPLAYERS + 1][3];

int g_nForceUntilTick[MAXPLAYERS + 1];
float g_flForcedEyeAngles[MAXPLAYERS + 1][3];

// ================================================================
// Utils
// ================================================================

static bool IsValidClient(int nClient) {
    if ((nClient <= 0) || (nClient > MaxClients)) {
        return false;
    }

    if (!IsClientInGame(nClient) || IsFakeClient(nClient)) {
        return false;
    }

    return true;
}

static float AngleDifference(float flA, float flB) {
    float flDifference = flA - flB;

    while (flDifference > 180.0) {
        flDifference -= 360.0;
    }

    while (flDifference < -180.0) {
        flDifference += 360.0;
    }

    return flDifference;
}

static float Vector2Length(float flX, float flY) {
    return SquareRoot((flX * flX) + (flY * flY));
}

static bool ResolveEyeAnglesOffsetsForEntity(int nEntity) {
    char szNetClass[128];
    if (!GetEntityNetClass(nEntity, szNetClass, sizeof(szNetClass))) {
        return false;
    }

    int nPitch = FindSendPropInfo(szNetClass, "m_angEyeAngles[0]");
    int nYaw = FindSendPropInfo(szNetClass, "m_angEyeAngles[1]");
    int nRoll = FindSendPropInfo(szNetClass, "m_angEyeAngles[2]");

    if ((nPitch > 0) && (nYaw > 0)) {
        g_nEyePitchOffset = nPitch;
        g_nEyeYawOffset = nYaw;
        g_nEyeRollOffset = (nRoll > 0) ? nRoll : -1;
        g_bEyeOffsetsReady = true;
        return true;
    }

    int nBase = FindSendPropInfo(szNetClass, "m_angEyeAngles");
    if (nBase > 0) {
        g_nEyePitchOffset = nBase + 0;
        g_nEyeYawOffset = nBase + 4;
        g_nEyeRollOffset = nBase + 8;
        g_bEyeOffsetsReady = true;
        return true;
    }

    return false;
}

static void ForceSendEyeAngles(int nClient, const float flAngles[3]) {
    if (!g_bEyeOffsetsReady) {
        return;
    }

    SetEntDataFloat(nClient, g_nEyePitchOffset, flAngles[ANGLE_PITCH], true);
    SetEntDataFloat(nClient, g_nEyeYawOffset, flAngles[ANGLE_YAW], true);

    if (g_nEyeRollOffset > 0) {
        SetEntDataFloat(nClient, g_nEyeRollOffset, flAngles[ANGLE_ROLL], true);
    }
}

static void ResetClientState(int nClient) {
    g_nForceUntilTick[nClient] = 0;

    g_flEyeAnglesPre[nClient][ANGLE_PITCH] = 0.0;
    g_flEyeAnglesPre[nClient][ANGLE_YAW] = 0.0;
    g_flEyeAnglesPre[nClient][ANGLE_ROLL] = 0.0;

    g_flForcedEyeAngles[nClient][ANGLE_PITCH] = 0.0;
    g_flForcedEyeAngles[nClient][ANGLE_YAW] = 0.0;
    g_flForcedEyeAngles[nClient][ANGLE_ROLL] = 0.0;
}

// ================================================================
// Hook management
// ================================================================

static void UnHookClient(int nClient) {
    if ((nClient > 0) && (nClient <= MaxClients)) {
        SDKUnhook(nClient, SDKHook_PostThinkPost, Hook_PostThinkPost);
    }

    if (g_nHookIDPost[nClient] != INVALID_HOOK_ID) {
        DynamicHook.RemoveHook(g_nHookIDPost[nClient]);
        g_nHookIDPost[nClient] = INVALID_HOOK_ID;
    }

    if (g_nHookIDPre[nClient] != INVALID_HOOK_ID) {
        DynamicHook.RemoveHook(g_nHookIDPre[nClient]);
        g_nHookIDPre[nClient] = INVALID_HOOK_ID;
    }

    if ((nClient > 0) && (nClient <= MaxClients)) {
        ResetClientState(nClient);
    }
}

static void HookClient(int nClient) {
    if (!IsValidClient(nClient)) {
        return;
    }

    if (!g_bEyeOffsetsReady) {
        ResolveEyeAnglesOffsetsForEntity(nClient);
    }

    UnHookClient(nClient);

    if (g_hHookPlayerRunCommand == null) {
        return;
    }

    g_nHookIDPre[nClient] = g_hHookPlayerRunCommand.HookEntity(Hook_Pre, nClient, Hook_PlayerRunCommand_Pre);
    if (g_nHookIDPre[nClient] == INVALID_HOOK_ID) {
        LogError("Failed to hook PlayerRunCommand PRE (client=%d)", nClient);
        return;
    }

    g_nHookIDPost[nClient] = g_hHookPlayerRunCommand.HookEntity(Hook_Post, nClient, Hook_PlayerRunCommand_Post);
    if (g_nHookIDPost[nClient] == INVALID_HOOK_ID) {
        LogError("Failed to hook PlayerRunCommand POST (client=%d)", nClient);
        return;
    }

    SDKHook(nClient, SDKHook_PostThinkPost, Hook_PostThinkPost);
}

static void HookAllClients() {
    for (int nClient = 1; nClient <= MaxClients; nClient++) {
        if (IsValidClient(nClient)) {
            HookClient(nClient);
        } else {
            UnHookClient(nClient);
        }
    }
}

static void UnHookAllClients() {
    for (int nClient = 1; nClient <= MaxClients; nClient++) {
        UnHookClient(nClient);
    }
}

static void ApplyEnableState() {
    bool bEnable = g_ConVarEnable.BoolValue;

    if (bEnable) {
        HookAllClients();
        return;
    }

    UnHookAllClients();
}

// ================================================================
// ConVar change hooks
// ================================================================

public void OnConVarChanged_Enable(ConVar hConVar, const char[] szOldValue, const char[] szNewValue) {
    ApplyEnableState();
}

// ================================================================
// Plugin lifecycle
// ================================================================

public void OnPluginStart() {
    for (int i = 0; i <= MAXPLAYERS; i++) {
        g_nHookIDPre[i]  = INVALID_HOOK_ID;
        g_nHookIDPost[i] = INVALID_HOOK_ID;
        ResetClientState(i);
    }

    g_ConVarEnable = CreateConVar(
        "sm_holdaim_enable", "1",
        "Enable HoldAim (0/1)",
        FCVAR_NOTIFY, true, 0.0, true, 1.0
    );

    g_ConVarForceTicks = CreateConVar(
        "sm_holdaim_force_ticks", "3",
        "How many server ticks to force m_angEyeAngles replication after a large delta",
        FCVAR_NOTIFY, true, 1.0, true, 16.0
    );

    g_ConVarForceDelta = CreateConVar(
        "sm_holdaim_force_delta", "0.5",
        "Minimal (pitch/yaw) delta length to trigger forced replication",
        FCVAR_NOTIFY, true, 0.0, true, 180.0
    );

    AutoExecConfig(true, "holdaim");

    g_hGameData = new GameData("holdaim.l4d2");
    if (g_hGameData == null) {
        SetFailState("Failed to load gamedata: holdaim.l4d2");
    }

    g_hHookPlayerRunCommand = DynamicHook.FromConf(g_hGameData, "CBasePlayer::PlayerRunCommand");
    if (g_hHookPlayerRunCommand == null) {
        SetFailState("Failed to find function in gamedata: CBasePlayer::PlayerRunCommand");
    }

    g_ConVarEnable.AddChangeHook(OnConVarChanged_Enable);

    ApplyEnableState();
}

public void OnPluginEnd() {
    UnHookAllClients();

    if (g_hHookPlayerRunCommand != null) {
        delete g_hHookPlayerRunCommand;
    }

    if (g_hGameData != null) {
        delete g_hGameData;
    }
}

public void OnMapStart() {
    g_bEyeOffsetsReady = false;
    g_nEyePitchOffset = -1;
    g_nEyeYawOffset = -1;
    g_nEyeRollOffset = -1;

    for (int nClient = 1; nClient <= MaxClients; nClient++) {
        ResetClientState(nClient);
    }

    ApplyEnableState();
}

public void OnClientPutInServer(int nClient) {
    if (!g_ConVarEnable.BoolValue) {
        return;
    }

    HookClient(nClient);
}

public void OnClientDisconnect(int nClient) {
    UnHookClient(nClient);
}

// ================================================================
// SDKHooks callback (late, good for replication)
// ================================================================

public void Hook_PostThinkPost(int nClient) {
    if (!g_ConVarEnable.BoolValue) {
        return;
    }

    if (!IsValidClient(nClient)) {
        return;
    }

    if (!g_bEyeOffsetsReady) {
        return;
    }

    int nServerTickNow = GetGameTickCount();

    if (g_nForceUntilTick[nClient] >= nServerTickNow) {
        ForceSendEyeAngles(nClient, g_flForcedEyeAngles[nClient]);
    }
}

// ================================================================
// DHooks callbacks
// ================================================================

public MRESReturn Hook_PlayerRunCommand_Pre(int nClient, DHookReturn hReturn, DHookParam hParams) {
    if (!g_ConVarEnable.BoolValue) {
        return MRES_Ignored;
    }

    if (!IsValidClient(nClient)) {
        return MRES_Ignored;
    }

    GetClientEyeAngles(nClient, g_flEyeAnglesPre[nClient]);

    return MRES_Ignored;
}

public MRESReturn Hook_PlayerRunCommand_Post(int nClient, DHookReturn hReturn, DHookParam hParams) {
    if (!g_ConVarEnable.BoolValue) {
        return MRES_Ignored;
    }

    if (!IsValidClient(nClient)) {
        return MRES_Ignored;
    }

    if (!g_bEyeOffsetsReady) {
        if (!ResolveEyeAnglesOffsetsForEntity(nClient)) {
            return MRES_Ignored;
        }
    }

    float flEyeAnglesPost[3];
    GetClientEyeAngles(nClient, flEyeAnglesPost);

    float flDeltaPitch = AngleDifference(flEyeAnglesPost[ANGLE_PITCH], g_flEyeAnglesPre[nClient][ANGLE_PITCH]);
    float flDeltaYaw = AngleDifference(flEyeAnglesPost[ANGLE_YAW],   g_flEyeAnglesPre[nClient][ANGLE_YAW]);
    float flDeltaLen = Vector2Length(flDeltaPitch, flDeltaYaw);

    float flTrigger = g_ConVarForceDelta.FloatValue;
    if (flDeltaLen <= flTrigger) {
        return MRES_Ignored;
    }

    int nServerTickNow = GetGameTickCount();

    int nForceTicks = g_ConVarForceTicks.IntValue;
    if (nForceTicks < 1) {
        nForceTicks = 1;
    }

    int nNewUntil = nServerTickNow + nForceTicks;

    bool bAlreadyForcing = (g_nForceUntilTick[nClient] >= nServerTickNow);

    if (!bAlreadyForcing) {
        g_flForcedEyeAngles[nClient][ANGLE_PITCH] = flEyeAnglesPost[ANGLE_PITCH];
        g_flForcedEyeAngles[nClient][ANGLE_YAW] = flEyeAnglesPost[ANGLE_YAW];
        g_flForcedEyeAngles[nClient][ANGLE_ROLL] = 0.0;
    }

    if (g_nForceUntilTick[nClient] < nNewUntil) {
        g_nForceUntilTick[nClient] = nNewUntil;
    }

    return MRES_Ignored;
}

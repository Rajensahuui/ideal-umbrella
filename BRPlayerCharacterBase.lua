-- language: Lua, file: BRPlayerCharacterBase.lua
-- Guest login integrated into BRPlayerCharacterBase.
-- GuestLogin_BGMI.lua is loaded first (or required inline); this file wires its hooks
-- to the character lifecycle so a guest pawn carries its generated name, reset flag,
-- and IMSDK guest-channel state from spawn through respawn.

-- =====================================================================
-- Guest login bootstrap (inlined from GuestLogin_BGMI.lua)
-- Kept at the top so BRPlayerCharacterBase can require() it safely.
-- =====================================================================
local function ZxRLog(msg)
    pcall(print, "[ZxR] " .. tostring(msg))
end
_G.ZxRLog = ZxRLog

local function _zxr_append_native_log(msg)
    local logs = rawget(_G, "__ZxR_CPP_LOGS")
    if type(logs) ~= "table" then
        logs = {}
        _G.__ZxR_CPP_LOGS = logs
    end
    logs[#logs + 1] = "[" .. tostring(os.time() or 0) .. "] " .. tostring(msg)
    if #logs > 128 then table.remove(logs, 1) end
    _G.__ZxR_CPP_LOG_COUNT = #logs
    return true
end

_G.__ZxR_GUEST_SCRIPT_LOADED = true

local function ZxR_FlushConfigNow()
    local cfg = rawget(_G, "ZxR_ConfigState")
    if type(cfg) ~= "table" then return false end
    local ok, encoded = pcall(function()
        if type(json) == "table" and json.encode then
            return json.encode(cfg)
        end
        local parts = {}
        for k, v in pairs(cfg) do
            parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
        end
        return table.concat(parts, ";")
    end)
    if ok then
        _G.__ZxR_LastConfigDump = encoded
        return true
    end
    return false
end
_G.ZxR_FlushConfigNow = ZxR_FlushConfigNow

local function _zxr_guest_log(msg)
    _zxr_append_native_log(msg)
    local logger = rawget(_G, "ZxRLog")
    if type(logger) == "function" then
        pcall(logger, "[GuestLogin] " .. tostring(msg))
        return
    end
    pcall(print, "[ZxR][GuestLogin] " .. tostring(msg))
end

local function _zxr_seed_guest_random()
    if rawget(_G, "__ZxR_GuestRandomSeeded") == true then return end
    local seed = os.time() or 1
    local clock = os.clock and os.clock() or 0
    math.randomseed(seed + math.floor(clock * 100000))
    _G.__ZxR_GuestRandomSeeded = true
end

local function _zxr_get_guest_channel_value()
    local shareSource = rawget(_G, "ShareSource")
    if type(shareSource) == "table" and shareSource.Guest ~= nil then
        return shareSource.Guest
    end
    return "guest"
end

local function _zxr_get_guest_imsdk_channel()
    local channel = rawget(_G, "BP_ENUM_IMSDK_CHANNEL_GUEST")
    if type(channel) == "number" then return channel end
    return nil
end

local function _zxr_is_guest_login_type(loginType)
    local shareSource = rawget(_G, "ShareSource")
    if type(shareSource) == "table"
        and shareSource.Guest ~= nil
        and loginType == shareSource.Guest then
        return true
    end
    return loginType == _zxr_get_guest_channel_value()
end

local function _zxr_is_guest_imsdk_channel(channelId)
    local guestChannel = _zxr_get_guest_imsdk_channel()
    return type(channelId) == "number"
        and type(guestChannel) == "number"
        and channelId == guestChannel
end

local function _zxr_table_contains(list, value)
    if type(list) ~= "table" then return false end
    for _, currentValue in ipairs(list) do
        if currentValue == value then return true end
    end
    return false
end

local function _zxr_ensure_guest_channel_list(list)
    local guestChannel = _zxr_get_guest_channel_value()
    if type(list) ~= "table" then list = {} end
    if not _zxr_table_contains(list, guestChannel) then
        list[#list + 1] = guestChannel
        _zxr_guest_log("Injected guest channel into login list")
    end
    return list
end

local function _zxr_generate_guest_name()
    _zxr_seed_guest_random()
    local prefix = "HyperX_"
    local charset = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    local suffix = {}
    for index = 1, 6 do
        local randomIndex = math.random(1, #charset)
        suffix[#suffix + 1] = charset:sub(randomIndex, randomIndex)
    end
    local generatedName = prefix .. table.concat(suffix)
    if #generatedName > 14 then
        generatedName = generatedName:sub(1, 14)
    end
    _G.ZxR_GuestGeneratedName = generatedName
    return generatedName
end

local function _zxr_consume_guest_reset_flag(reason)
    local cfg = rawget(_G, "ZxR_ConfigState")
    if type(cfg) == "table" then cfg.guestReset = false end
    _G.ZxR_GuestResetRequested = false
    if type(rawget(_G, "MarkConfigDirty")) == "function" then
        pcall(_G.MarkConfigDirty)
    end
    if type(rawget(_G, "ZxR_FlushConfigNow")) == "function" then
        pcall(_G.ZxR_FlushConfigNow)
    end
    _zxr_guest_log("Consumed guestReset flag: " .. tostring(reason or "guest_login"))
end

local function _zxr_prepare_fresh_guest_login()
    if rawget(_G, "ZxR_GuestResetRequested") ~= true then return false end
    _G.__ZxR_GuestResetActiveAttempt = true
    pcall(function()
        if Client and Client.ClearChannelID then
            Client.ClearChannelID(NetInterface)
        end
    end)
    _zxr_guest_log("Requested fresh guest login path")
    return true
end

_G.ZxR_GetGuestGeneratedName = function()
    local currentName = rawget(_G, "ZxR_GuestGeneratedName")
    if type(currentName) == "string" and #currentName > 0 then
        return currentName
    end
    return _zxr_generate_guest_name()
end

local function _zxr_mark_guest_auto_name_pending()
    _G.ZxR_GuestGeneratedName = _zxr_generate_guest_name()
    _G.ZxR_GuestAutoNamePending = true
    _G.ZxR_GuestAutoNameExpireAt = (os.time() or 0) + 120
    _zxr_guest_log("Prepared guest auto-name: " .. tostring(_G.ZxR_GuestGeneratedName))
end

local function _zxr_is_guest_auto_name_pending()
    if rawget(_G, "ZxR_GuestAutoNamePending") ~= true then return false end
    local expiresAt = tonumber(rawget(_G, "ZxR_GuestAutoNameExpireAt")) or 0
    local now = os.time() or 0
    if expiresAt > 0 and now > expiresAt then
        _G.ZxR_GuestAutoNamePending = false
        _G.ZxR_GuestAutoNameExpireAt = 0
        return false
    end
    return true
end

-- forward decls for UI patch
local _zxr_patch_login_ui_module

local function _zxr_patch_login_module_instance(loginModule)
    if type(loginModule) ~= "table" then return false end
    if loginModule.__ZxR_GuestLoginPatched == true then return true end
    if type(loginModule.GetLoginTypeList) ~= "function" then return false end
    local originalGetLoginTypeList = loginModule.GetLoginTypeList
    loginModule.GetLoginTypeList = function(self, ...)
        local result = originalGetLoginTypeList(self, ...)
        return _zxr_ensure_guest_channel_list(result)
    end
    loginModule.__ZxR_GuestLoginPatched = true
    _zxr_guest_log("Patched login_module:GetLoginTypeList")
    return true
end

local function _zxr_try_patch_login_module()
    local okMM, ModuleManager = pcall(require, "client.module_framework.ModuleManager")
    if not okMM or not ModuleManager or not ModuleManager.GetModule
        or not ModuleManager.LobbyModuleConfig then
        return false
    end
    local okModule, loginModule = pcall(function()
        return ModuleManager.GetModule(ModuleManager.LobbyModuleConfig.login_module)
    end)
    if okModule and loginModule then
        return _zxr_patch_login_module_instance(loginModule)
    end
    return false
end

_zxr_patch_login_ui_module = function(mod)
    if type(mod) ~= "table" then return false end
    if mod.__ZxR_GuestLoginUIPatched == true then return true end
    if type(mod.UpdateLoginButtons) ~= "function"
        or type(mod.OnClickLogin) ~= "function" then
        return false
    end
    local originalUpdateLoginButtons = mod.UpdateLoginButtons
    mod.UpdateLoginButtons = function(self, ...)
        local result = originalUpdateLoginButtons(self, ...)
        self.loginChannels = _zxr_ensure_guest_channel_list(self.loginChannels)
        _zxr_guest_log("UpdateLoginButtons patched")
        return result
    end
    local originalOnClickLogin = mod.OnClickLogin
    mod.OnClickLogin = function(self, ...)
        local channel = ...
        if channel == _zxr_get_guest_channel_value() then
            pcall(_zxr_prepare_fresh_guest_login)
            _zxr_mark_guest_auto_name_pending()
            _zxr_guest_log("Guest OnClickLogin hit")
        end
        return originalOnClickLogin(self, ...)
    end
    mod.__ZxR_GuestLoginUIPatched = true
    _zxr_guest_log("Patched Login_UI guest flow")
    return true
end

local function _zxr_try_patch_login_ui_direct()
    local okUI, LoginUI = pcall(require, "client.slua.umg.NewLogin.Login_UIBP")
    if okUI and LoginUI then
        return _zxr_patch_login_ui_module(LoginUI)
    end
    return false
end

local function _zxr_patch_imsdk_interface_module(mod)
    if type(mod) ~= "table" then return false end
    if mod.__ZxR_GuestResetIMSDKPatched == true then return true end
    local patchedAny = false
    if type(mod.Login) == "function" then
        local originalLogin = mod.Login
        mod.Login = function(self, loginType, extraJson, skipLocalCacheCheck)
            if _zxr_is_guest_login_type(loginType)
                and rawget(_G, "ZxR_GuestResetRequested") == true then
                pcall(_zxr_prepare_fresh_guest_login)
                skipLocalCacheCheck = true
                _zxr_guest_log("Forced guest login to skip local cache")
            end
            if _zxr_is_guest_login_type(loginType) then
                _zxr_guest_log("IMSDK Login guest path")
            end
            return originalLogin(self, loginType, extraJson, skipLocalCacheCheck)
        end
        patchedAny = true
    end
    if type(mod.ForbidLoginWithLocalCache) == "function" then
        local originalForbid = mod.ForbidLoginWithLocalCache
        mod.ForbidLoginWithLocalCache = function(self, imsdkLoginChannelId, ...)
            if _zxr_is_guest_imsdk_channel(imsdkLoginChannelId)
                and rawget(_G, "ZxR_GuestResetRequested") == true then
                _zxr_guest_log("Forbidding guest local-cache login path")
                return true
            end
            if _zxr_is_guest_imsdk_channel(imsdkLoginChannelId) then
                _zxr_guest_log("ForbidLoginWithLocalCache guest path")
            end
            return originalForbid(self, imsdkLoginChannelId, ...)
        end
        patchedAny = true
    end
    if type(mod.OnMSDKLogin) == "function" then
        local originalOnMSDKLogin = mod.OnMSDKLogin
        mod.OnMSDKLogin = function(self, ...)
            local result = originalOnMSDKLogin(self, ...)
            if rawget(_G, "__ZxR_GuestResetActiveAttempt") == true then
                _G.__ZxR_GuestResetActiveAttempt = false
                pcall(_zxr_consume_guest_reset_flag, "imsdk_login_success")
            end
            return result
        end
        patchedAny = true
    end
    if not patchedAny then return false end
    mod.__ZxR_GuestResetIMSDKPatched = true
    _zxr_guest_log("Patched IMSDK guest reset flow")
    return true
end

local function _zxr_try_patch_imsdk_interface()
    local okDirect, direct = pcall(require, "client.logic.login.logic_imsdk_interface")
    if okDirect and direct then
        return _zxr_patch_imsdk_interface_module(direct)
    end
    if type(package) ~= "table"
        or type(package.loaded) ~= "table" then
        return false
    end
    direct = package.loaded["client.logic.login.logic_imsdk_interface"]
    return _zxr_patch_imsdk_interface_module(direct)
end

local function _zxr_patch_revise_name_module(mod)
    if type(mod) ~= "table" then return false end
    if mod.__ZxR_GuestRenamePatched == true then return true end
    if type(mod.OnShow) ~= "function"
        or type(mod.RealModifyName) ~= "function" then
        return false
    end
    local originalOnShow = mod.OnShow
    mod.OnShow = function(self, ...)
        local result = originalOnShow(self, ...)
        if self and self._modifyType == 0 and _zxr_is_guest_auto_name_pending() then
            local generatedName = _G.ZxR_GetGuestGeneratedName()
            self._roleName = generatedName
            if self.UIRoot and self.UIRoot.EditableText_0
                and self.UIRoot.EditableText_0.SetText then
                pcall(function()
                    self.UIRoot.EditableText_0:SetText(generatedName)
                end)
            end
            if self._UpdatePanel then pcall(self._UpdatePanel, self) end
            _G.ZxR_GuestAutoNamePending = false
            _G.ZxR_GuestAutoNameExpireAt = 0
            _zxr_guest_log("Prefilled guest name: " .. tostring(generatedName))
        end
        return result
    end
    mod.__ZxR_GuestRenamePatched = true
    _zxr_guest_log("Patched revise_name guest prefill flow")
    return true
end

local function _zxr_try_patch_loaded_revise_name()
    local okDirect, direct = pcall(require, "client.slua.umg.WarDrobe.revise_name")
    if okDirect and _zxr_patch_revise_name_module(direct) then return true end
    if type(package) ~= "table" or type(package.loaded) ~= "table" then return false end
    direct = package.loaded["revise_name"]
    if _zxr_patch_revise_name_module(direct) then return true end
    for loadedName, loadedModule in pairs(package.loaded) do
        if type(loadedName) == "string"
            and string.find(loadedName, "revise_name", 1, true) then
            if _zxr_patch_revise_name_module(loadedModule) then return true end
        end
    end
    return false
end

local function _zxr_try_patch_loaded_modules()
    local patchedAny = false
    if _zxr_try_patch_login_module() then patchedAny = true end
    if _zxr_try_patch_login_ui_direct() then patchedAny = true end
    if _zxr_try_patch_loaded_revise_name() then patchedAny = true end
    if _zxr_try_patch_imsdk_interface() then patchedAny = true end
    if patchedAny then _zxr_guest_log("Guest hooks installed") end
    return patchedAny
end

_G.ZxR_TryInstallGuestLoginHooks = function()
    return _zxr_try_patch_loaded_modules()
end

pcall(function()
    local okTicker, ticker = pcall(require, "common.time_ticker")
    if okTicker and ticker and ticker.AddTimerLoop then
        ticker.AddTimerLoop(0, function()
            pcall(_zxr_try_patch_loaded_modules)
        end, -1, 1.0)
    else
        pcall(_zxr_try_patch_loaded_modules)
    end
end)

-- =====================================================================
-- BRPlayerCharacterBase — original body, plus guest integration
-- =====================================================================

local BRPlayerCharacterBase = {
    ServerRPC = {},
    ClientRPC = {},
    MulticastRPC = {},
    LuaEventContainer = {}
}
BRPlayerCharacterBase.ServerRPC.ServerRPC_NearDeathGiveupRescue = {
    Reliable = true,
    Params = {}
}
BRPlayerCharacterBase.ServerRPC.ServerRPC_CarryDeadBox = {
    Reliable = true,
    Params = { UEnums.EPropertyClass.Object }
}
BRPlayerCharacterBase.ServerRPC.RPC_Server_GmPlayAction = {
    Reliable = true,
    Params = { UEnums.EPropertyClass.Int }
}
BRPlayerCharacterBase.MulticastRPC.MulticastRPC_GmPlayAction = {
    Reliable = true,
    Params = { UEnums.EPropertyClass.Int }
}
BRPlayerCharacterBase.ClientRPC.RPC_Client_SetShouldCheckPassWall = {
    Reliable = true,
    Params = { UEnums.EPropertyClass.Bool }
}

local ENetRole = import("ENetRole")
local EPawnState = import("EPawnState")
local ECharacterHideMovementAcive = import("ECharacterHideMovementAcive")
local ESpecialMovementType = import("ESpecialMovementType")
local ESpiderSwingMoveState = import("ESpiderSwingMoveState")
local ESurviveWeaponPropSlot = import("ESurviveWeaponPropSlot")
local EParachuteState = import("EParachuteState")
local EMovementMode = import("EMovementMode")
local EStateType = import("EStateType")
local ESTEPoseState = import("ESTEPoseState")
local EGameModeType = import("EGameModeType")
local STExtraGameStateBase = import("STExtraGameStateBase")
local UKismetSystemLibrary = import("KismetSystemLibrary")
local USTExtraBlueprintFunctionLibrary = import("STExtraBlueprintFunctionLibrary")
local GameplayData = require("GameLua.GameCore.Data.GameplayData")
local GamePlayTools = require("GameLua.Mod.BaseMod.Common.GamePlayTools")
local MatchModeIds = require("GameLua.Mod.BaseMod.GamePlay.Config.MatchModeIdsConfig")

-- guest module handle (set lazily)
local _ZxR_GuestHooksInstalled = false

function BRPlayerCharacterBase:ctor()
end

function BRPlayerCharacterBase:_PostConstruct()
    BRPlayerCharacterBase.__super._PostConstruct(self)
    self:InitAddSpecialMoveInfo()
    self.bCanNearDeathGiveup = true
    -- guest identity carries on the pawn
    self.bZxRGuestPawn = false
    self.ZxRGuestName = nil
    print(bWriteLog and "BRPlayerCharacterBase:_PostConstruct bCanNearDeathGiveup true")
end

-- Guest hooks: install once per process, from the first pawn that begins play.
-- Safe to call repeatedly — _zxr_try_patch_loaded_modules is idempotent.
function BRPlayerCharacterBase:ZxR_EnsureGuestLoginHooks()
    if _ZxR_GuestHooksInstalled then return true end
    local installer = rawget(_G, "ZxR_TryInstallGuestLoginHooks")
    if type(installer) ~= "function" then
        -- GuestLogin_BGMI.lua not loaded yet; try requiring it by canonical path.
        local ok, err = pcall(require, "GameLua.Mod.BRMod.GuestLogin_BGMI")
        if not ok then
            pcall(function()
                local fallback = rawget(_G, "ZxRLog")
                if type(fallback) == "function" then
                    fallback("[GuestLogin] require failed: " .. tostring(err))
                end
            end)
            return false
        end
        installer = rawget(_G, "ZxR_TryInstallGuestLoginHooks")
        if type(installer) ~= "function" then return false end
    end
    local ok, result = pcall(installer)
    if ok then
        _ZxR_GuestHooksInstalled = true
        return true
    end
    return false
end

-- Mark this pawn as a guest pawn and bind the generated guest name to it.
-- Call from login flow / spawn flow when the guest channel is selected.
function BRPlayerCharacterBase:ZxR_ApplyGuestIdentity(optionalName)
    self.bZxRGuestPawn = true
    if type(optionalName) == "string" and #optionalName > 0 then
        self.ZxRGuestName = optionalName
        _G.ZxR_GuestGeneratedName = optionalName
    else
        local getter = rawget(_G, "ZxR_GetGuestGeneratedName")
        if type(getter) == "function" then
            self.ZxRGuestName = getter()
        else
            self.ZxRGuestName = nil
        end
    end
    print(bWriteLog and string.format(
        "BRPlayerCharacterBase:ZxR_ApplyGuestIdentity PlayerKey=%s GuestName=%s",
        tostring(self.PlayerKey), tostring(self.ZxRGuestName)
    ))
    return self.ZxRGuestName
end

function BRPlayerCharacterBase:ZxR_IsGuest()
    return self.bZxRGuestPawn == true
end

function BRPlayerCharacterBase:ZxR_GetGuestName()
    return self.ZxRGuestName
end

-- Request a fresh guest login: sets the reset flag consumed by the IMSDK hook
-- and clears channel ID so the next login path is treated as new.
function BRPlayerCharacterBase:ZxR_RequestGuestReset()
    _G.ZxR_GuestResetRequested = true
    local cfg = rawget(_G, "ZxR_ConfigState")
    if type(cfg) == "table" then cfg.guestReset = true end
    local flush = rawget(_G, "ZxR_FlushConfigNow")
    if type(flush) == "function" then pcall(flush) end
    print(bWriteLog and "BRPlayerCharacterBase:ZxR_RequestGuestReset flag set")
    return true
end

function BRPlayerCharacterBase:ReceiveBeginPlay()
    BRPlayerCharacterBase.__super.ReceiveBeginPlay(self)

    -- install guest login hooks as early as the first pawn appears
    self:ZxR_EnsureGuestLoginHooks()

    self:AddControlEvent(self, "MovementModeChangedDelegate", self.HandleOnMovementModeChangedNew, self)

    if self:HasAuthority() and self:CheckAddCheckFallingDistanceComponent() then
        local CheckFallingDistanceComponent_C = import("CheckFallingDistanceComponent")
        if slua.isValid(CheckFallingDistanceComponent_C)
            and not slua.isValid(self:GetComponentByClass(CheckFallingDistanceComponent_C)) then
            print(bWriteLog and "BRPlayerCharacterBase:ReceiveBeginPlay Add CheckFallingDistanceComponent")
            Game:AddComponent(CheckFallingDistanceComponent_C, self, "CheckFallingDistanceComponent")
        end
    end

    if slua.isValid(self.STCharacterMovement) then
        self.STCharacterMovement.bPositiveBlowUp = true
    end

    if self.Role == ENetRole.ROLE_AutonomousProxy then
        self:AddControlEvent(self, "OnPawnStateDisabled", self.OnPawnStateChange, self)
        self:AddControlEvent(self, "OnPawnStateEnabled", self.OnPawnStateChange, self)
        self:AddControlEventConditionOnly(self, "OnAttrChangeEventDelegate", {
            AttrName = { "bCanSelfRescue" }
        }, self.CharacterAttrChangeEvent, self)
    end

    if Client then
        printf(bWriteLog and "BRPlayerCharacterBase:ReceiveBeginPlay, PlayerKey:%u ", self.PlayerKey)
        GameplayData.AddCharacter(self.Object)
        -- guest pawn marker for client-side UI
        if self:ZxR_IsGuest() then
            local uPlayerController = self:GetPlayerControllerSafety()
            if slua.isValid(uPlayerController) then
                uPlayerController:BroadcastUIMessage("UIMsg_ZxRGuestIdentity", 0,
                    tostring(self.ZxRGuestName or ""), "")
            end
        end
    else
        self:AddCommonEventWithConditions(EVENTTYPE_INGAME_NORMAL, EVENTID_GAME_MODE_STATE_CHANGE, {
            [1] = "FinishedState"
        }, self.HandleFinishedState, self)
        self:AddControlEvent(self, "OnPawnRespawnDelegate", self.OnRespawnRehideCheck, self)
    end
end

function BRPlayerCharacterBase:CharacterAttrChangeEvent(uPawn, AttrName, AttrVal)
    BRPlayerCharacterBase.__super.CharacterAttrChangeEvent(self, uPawn, AttrName, AttrVal)
    if self.Object ~= uPawn then return end
    if self.Role == ENetRole.ROLE_AutonomousProxy and AttrName == "bCanSelfRescue" then
        local uPlayerController = self:GetPlayerControllerSafety()
        if slua.isValid(uPlayerController) then
            uPlayerController:BroadcastUIMessage("UIMsg_CanSelfRescue", 0, "", "")
        end
    end
end

function BRPlayerCharacterBase:OnPawnStateChange(PawnState)
    print("BRPlayerCharacterBase:OnPawnStateChange:", PawnState)
    if PawnState == EPawnState.SwitchPP then
        local uPlayerController = self:GetPlayerControllerSafety()
        if slua.isValid(uPlayerController) then
            uPlayerController:BroadcastUIMessage("UIMsg_FPPModeChange", 0, "", "")
        end
    end
end

function BRPlayerCharacterBase:HandleFinishedState()
    print(bWriteLog and "BRPlayerCharacterBase:HandleFinishedState", self.STCharacterMovement)
    if slua.isValid(self.STCharacterMovement) and self.STCharacterMovement.SetDynamicSimpleQueryConfigDisable then
        local EDynamicSimpleQueryConfigDisableMask = import("EDynamicSimpleQueryConfigDisableMask")
        self.STCharacterMovement:SetDynamicSimpleQueryConfigDisable(
            EDynamicSimpleQueryConfigDisableMask.Bit0, true)
    end
end

function BRPlayerCharacterBase:OnRespawnRehideCheck()
    if not self:GetEnsure() then return end
    self:AddGameTimer(0.5, false, function()
        if not slua.isValid(self.Object) then return end
        if self:HasState(EPawnState.InPlane) then
            self:SetCharacterHideInGame(true, true, true, 1, ECharacterHideMovementAcive.Normal)
            print(bWriteLog and "BRPlayerCharacterBase:OnRespawnRehideCheck re-hide AI on plane, PlayerKey:", self.PlayerKey)
        end
    end)
end

function BRPlayerCharacterBase:CheckAddCheckFallingDistanceComponent()
    if CGameMode and CGameMode.GameModeType and CGameState and CGameState.GameModeID then
        local GameModeType = CGameMode.GameModeType
        local GameModeID = tonumber(CGameState.GameModeID)
        local bModeTypeSatisfy = GameModeType == EGameModeType.ETypicalGameMode
            or GameModeType == EGameModeType.EFourInOneGameMode
            or GameModeType == EGameModeType.EHeavyWeaponGameMode
        local bModeIDSatisfy = MatchModeIds[GameModeID] - self
        print(bWriteLog and bWriteLog and "BRPlayerCharacterBase:CheckAddCheckFallingDistanceComponent:",
            GameModeType, GameModeID, bModeTypeSatisfy, bModeIDSatisfy)
        return bModeTypeSatisfy and bModeIDSatisfy
    end
    return false
end

function BRPlayerCharacterBase:LuaHandleParachuteStateChanged(LastParachuteState, NewParachuteState)
    BRPlayerCharacterBase.__super.LuaHandleParachuteStateChanged(self, LastParachuteState, NewParachuteState)
    if not Client then
        local uCurrentPlayerControl = self:GetPlayerControllerSafety()
        if slua.isValid(uCurrentPlayerControl) and uCurrentPlayerControl.CheckParachuteOpenFeature then
            if NewParachuteState == EParachuteState.PS_Opening then
                if uCurrentPlayerControl.CheckParachuteOpenFeature.SatrtCheckShowParachuteCloseUI then
                    uCurrentPlayerControl.CheckParachuteOpenFeature:SatrtCheckShowParachuteCloseUI()
                end
            elseif NewParachuteState == EParachuteState.PS_None then
                if uCurrentPlayerControl.CheckParachuteOpenFeature.RecoverParachuteOpenParam then
                    uCurrentPlayerControl.CheckParachuteOpenFeature:RecoverParachuteOpenParam()
                end
                if uCurrentPlayerControl.CheckParachuteOpenFeature.ClearTimerAndState then
                    uCurrentPlayerControl.CheckParachuteOpenFeature:ClearTimerAndState()
                end
            end
        end
    end
end

function BRPlayerCharacterBase:OnLanded()
    printf("BRPlayerCharacterBase:OnLanded PlayerKey:%d", self.PlayerKey)
    if self.HandleOnLanded then self:HandleOnLanded(-1) end
    if not Client then
        local uCurrentPlayerControl = self:GetPlayerControllerSafety()
        if slua.isValid(uCurrentPlayerControl) and uCurrentPlayerControl.CheckParachuteOpenFeature then
            if uCurrentPlayerControl.CheckParachuteOpenFeature.ClearTimerAndState then
                uCurrentPlayerControl.CheckParachuteOpenFeature:ClearTimerAndState()
            end
            if uCurrentPlayerControl.CheckParachuteOpenFeature.ResetCheckShowUI then
                uCurrentPlayerControl.CheckParachuteOpenFeature:ResetCheckShowUI()
            end
        end
    end
end

function BRPlayerCharacterBase:ReceiveEndPlay(EndPlayReason)
    BRPlayerCharacterBase.__super.ReceiveEndPlay(self, EndPlayReason)
    if Client then
        GameplayData.RemoveCharacter(self.Object)
    end
end

function BRPlayerCharacterBase:IsWarGameMode()
    local uGameState = GameplayData:GetGameState()
    if slua.isValid(uGameState) and Game:IsClassOf(uGameState, STExtraGameStateBase) then
        return uGameState.GameModeType == EGameModeType.EWarGameMode
    end
    return false
end

function BRPlayerCharacterBase:BPOnRecycled()
    print(bWriteLog and string.format("%s BPOnRecycled()", Game:GetPlainName(self.Object)))
    if Client then self:ResetMeshRelativeLocationAndRotation() end
end

function BRPlayerCharacterBase:BPOnRespawned()
    print(bWriteLog and string.format("%s BPOnRespawned()", Game:GetPlainName(self.Object)))
    if Client then self:ResetMeshRelativeLocationAndRotation() end
end

function BRPlayerCharacterBase:ReceiveOnRecycle()
    print(bWriteLog and string.format("%s IReusable:ReceiveOnRecycle()", Game:GetPlainName(self.Object)))
    if Client then
        self:ResetMeshRelativeLocationAndRotation()
        GameplayData.RemoveCharacter(self.Object)
    end
end

function BRPlayerCharacterBase:ReceiveOnSpawn()
    print(bWriteLog and string.format("%s IReusable:ReceiveOnSpawn()", Game:GetPlainName(self.Object)))
    if Client then
        self:ResetMeshRelativeLocationAndRotation()
        GameplayData.AddCharacter(self.Object)
    end
end

function BRPlayerCharacterBase:ResetMeshRelativeLocationAndRotation()
    if Game:IsValid(self.Object) and Game:IsValid(self.Mesh) then
        local uDefaultMeshRot = FRotator(0, -90, 0)
        local uDefaultMeshRelativeLoc = FVector(0, 0, 0)
        if self.Mesh.K2_SetRelativeRotation then
            self.Mesh:K2_SetRelativeRotation(uDefaultMeshRot, false, nil, false)
        end
        self:CacheInitialMeshOffset(uDefaultMeshRelativeLoc, uDefaultMeshRot)
        local vRelativeRot = self.Mesh.RelativeRotation
        local vBaseRotationOffset = self.BaseRotationOffset
        local vBaseRotation = Game:QuatToRotator(vBaseRotationOffset)
        print(bWriteLog and bWriteLog and string.format(
            "%s ResetMeshRelativeLocationAndRotation() Mesh.RelativeRotation: %s %s %s   Pawn.BaseRotationOffset:%s %s %s ",
            Game:GetPlainName(self.Object),
            tostring(vRelativeRot.Pitch), tostring(vRelativeRot.Yaw), tostring(vRelativeRot.Roll),
            tostring(vBaseRotation.Pitch), tostring(vBaseRotation.Yaw), tostring(vBaseRotation.Roll)))
    end
end

function BRPlayerCharacterBase:HandleOnMovementModeChangedNew()
    print(bWriteLog and "BRPlayerCharacterBase:HandleOnMovementModeChanged11")
    if Game:IsValid(self.STCharacterMovement)
        and self.STCharacterMovement.MovementMode == EMovementMode.MOVE_Swimming        and self:CheckBaseIsMoveable() then
        print(bWriteLog and "BRPlayerCharacterBase:HandleOnMovementModeChanged22")
        self.CharacterMovement:SetBase(nil, "", true)
    end
    if self.Role == ENetRole.ROLE_AutonomousProxy
        and Game:IsValid(self.STCharacterMovement)
        and self.STCharacterMovement.MovementMode == EMovementMode.MOVE_Walking
        and UIManager.UI_Config_InGame.ParachuteOpenUI then
        print(bWriteLog and "BRPlayerCharacterBase:HandleOnMovementModeChangedNew CloseUI")
        UIManager.CloseUI(UIManager.UI_Config_InGame.ParachuteOpenUI)
    end
end

function BRPlayerCharacterBase:BPOnMissPlayerDamageRecord()
end

function BRPlayerCharacterBase:PreAttachedToVehicle()
    local IsDS = UKismetSystemLibrary.IsDedicatedServer(self)
    if not IsDS then return end
    local MainPlayerController = self:GetPlayerControllerSafety()
    if not slua.isValid(MainPlayerController) then return end
    local CharacterAvatarComp2_BP = self.CharacterAvatarComp2_BP
    if not slua.isValid(CharacterAvatarComp2_BP) then return end
    local CommerAvatarDataUtil = require("GameLua.Activity.Commercialize.GamePlay.CommerAvatarDataUtil")
    local changedVehicleId = CommerAvatarDataUtil:ChangeVehicleSkinByClothes(MainPlayerController, CharacterAvatarComp2_BP)
    local ESTExtraVehicleShapeType = import("ESTExtraVehicleShapeType")
    if changedVehicleId then
        local UAvatarUtils = import("AvatarUtils")
        if UAvatarUtils.GetVehicleShapeBySkinID(changedVehicleId) == ESTExtraVehicleShapeType.VST_Horse then
            local uCurPlayerState = self:GetPlayerStateSafety()
            if slua.isValid(uCurPlayerState) then
                print(bWriteLog and "  BRPlayerCharacterBase:PreAttachedToVehicle. changedVehicleId: " % tostring(changedVehicleId))
                uCurPlayerState:AddGeneralCount(468, 1, false)
            end
        end
    end
end

function BRPlayerCharacterBase:ParachuteJump()
    local uPlayerController = self:GetControllerSafety()
    if slua.isValid(uPlayerController) then
        if not self:GetEnsure() then
            if uPlayerController:GetCurrentStateType() ~= EStateType.State_ParachuteJump
                and uPlayerController:GetCurrentStateType() ~= EStateType.State_ParachuteOpen then
                self:SwitchPoseState(ESTEPoseState.Stand, true, true, true, false)
                uPlayerController:ReInitParachuteItem()
                uPlayerController:ServerChangeStatePC(EStateType.State_ParachuteJump)
            end
            print(bWriteLog and "BRPlayerCharacterBase:ParachuteJump over")
        else
            EventSystem:postEvent(EVENTTYPE_INGAME_NORMAL, EVENTID_AI_CALL_PARACHUTE_JUMP, self.Object)
            print(bWriteLog and "BRPlayerCharacterBase:ParachuteJump AI JUMP over, Loc=", tostring(self:K2_GetActorLocation():ToString()))
        end
    end
end

function BRPlayerCharacterBase:OnMovementBaseChangedEvent(uCharacter, uNewMovementBase, uOldMovementBase)
    if uCharacter ~= self.Object then return end
    print(bWriteLog and string.format("BRPlayerCharacterBase:OnMovementBaseChangedEvent %s, Base: %s -> %s",
        uCharacter, uOldMovementBase, uNewMovementBase))
    local MedievalCrane = self:GetMedievalCraneFromBase(uNewMovementBase)
    if MedievalCrane and MedievalCrane.AddCharacter then
        MedievalCrane:AddCharacter(self.Object)
    else
        MedievalCrane = self:GetMedievalCraneFromBase(uOldMovementBase)
        if MedievalCrane and MedievalCrane.RemoveCharacter then
            MedievalCrane:RemoveCharacter(self.Object)
        end
    end
end

function BRPlayerCharacterBase:GetMedievalCraneFromBase(Base)
    if not slua.isValid(Base) or not Base.GetOwner then return end
    local Lifter = Base:GetOwner()
    if not slua.isValid(Lifter) then return end
    if not Lifter.AddCharacter then return end
    return Lifter
end

function BRPlayerCharacterBase:CheckForbidFlaregun()
    local uPlayerState = self:GetPlayerStateSafety()
    if not slua.isValid(uPlayerState) then return false end
    if uPlayerState.CanUseFlaregun == false and self:IsLocallyControlled() then
        local uPlayerController = self:GetPlayerControllerSafety()
        if slua.isValid(uPlayerController) then
            uPlayerController:DisplayGameTipWithMsgID(48532)
        end
    end
    return uPlayerState.CanUseFlaregun - self
end

function BRPlayerCharacterBase:ServerRPC_NearDeathGiveupRescue()
    self:HandleNearDeathGiveupRescue()
end

function BRPlayerCharacterBase:HandleNearDeathGiveupRescue()
    local uNearDeathComp = self.NearDeatchComponent
    if self:IsNearDeath() and slua.isValid(uNearDeathComp) and self.bCanNearDeathGiveup == true then
        local uPlayerState = self:GetPlayerStateSafety()
        if slua.isValid(uPlayerState) then
            uPlayerState:AddGeneralCount(1613, 1, false)
        end
        uNearDeathComp:TriggerGotoDieExplictly(self.Object)
    end
end

function BRPlayerCharacterBase:RPC_Server_GmPlayAction(actionId)
    log(bWriteLog and "  BRPlayerCharacterBase:RPC_Server_GmPlayAction.  actionId: " % tostring(actionId))
    if USTExtraBlueprintFunctionLibrary.IsDevelopment() then
        log(bWriteLog and "  BRPlayerCharacterBase:RPC_Server_GmPlayAction. IsDevelopment actionId: " % tostring(actionId))
        self:MulticastRPC_GmPlayAction(actionId)
    end
end

function BRPlayerCharacterBase:MulticastRPC_GmPlayAction(actionId)
    if not Client then return end
    log(bWriteLog and "  BRPlayerCharacterBase:MulticastRPC_GmPlayAction.  actionId: " % tostring(actionId))
    local uPlayEmoteComp = self:GetPlayEmoteComponent()
    if not slua.isValid(uPlayEmoteComp) then return end
    local LogFilter = require("common.log_filter")
    LogFilter.SetLogTreeEnable(true)
    local animCfg = CDataTable.GetTableData("EmoteBPTable", actionId)
    if not animCfg then return end
    local handlePath = animCfg.Path
    local EmoteHandleAsset = slua.loadObject(handlePath)
    local assetsArray = slua.Array(UEnums.EPropertyClass.Struct,
        import("/Script/CoreUObject.SoftObjectPath"))
    local handle = EmoteHandleAsset()
    uPlayEmoteComp:OnLoadEmoteAssetBegin(handle, actionId, assetsArray, "")
    log(bWriteLog and "  BRPlayerCharacterBase:MulticastRPC_GmPlayAction. assetsArray:Num(): " % tostring(assetsArray:Num()))
    local tb = FuncUtil.LuaArrayToTable(assetsArray)
    local asset_util = require("common.asset_util")
    local function loadLater()
        uPlayEmoteComp:OnLoadEmoteAssetEnd(handle, actionId, 0)
    end
    asset_util.GetAssetsArrayAsyncParallel(tb, loadLater)
end

function BRPlayerCharacterBase:RPC_Client_SetShouldCheckPassWall(bServerSyncShouldCheckPassWall)
    print(bWriteLog and "BRPlayerCharacterBase:RPC_Client_SetShouldCheckPassWall " % tostring(bServerSyncShouldCheckPassWall))
    if slua.isValid(self.ParachuteComponent) then
        self.ParachuteComponent.bServerSyncShouldCheckPassWall = bServerSyncShouldCheckPassWall
    end
end

function BRPlayerCharacterBase:OnPlayerEnterCarryBoxState()
    self.Super:OnPlayerEnterCarryBoxState()
    local CharName = self:GetPlayerNameSafety()
    print(bWriteLog and string.format("DeadBoxLog BRPlayerCharacterBase:OnPlayerEnterCarryBoxState Role:%s PlayerKey:%s Name:%s",
        tostring(self.Role), tostring(self.PlayerKey), tostring(CharName)))
    if self.CarryDeadBoxFeature then
        self.CarryDeadBoxFeature:OnPlayerEnterCarryBoxState()
    end
end

function BRPlayerCharacterBase:OnPlayerLeaveCarryBoxState(bInIsInterrupt)
    self.Super:OnPlayerLeaveCarryBoxState(bInIsInterrupt)
    local CharName = self:GetPlayerNameSafety()
    print(bWriteLog and string.format("DeadBoxLog BRPlayerCharacterBase:OnPlayerLeaveCarryBoxState Role:%s PlayerKey:%s Name:%s bInIsInterrupt:%s",
        tostring(self.Role), tostring(self.PlayerKey), tostring(CharName), tostring(bInIsInterrupt)))
    if self.CarryDeadBoxFeature then
        self.CarryDeadBoxFeature:OnPlayerLeaveCarryBoxState(bInIsInterrupt)
    end
end

function BRPlayerCharacterBase:ServerRPC_CarryDeadBox(uInDeadBox)
    if slua.isValid(uInDeadBox)
        and Game:IsClassOf(uInDeadBox, import("/Script/ShadowTrackerExtra.PlayerTombBox"))
        and self.CarryDeadBoxFeature then
        self.CarryDeadBoxFeature:CarryDeadBox(uInDeadBox)
    end
end

function BRPlayerCharacterBase:SetAreaID(AreaID)
    self:SetAttrValue("AreaID", AreaID, -1)
end

function BRPlayerCharacterBase:GetAreaID()
    return math.floor(self:GetAttrValue("AreaID") + 0.5)
end

function BRPlayerCharacterBase:CannotChangeIntoPetSpectator()
    print(bWriteLog and "BRPlayerCharacterBase:CannotChangeIntoPetSpectator")
    return self.bCannotChangeIntoPetSpectator
end

function BRPlayerCharacterBase:DoModChangeToBT()
    print(bWriteLog and string.format("BRPlayerCharacterBase:DoModChangeToBT, PlayerKey=%s", tostring(self.PlayerKey)))
    if self:HasState(EPawnState.SpecialSuit) then
        self:TriggerEntrySkillWithID(4301101, true)
        print(bWriteLog and string.format("BRPlayerCharacterBase:DoModChangeToBT, PlayerKey=%s, HasState(EPawnState.SpecialSuit)",
            tostring(self.PlayerKey)))
    end
end

function BRPlayerCharacterBase:SwitchCameraToParachuteOpening()
    print(bWriteLog and "BRPlayerCharacterBase:SwitchCameraToParachuteOpening")
    self.Super:SwitchCameraToParachuteOpening()
    if self.ParachuteFormation and self.ParachuteFormation.ShouldApplyFormationCamera
        and self.ParachuteFormation:ShouldApplyFormationCamera() then
        self.ParachuteFormation:OverlayFormationCameraParams()
        print(bWriteLog and "BRPlayerCharacterBase:SwitchCameraToParachuteOpening - Formation camera overlaid")
    end
end

function BRPlayerCharacterBase:SwitchCameraToParachuteFalling()
    print(bWriteLog and "BRPlayerCharacterBase:SwitchCameraToParachuteFalling")
    self.Super:SwitchCameraToParachuteFalling()
    if self.ParachuteFormation and self.ParachuteFormation.ShouldApplyFormationCamera
        and self.ParachuteFormation:ShouldApplyFormationCamera() then
        self.ParachuteFormation:OverlayFormationCameraParams()
        print(bWriteLog and "BRPlayerCharacterBase:SwitchCameraToParachuteFalling - Formation camera overlaid")
    end
end

function BRPlayerCharacterBase:SwitchCameraToNormal()
    print(bWriteLog and "BRPlayerCharacterBase:SwitchCameraToNormal")
    self.Super:SwitchCameraToNormal()
    if self.ParachuteFormation and self.ParachuteFormation.OnLandingClearFormationCamera then
        self.ParachuteFormation:OnLandingClearFormationCamera()
    end
end

function BRPlayerCharacterBase:SwitchWeaponCheck(Slot, IgnoreState)
    if self:HasState(EPawnState.AttachToOther) then
        local Weapon = self:GetWeaponBySlot(Slot)
        if slua.isValid(Weapon) then
            local WeaponID = Weapon:GetWeaponID()
            local AttachToOtherConfig = GamePlayTools.GetCurrentConfig("AttachToOtherConfig")
            if AttachToOtherConfig and AttachToOtherConfig.CheckIsWeaponInBlackList
                and AttachToOtherConfig.CheckIsWeaponInBlackList(WeaponID) then
                print(bWriteLog and "BRPlayerCharacterBase:SwitchWeaponCheck not allow switch weapon in AttachToOther, WeaponID: " % tostring(WeaponID))
                local uPlayerController = self:GetPlayerControllerSafety()
                if Client and slua.isValid(uPlayerController)
                    and uPlayerController.Role == ENetRole.ROLE_AutonomousProxy then
                    uPlayerController:DisplayGameTipWithMsgID(47306)
                end
                return false
            end
        end
    end
    if self:HasState(EPawnState.WebSwing) and Slot ~= ESurviveWeaponPropSlot.SWPS_None
        and slua.isValid(self.STCharacterMovement) then
        local SpiderSwingObj = self.STCharacterMovement:GetSpecialMoveObjBySpecialMoveType(
            ESpecialMovementType.SPECIAL_MOVE_SpiderSwing)
        if slua.isValid(SpiderSwingObj) then
            local nCurState = SpiderSwingObj:GetCurMoveState()
            if nCurState == ESpiderSwingMoveState.Launching
                or nCurState == ESpiderSwingMoveState.Swinging then
                print(bWriteLog and "BRPlayerCharacterBase:SwitchWeaponCheck blocked by SpiderSwing state: " % tostring(nCurState))
                return false
            end
        end
    end
    return self.Super:SwitchWeaponCheck(Slot, IgnoreState)
end

local VICTORY_DANCE_FX_MAP = {
    [12219601] = 22010089
}
local PublishRegionMacros = require("client.slua.config.ClientMacros.PublishRegionMacros")
local isFitVersion = PublishRegionMacros.IsFITVersion()

local function ResolveEmoteResID(ItemID)
    local FxID = VICTORY_DANCE_FX_MAP[ItemID]
    if not FxID or FxID == ItemID then return ItemID end
    local model_util = require("client.common.model_util")
    local FxBPID = model_util.GetBPID(FxID)
    local ResID = ItemID
    if FxBPID and 0 < FxBPID
        and model_util.IsBattleItemHandleExist("Emote", FxBPID, false, false) then
        ResID = FxID
    end
    print(bWriteLog and string.format("BRPlayerCharacterBase 11 ResolveEmoteResID ItemID:%s, FxID:%s, FxBPID:%s, ResID:%s",
        tostring(ItemID), tostring(FxID), tostring(FxBPID), tostring(ResID)))
    if isFitVersion and ResID == 12219601 then
        print(bWriteLog and "BRPlayerCharacterBase ResolveEmoteResID 12219601 to 12222069")
        return 12222069
    end
    return ResID
end

function BRPlayerCharacterBase:GetEmoteHandlePath(ItemID)
    local ResID = ResolveEmoteResID(ItemID)
    if self.Super then return self.Super:GetEmoteHandlePath(ResID) end
    local model_util = require("client.common.model_util")
    local BPID = model_util.GetBPID(ResID)
    if not BPID or BPID <= 0 then return "" end
    return model_util.GetPath("Emote", BPID, false, false) or ""
end

function BRPlayerCharacterBase:GetEmoteHandle(ItemID)
    local ResID = ResolveEmoteResID(ItemID)
    if self.Super then return self.Super:GetEmoteHandle(ResID) end
    local model_util = require("client.common.model_util")
    local BPID = model_util.GetBPID(ResID)
    if not BPID or BPID <= 0 then return nil end
    local HandleClass = model_util.GetClass("Emote", BPID, false, false)
    if not HandleClass then return nil end
    local Handle = HandleClass()
    if not slua.isValid(Handle) then return nil end
    return Handle
end

local class = require("class")
local CCharacterBase = require("GameLua.GameCore.Framework.CharacterBase")
local CBRPlayerCharacterBase = class(CCharacterBase, nil, BRPlayerCharacterBase)
return require("combine_class").DeclareFeature(CBRPlayerCharacterBase, {
    { SkyTransition = "GameLua.Mod.BaseMod.Gameplay.Feature.SkyControl.PlayerCharacterSkyTransitionFeature" },
    { CarryDeadBoxFeature = "GameLua.Mod.Library.GamePlay.Feature.CarryDeadBoxFeature" },
    { SpecialSuitFeature = "GameLua.Mod.Library.GamePlay.Feature.SpecialSuitFeature" },
    { TeleportPawnFeature = "GameLua.Mod.Library.GamePlay.Feature.TeleportPawnFeature" },
    { LifterControl = "GameLua.Mod.BaseMod.Gameplay.Feature.Player.CharacterLifterControlFeature" },
    { FinalKillEffect = "GameLua.Mod.BaseMod.Gameplay.Feature.Player.PlayerCharacterFinalKillEffectFeature" },
    { CampFeature = "GameLua.Mod.BaseMod.GamePlay.Feature.Camp.PlayerCharacterCampFeature" },
    { BuildAircraftVehicleFeature = "GameLua.Mod.BaseMod.GamePlay.Feature.PlayerCharacterBuildVehicleFeature" },
    { UnifiedBuildVehicleFeature = "GameLua.Mod.BaseMod.GamePlay.Feature.UnifiedBuildVehicleFeature" },
    { CommonBornlandTransformFeature = "GameLua.Mod.BaseMod.GamePlay.Feature.HeroPropFeature.CommonBornlandTransformFeature" },
    { ParachuteFormation = "GameLua.Mod.BaseMod.GamePlay.Feature.ParachuteFormationFeature" },
    { ParachuteSprint = "GameLua.Mod.BaseMod.GamePlay.Feature.Parachute.ParachuteSprintFeature" },
    { GeneralShowSpotFeature = "GameLua.Mod.BRMod.Gameplay.Feature.PlayerCharacterGeneralShowSpotFeature" },
    { FPPAnimMonitor = "GameLua.Mod.BaseMod.GamePlay.Feature.Player.FPPAnimMonitorFeature" }
}, "BRPlayerCharacterBase")
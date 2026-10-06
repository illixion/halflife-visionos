// LambdaVision VR layer: the native HUD's state publish.
//
// LambdaVision draws the HUD in Metal, not in the 2D HUD layer.
// g_vr_hud_native (set by the bridge) turns the stock health, battery, ammo
// and flashlight readouts off (hooks at the top of their Draw functions);
// pain/damage indicators, the pickup history and text messages still draw.
// g_vr_hud_state is what the native HUD shows, refreshed every redraw (hook:
// first thing in CHud::Redraw) — plain floats so the bridge reads it without
// the SDK's headers:
//   [0] has suit   [1] health   [2] battery   [3] m_iHideHUDDisplay
//   [4] weapon id (-1 none)     [5] clip (-1 = no clip)
//   [6] primary reserve (-1 = no primary ammo)  [7] primary max
//   [8] secondary count (-1 = no secondary)     [9] secondary max
//   [10] flashlight on   [11] flashlight charge 0…1   [12] intermission
//   [13] max clip (-1 = none/unknown; from the weapon's own GetItemInfo)

// The readouts live in private members of CHudAmmo / CHudBattery /
// CHudFlashlight. Opening them up for this one translation unit keeps hud.h
// untouched (it is among the most-edited headers in mods); access control
// does not change the class layout. System headers come first so only the
// SDK's own classes see the define.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#define private public
#define protected public
#include "hud.h"
#include "cl_util.h"
#include "ammohistory.h"
#undef private
#undef protected

// Platform-facing globals are weak: every compiled-in game defines the same
// set, and the single static link keeps one copy that the bridge and the
// running game share (only one game runs per process).
#define VR_SHARED extern "C" __attribute__((weak, visibility("default")))

// Non-zero initializers keep both in __DATA,__data rather than common
// storage (see the gpGlobals common-symbol merge in the static link).
VR_SHARED int g_vr_hud_native = 1;
VR_SHARED float g_vr_hud_state[14] = { 0, 0, 0, 0, -1, -1, -1, 0, -1, 0, 0, 0, 0, -1 };
int VR_WeaponMaxClip( int id );	// vr_weapons.cpp

// Hook for the stock readouts' Draw functions.
int VR_HudNative( void )
{
	return g_vr_hud_native;
}

void VR_PublishHudState( void )
{
	float *s = g_vr_hud_state;
	s[0] = ( gHUD.m_iWeaponBits & ( 1 << ( WEAPON_SUIT ) ) ) ? 1.0f : 0.0f;
	s[1] = (float)gHUD.m_Health.m_iHealth;
	s[2] = (float)gHUD.m_Battery.m_iBat;
	s[3] = (float)gHUD.m_iHideHUDDisplay;
	const WEAPON *w = gHUD.m_Ammo.m_pWeapon;
	s[4] = w ? (float)w->iId : -1.0f;
	s[5] = w ? (float)w->iClip : -1.0f;
	s[6] = ( w && w->iAmmoType > 0 ) ? (float)gWR.CountAmmo( w->iAmmoType ) : -1.0f;
	s[7] = w ? (float)w->iMax1 : 0.0f;
	s[8] = ( w && w->iAmmo2Type > 0 ) ? (float)gWR.CountAmmo( w->iAmmo2Type ) : -1.0f;
	s[9] = w ? (float)w->iMax2 : 0.0f;
	s[10] = gHUD.m_Flash.m_fOn ? 1.0f : 0.0f;
	s[11] = gHUD.m_Flash.m_flBat;
	s[12] = (float)gHUD.m_iIntermission;
	s[13] = w ? (float)VR_WeaponMaxClip( w->iId ) : -1.0f;
}

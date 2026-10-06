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

	extern void VR_PublishWheelState( void );
	VR_PublishWheelState();
}

// The hand-tracking weapon wheel's contents: one entry per weapon slot the
// player owns anything in, so its sector count follows the game (Opposing
// Force has seven slots, Half-Life five) and the player's arsenal. Each
// entry names the weapon a pick selects, chosen the way hud_fastswitch's
// slotN cycles a bucket: the next usable weapon after the one in hand when
// it sits in that slot, else the slot's first usable one. The app sends the
// name itself (the server's ClientCommand selects any "weapon_*"), so the
// icon it shows is exactly what the pick selects. Seqlock: [0] is odd while
// a write is in progress, and only changes when the contents do.
//   g_vr_wheel: [0] sequence  [1] entry count  [2] 1 = selection allowed
//   (suit on, alive, weapons HUD not hidden)  [3] unused
//   then per entry, VR_WHEEL_FIELDS ints: slot (0-based), weapon id, the
//   pick's position among the slot's owned weapons, owned count, flags
//   (1 = the weapon in hand is in this slot, 2 = nothing usable: no ammo)
//   g_vr_wheel_names: the pick's classname per entry.
#define VR_WHEEL_MAX 16
#define VR_WHEEL_FIELDS 5
#define VR_WHEEL_NAME 64
VR_SHARED int g_vr_wheel[4 + VR_WHEEL_MAX * VR_WHEEL_FIELDS] = { 2 };
VR_SHARED char g_vr_wheel_names[VR_WHEEL_MAX][VR_WHEEL_NAME] = { "-" };
// The server's "slj" physinfo key (the long jump module), as the client's own
// movement prediction reads it: 1 = owned, 0 = not, -1 = not published yet.
VR_SHARED int g_vr_longjump = -1;

void VR_PublishWheelState( void )
{
	const char *slj = gEngfuncs.PhysInfo_ValueForKey ? gEngfuncs.PhysInfo_ValueForKey( "slj" ) : NULL;
	g_vr_longjump = ( slj && atoi( slj ) == 1 ) ? 1 : 0;

	int buf[4 + VR_WHEEL_MAX * VR_WHEEL_FIELDS];
	char names[VR_WHEEL_MAX][VR_WHEEL_NAME];
	memset( buf, 0, sizeof( buf ));
	memset( names, 0, sizeof( names ));
	const WEAPON *cur = gHUD.m_Ammo.m_pWeapon;
	int count = 0;
	for( int slot = 0; slot < MAX_WEAPON_SLOTS && count < VR_WHEEL_MAX; slot++ )
	{
		WEAPON *owned[MAX_WEAPON_POSITIONS];
		int n = 0;
		for( int pos = 0; pos < MAX_WEAPON_POSITIONS; pos++ )
			if( gWR.rgSlots[slot][pos] )
				owned[n++] = gWR.rgSlots[slot][pos];
		if( !n )
			continue;
		const bool holding = cur && cur->iSlot == slot;
		WEAPON *pick = NULL;
		if( holding )
		{
			pick = gWR.GetNextActivePos( slot, cur->iSlotPos );
			if( !pick )
				pick = gWR.GetFirstPos( slot );	// wraps, or the one in hand
		}
		else
			pick = gWR.GetFirstPos( slot );
		int flags = holding ? 1 : 0;
		if( !pick )
		{
			pick = owned[0];
			flags |= 2;
		}
		int index = 0;
		for( int i = 0; i < n; i++ )
			if( owned[i] == pick )
				index = i;
		int *e = &buf[4 + count * VR_WHEEL_FIELDS];
		e[0] = slot;
		e[1] = pick->iId;
		e[2] = index;
		e[3] = n;
		e[4] = flags;
		strncpy( names[count], pick->szName, VR_WHEEL_NAME - 1 );
		count++;
	}
	buf[1] = count;
	const bool suit = ( gHUD.m_iWeaponBits & ( 1 << ( WEAPON_SUIT ))) != 0;
	buf[2] = ( suit && !gHUD.m_fPlayerDead
		&& !( gHUD.m_iHideHUDDisplay & ( HIDEHUD_WEAPONS | HIDEHUD_ALL ))) ? 1 : 0;

	if( !memcmp( buf + 1, g_vr_wheel + 1, sizeof( buf ) - sizeof( int ))
		&& !memcmp( names, g_vr_wheel_names, sizeof( names )))
		return;
	const int seq = g_vr_wheel[0];
	__atomic_store_n( &g_vr_wheel[0], seq + 1, __ATOMIC_RELEASE );
	__atomic_thread_fence( __ATOMIC_SEQ_CST );
	memcpy( g_vr_wheel + 1, buf + 1, sizeof( buf ) - sizeof( int ));
	memcpy( g_vr_wheel_names, names, sizeof( names ));
	__atomic_store_n( &g_vr_wheel[0], seq + 2, __ATOMIC_RELEASE );
}

// LambdaVision VR layer: weapon facts the native HUD needs from the client's
// weapon prediction objects (cl_dll/hl/hl_weapons.cpp's g_pWpns, which is
// static there; its one hook line exports the array).

#include "extdll.h"
#include "util.h"
#include "cbase.h"
#include "weapons.h"

extern CBasePlayerWeapon **g_vr_client_weapons;	// defined in hl_weapons.cpp

// VR native HUD: the weapon's own declared clip size (GetItemInfo), so the
// HUD needs no table of stock weapons and follows whatever weapon code is
// built in. -1 when the weapon has no clip or no client-side prediction
// object (the client's ItemInfoArray is never filled, so iMaxClip() is 0).
int VR_WeaponMaxClip( int id )
{
	if( id < 0 || id >= MAX_WEAPONS || !g_vr_client_weapons || !g_vr_client_weapons[id] )
		return -1;
	ItemInfo info;
	memset( &info, 0, sizeof( info ) );
	if( !g_vr_client_weapons[id]->GetItemInfo( &info ) )
		return -1;
	return info.iMaxClip > 0 ? info.iMaxClip : -1;
}

// The egon's weapon id in this game's numbering (8 in Half-Life, 10 in
// Opposing Force), for client code that can't include weapons.h.
int VR_WeaponEgonId( void )
{
	return WEAPON_EGON;
}

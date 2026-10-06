// LambdaVision VR layer: barrel aim for the client-side weapon events.
//
// The server adds g_vr_aim_offset to pev->v_angle inside the weapon frame
// (dlls/vr/vr_player.cpp) so shots fire along the weapon barrel (the hand
// direction) rather than the head view, and moves the shot's origin to the
// muzzle. The client event that draws the bullet-hole decal + tracer reads
// args->angles — the head view, with NO offset — and starts at the eye, so
// without this the visual "lied": the hole appeared along the gaze while the
// damage went along the barrel.
//
// Instead of editing every event in ev_hldm.cpp, VR_ClientInit (hook: in
// Initialize, before EV_HookEvents) wraps gEngfuncs.pfnHookEvent. Events named
// in the table below are registered through a trampoline that, for the local
// player only, adds g_vr_aim_offset_cl to args->angles for the duration of
// the call (every listed event copies args->angles once, up front), and arms
// VR_EV_GunPosition (hook: end of EV_GetGunPosition, ev_common.cpp) to move
// the trace start to the muzzle, with the same eye→muzzle wall check as the
// server. A mod's own weapons get the same treatment by adding their event
// names here — no edit to the mod's event code.
//
// We read g_vr_aim_offset_cl (vr_client.cpp, written by the bridge) rather
// than the server's g_vr_aim_offset — the intermediate cl_dll dylib link has
// no server symbols. Egon is absent, matching the server-side and
// render-side exemptions — it fires along the view.

#include "hud.h"
#include "cl_util.h"
#include "const.h"
#include "entity_types.h"
#include "event_api.h"
#include "event_args.h"
#include "pm_defs.h"
#include "pmtrace.h"
#include "in_defs.h" // PITCH YAW ROLL
#include "eventscripts.h" // EV_IsLocal

extern "C" float g_vr_aim_offset_cl[2];     // vr_client.cpp
extern "C" float g_vr_muzzle_offset_cl[4];  // vr_client.cpp

typedef void ( *vr_event_fn )( struct event_args_s *args );

static const struct
{
	const char *name;
	int muzzle;	// 1: the event fires bullets from EV_GetGunPosition
} s_vrEvents[] =
{
	// Half-Life
	{ "events/glock1.sc", 1 },
	{ "events/glock2.sc", 1 },
	{ "events/shotgun1.sc", 1 },
	{ "events/shotgun2.sc", 1 },
	{ "events/mp5.sc", 1 },
	{ "events/python.sc", 1 },
	{ "events/gauss.sc", 1 },
	{ "events/gaussspin.sc", 0 },
	// Opposing Force (same shape: one args->angles copy, one EV_GetGunPosition)
	{ "events/eagle.sc", 1 },
	{ "events/m249.sc", 1 },
	{ "events/sniper.sc", 1 },
};

#define VR_MAX_EVENTS 32

static vr_event_fn s_vrEventFns[VR_MAX_EVENTS];
static int s_vrEventMuzzle[VR_MAX_EVENTS];
static void ( *s_vrHookEvent )( const char *name, vr_event_fn pfnEvent );

// Set while a muzzle event runs for the local player: the view yaw before
// the aim offset, which the muzzle offset's level frame is relative to.
static int s_vrMuzzleArmed = 0;
static float s_vrMuzzleYaw = 0.0f;

static void VR_RunEvent( int slot, struct event_args_s *args )
{
	vr_event_fn fn = s_vrEventFns[slot];
	if( !EV_IsLocal( args->entindex ))
	{
		fn( args );
		return;
	}
	float saved[3];
	VectorCopy( args->angles, saved );
	args->angles[PITCH] += g_vr_aim_offset_cl[0];
	args->angles[YAW]   += g_vr_aim_offset_cl[1];
	s_vrMuzzleArmed = s_vrEventMuzzle[slot];
	s_vrMuzzleYaw = saved[YAW];

	fn( args );

	s_vrMuzzleArmed = 0;
	VectorCopy( saved, args->angles );
}

template<int N> static void VR_EventTrampoline( struct event_args_s *args )
{
	VR_RunEvent( N, args );
}

#define VR_T4( n ) VR_EventTrampoline<n>, VR_EventTrampoline<n + 1>, VR_EventTrampoline<n + 2>, VR_EventTrampoline<n + 3>
static const vr_event_fn s_vrTrampolines[VR_MAX_EVENTS] =
{
	VR_T4( 0 ), VR_T4( 4 ), VR_T4( 8 ), VR_T4( 12 ),
	VR_T4( 16 ), VR_T4( 20 ), VR_T4( 24 ), VR_T4( 28 ),
};

static void VR_HookEvent( const char *name, vr_event_fn pfnEvent )
{
	static int used = 0;
	for( size_t i = 0; name && pfnEvent && i < sizeof( s_vrEvents ) / sizeof( s_vrEvents[0] ); i++ )
	{
		if( strcmp( name, s_vrEvents[i].name ))
			continue;
		// A re-registration of the same event reuses its slot.
		int slot;
		for( slot = 0; slot < used; slot++ )
			if( s_vrEventFns[slot] == pfnEvent )
				break;
		if( slot == used )
		{
			if( used == VR_MAX_EVENTS )
				break;
			used++;
		}
		s_vrEventFns[slot] = pfnEvent;
		s_vrEventMuzzle[slot] = s_vrEvents[i].muzzle;
		s_vrHookEvent( name, s_vrTrampolines[slot] );
		return;
	}
	s_vrHookEvent( name, pfnEvent );
}

/*
=========================
VR_ClientInit

Hook: Initialize (cdll_int.cpp), after gEngfuncs is filled, before
EV_HookEvents.
=========================
*/
void VR_ClientInit( void )
{
	if( gEngfuncs.pfnHookEvent != VR_HookEvent )
	{
		s_vrHookEvent = gEngfuncs.pfnHookEvent;
		gEngfuncs.pfnHookEvent = VR_HookEvent;
	}
}

/*
=========================
VR_EV_GunPosition

Hook: end of EV_GetGunPosition (ev_common.cpp).

VR muzzle origin: the server fires from the muzzle of the gun in the hand
(CBasePlayer::GetGunPosition → VR_GunPosition); move the client trace's
start the same way, with the same eye→muzzle wall check, so the tracer and
the decal leave the drawn barrel. g_vr_muzzle_offset_cl is muzzle relative
to the eye in the level frame of the view yaw, [3] > 0 while active.
=========================
*/
void VR_EV_GunPosition( struct event_args_s *args, float *vecSrc )
{
	if( !s_vrMuzzleArmed )
		return;
	s_vrMuzzleArmed = 0; // once per event, right after the eye position
	if( !EV_IsLocal( args->entindex ) || g_vr_muzzle_offset_cl[3] <= 0.0f )
		return;
	const float *o = g_vr_muzzle_offset_cl;
	float yaw = s_vrMuzzleYaw * 0.017453293f;
	float c = cosf( yaw ), s = sinf( yaw );
	vec3_t muzzle;
	muzzle[0] = vecSrc[0] + c * o[0] - s * o[1];
	muzzle[1] = vecSrc[1] + s * o[0] + c * o[1];
	muzzle[2] = vecSrc[2] + o[2];
	pmtrace_t *tr = gEngfuncs.PM_TraceLine( vecSrc, muzzle, PM_TRACELINE_PHYSENTSONLY, 2, -1 );
	if( tr && tr->fraction >= 1.0f && !tr->startsolid && !tr->allsolid )
		VectorCopy( muzzle, vecSrc );
}

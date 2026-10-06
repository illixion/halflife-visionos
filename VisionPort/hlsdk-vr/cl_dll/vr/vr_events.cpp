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
// no server symbols. While the gun on screen is the head-locked viewmodel
// (g_vr_weapon_flat_cl), events run as stock, matching the server, which
// then fires along the view too.
//
// Not listed, because they draw nothing from the view: the gluon gun (its
// beam is a server entity attached to the gun's muzzle, which
// VR_StudioAttachments moves to the drawn gun, as it does the shock roach's
// arcs and every muzzle flash), the displacer (sound and animation only; the
// ball is a server entity) and the melee swings.

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
extern "C" int g_vr_weapon_flat_cl;         // vr_client.cpp
extern "C" float g_vr_weapon_xform_cl[13];  // vr_client.cpp

typedef void ( *vr_event_fn )( struct event_args_s *args );

enum
{
	VR_EV_AIM,	// copies args->angles once: aims along the barrel
	VR_EV_MUZZLE,	// ...and fires from EV_GetGunPosition once: from the muzzle
	VR_EV_ORIGIN,	// ...and places its effect at args->origin + the offset below
			// (forward, right, up, in the aimed frame): moved to the muzzle
};

static const struct
{
	const char *name;
	int mode;
	float offset[3];	// VR_EV_ORIGIN only
} s_vrEvents[] =
{
	// Half-Life
	{ "events/glock1.sc", VR_EV_MUZZLE },
	{ "events/glock2.sc", VR_EV_MUZZLE },
	{ "events/shotgun1.sc", VR_EV_MUZZLE },
	{ "events/shotgun2.sc", VR_EV_MUZZLE },
	{ "events/mp5.sc", VR_EV_MUZZLE },
	{ "events/python.sc", VR_EV_MUZZLE },
	{ "events/gauss.sc", VR_EV_MUZZLE },
	{ "events/gaussspin.sc", VR_EV_AIM },
	{ "events/crossbow2.sc", VR_EV_MUZZLE },	// the zoomed bolt's hit
	// The throw checks: their trace must match the server's (which runs
	// along the aimed v_angle) or the throw animation plays for a throw that
	// never happens, or the other way round.
	{ "events/snarkfire.sc", VR_EV_AIM },
	{ "events/tripfire.sc", VR_EV_AIM },
	// Opposing Force
	{ "events/eagle.sc", VR_EV_MUZZLE },
	{ "events/m249.sc", VR_EV_MUZZLE },
	{ "events/sniper.sc", VR_EV_MUZZLE },
	{ "events/penguinfire.sc", VR_EV_AIM },
	// The spore launcher's spit spray, at origin + forward·16 + right·8 + up·4.
	{ "events/spore.sc", VR_EV_ORIGIN, { 16.0f, 8.0f, 4.0f } },
};

#define VR_MAX_EVENTS 32

static vr_event_fn s_vrEventFns[VR_MAX_EVENTS];
static int s_vrEventSlot[VR_MAX_EVENTS];	// index into s_vrEvents
static void ( *s_vrHookEvent )( const char *name, vr_event_fn pfnEvent );

// Set while a muzzle event runs for the local player: the view yaw before
// the aim offset, which the muzzle offset's level frame is relative to.
static int s_vrMuzzleArmed = 0;
static float s_vrMuzzleYaw = 0.0f;
// Set for the whole of a listed event run for the local player.
static int s_vrEventActive = 0;

static void VR_RunEvent( int slot, struct event_args_s *args )
{
	vr_event_fn fn = s_vrEventFns[slot];
	if( !EV_IsLocal( args->entindex ) || g_vr_weapon_flat_cl )
	{
		fn( args );
		return;
	}
	const int mode = s_vrEvents[s_vrEventSlot[slot]].mode;
	float saved[3], savedOrigin[3];
	VectorCopy( args->angles, saved );
	VectorCopy( args->origin, savedOrigin );
	args->angles[PITCH] += g_vr_aim_offset_cl[0];
	args->angles[YAW]   += g_vr_aim_offset_cl[1];
	s_vrMuzzleYaw = saved[YAW];

	if( mode == VR_EV_ORIGIN && g_vr_muzzle_offset_cl[3] > 0.0f )
	{
		// Where the muzzle is (the eye when a wall is in the way), less the
		// event's own offset, so the effect it places lands on the muzzle.
		const float *off = s_vrEvents[s_vrEventSlot[slot]].offset;
		vec3_t muzzle, forward, right, up;
		s_vrMuzzleArmed = 1;
		EV_GetGunPosition( args, muzzle, args->origin );
		AngleVectors( args->angles, forward, right, up );
		for( int i = 0; i < 3; i++ )
			args->origin[i] = muzzle[i] - forward[i] * off[0] - right[i] * off[1] - up[i] * off[2];
	}
	s_vrMuzzleArmed = mode == VR_EV_MUZZLE;
	s_vrEventActive = 1;

	fn( args );

	s_vrEventActive = 0;
	s_vrMuzzleArmed = 0;
	VectorCopy( saved, args->angles );
	VectorCopy( savedOrigin, args->origin );
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
		s_vrEventSlot[slot] = (int)i;
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

/*
=========================
VR_EV_ShellInfo

Hook: end of EV_GetDefaultShellInfo (ev_common.cpp).

Shells eject from the gun in the hand. Stock places the shell at a fixed
offset from the eye along the view's forward/right/up — a point on the flat
viewmodel, which is authored in view space (x forward, y left, z up from the
eye). With barrel aim those axes are the barrel's, but the origin is still
the eye, so shells left from in front of the face, off the aim ray. The
offset is read as that viewmodel-space point and carried onto the drawn gun
by the platform's model transform (g_vr_weapon_xform_cl); the throw is
turned with it, the player's own velocity kept.
=========================
*/
void VR_EV_ShellInfo( struct event_args_s *args, float *velocity, float *ShellVelocity, float *ShellOrigin,
	float *forward, float *right, float *up, float forwardScale, float upScale, float rightScale )
{
	const float *x = g_vr_weapon_xform_cl;
	if( !s_vrEventActive || x[12] <= 0.0f || !EV_IsLocal( args->entindex ))
		return;
	int i;
	vec3_t eye, d;
	for( i = 0; i < 3; i++ )
	{
		eye[i] = ShellOrigin[i] - up[i] * upScale - forward[i] * forwardScale - right[i] * rightScale;
		d[i] = ShellVelocity[i] - velocity[i];
	}
	// Viewmodel space: x forward, y left, z up.
	const float p[3] = { forwardScale, -rightScale, upScale };
	const float v[3] = { DotProduct( d, forward ), -DotProduct( d, right ), DotProduct( d, up ) };
	// x: columns of the gun's rotation [0..8] and its origin [9..11], relative
	// to the eye in the level frame of the view yaw.
	float lp[3], lv[3];
	for( i = 0; i < 3; i++ )
	{
		lp[i] = x[i] * p[0] + x[3 + i] * p[1] + x[6 + i] * p[2] + x[9 + i];
		lv[i] = x[i] * v[0] + x[3 + i] * v[1] + x[6 + i] * v[2];
	}
	const float yaw = s_vrMuzzleYaw * 0.017453293f, c = cosf( yaw ), s = sinf( yaw );
	ShellOrigin[0] = eye[0] + c * lp[0] - s * lp[1];
	ShellOrigin[1] = eye[1] + s * lp[0] + c * lp[1];
	ShellOrigin[2] = eye[2] + lp[2];
	ShellVelocity[0] = velocity[0] + c * lv[0] - s * lv[1];
	ShellVelocity[1] = velocity[1] + s * lv[0] + c * lv[1];
	ShellVelocity[2] = velocity[2] + lv[2];
}

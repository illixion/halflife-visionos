// LambdaVision VR layer, server side: aim ray, muzzle origin, immersive +use
// and the train throttle. Copied into dlls/vr/ by VisionPort/hlsdk-vr/
// apply.sh; dlls' wscript globs **/*.cpp, so nothing registers it. The hook
// calls in dlls/player.cpp are declared in vr_server.h.

#include "extdll.h"
#include "util.h"
#include "cbase.h"
#include "player.h"
#include "trains.h"
#include "weapons.h"
#include "vr_server.h"

// Platform-facing globals are weak: every compiled-in game defines the same
// set, and the single static link keeps one copy that the bridge and the
// running game share (only one game runs per process).
#define VR_SHARED extern "C" __attribute__((weak, visibility("default")))

// VR (LambdaVision): angular offset of the aim ray from the view
// direction (pitch, yaw — degrees), written per frame by the platform
// bridge. Applied around the weapon frame in VR_ItemPostFrame so weapons
// fire along the player's gaze/hand ray while view, movement and pmove
// stay on the real view angles. Default visibility: the ld -r prelink
// localizes hidden symbols and the bridge externs this by name.
VR_SHARED float g_vr_aim_offset[2] = { 0.0f, 0.0f };

// VR (LambdaVision): where shots leave from. [0..2] = the gun's muzzle
// relative to the eye (pev->origin + view_ofs), in units, in the level frame
// of the view yaw (x forward, y left, z up); [3] > 0 while the platform has
// a gun in the hand. Only read inside the weapon frame (see VR_ItemPostFrame),
// where v_angle carries the aim offset, so the yaw is saved beforehand.
VR_SHARED float g_vr_muzzle_offset[4] = { 0.0f, 0.0f, 0.0f, -1.0f };
static int   g_vr_weapon_frame = 0;
static float g_vr_weapon_frame_yaw = 0.0f;

// VR (LambdaVision): immersive +use. g_vr_use_offset points the PlayerUse
// selection cone along the platform's eye→fingertip ray (pitch/yaw degrees
// from the view direction, same convention as g_vr_aim_offset);
// g_vr_use_active gates it — zero means the stock gaze cone. When active,
// the entity cone search also runs BEFORE the train-mount attempt, so
// poking a button while standing on a controllable train presses the
// button instead of grabbing the train.
VR_SHARED float g_vr_use_offset[2] = { 0.0f, 0.0f };
VR_SHARED int g_vr_use_active = 0;

// VR train throttle: the platform stages a desired gear (-1 reverse, 0
// neutral, 1..3 forward; VR_TRAIN_NO_TARGET = gesture inactive) and the
// PreThink train block steps the train one notch at a time toward it via
// the same USE_SET path the IN_FORWARD/IN_BACK edges use — sounds and the
// HUD gear sprite behave exactly like key taps. g_vr_train_state mirrors
// the live status back to the platform: 0 = not controlling a train, else
// 0x100 | (gear + 1).
#define VR_TRAIN_NO_TARGET	99
VR_SHARED int g_vr_train_target = VR_TRAIN_NO_TARGET;
VR_SHARED int g_vr_train_state = 0;

extern int TrainSpeed( int iSpeed, int iMax );	// player.cpp
#ifndef TRAIN_NEW
#define TRAIN_NEW		0xc0	// player.cpp keeps it private
#endif

void VR_GunPosition( CBasePlayer *pPlayer, Vector &origin )
{
	// VR: fire from the muzzle of the gun in the player's hand, unless
	// something solid sits between the eye and it — a barrel pushed
	// through a wall must not shoot from the far side.
	if( g_vr_weapon_frame && g_vr_muzzle_offset[3] > 0.0f )
	{
		const float *o = g_vr_muzzle_offset;
		float yaw = g_vr_weapon_frame_yaw * 0.017453293f;
		float c = cosf( yaw ), s = sinf( yaw );
		Vector muzzle = origin + Vector( c * o[0] - s * o[1], s * o[0] + c * o[1], o[2] );
		TraceResult tr;
		UTIL_TraceLine( origin, muzzle, ignore_monsters, ENT( pPlayer->pev ), &tr );
		if( tr.flFraction >= 1.0f && !tr.fStartSolid && !tr.fAllSolid )
			origin = muzzle;
	}
}

void VR_ItemPostFrame( CBasePlayer *pPlayer )
{
	entvars_t *pev = pPlayer->pev;
	CBasePlayerItem *pItem = pPlayer->m_pActiveItem;

	// VR aim: fire along the platform-supplied aim ray (gaze or hand),
	// scoped to the weapon frame — UTIL_MakeVectors, GetAutoaimVector and
	// GetGunPosition all read v_angle, so every weapon inherits the ray;
	// GetGunPosition also moves the shot's origin to the muzzle.
	// The egon is exempt: it renders as the camera-locked viewmodel
	// (its backpack clips the body when hand-anchored, see vr_client.cpp),
	// so it must fire along the view direction — where the player looks —
	// to match the gun the player sees, not the hand ray.
	if( pItem->m_iId == WEAPON_EGON )
	{
		pItem->ItemPostFrame();
	}
	else
	{
		Vector vrSavedAngle = pev->v_angle;
		pev->v_angle.x += g_vr_aim_offset[0];
		pev->v_angle.y += g_vr_aim_offset[1];
		g_vr_weapon_frame = 1;
		g_vr_weapon_frame_yaw = vrSavedAngle.y;

		pItem->ItemPostFrame();

		g_vr_weapon_frame = 0;
		pev->v_angle = vrSavedAngle;
	}
}

// VR: current gear of a controlled train as -1..3 (reverse..full), the
// same banding TrainSpeed() uses for the HUD sprite.
static int VR_TrainGear( CBaseEntity *pTrain )
{
	int iSpeed = (int)pTrain->pev->speed;
	float f = pTrain->pev->impulse ? (float)iSpeed / (float)pTrain->pev->impulse : 0.0f;

	if( iSpeed < 0 )
		return -1;
	if( iSpeed == 0 )
		return 0;
	if( f < 0.33f )
		return 1;
	if( f < 0.66f )
		return 2;
	return 3;
}

// VR: the stock train-mount attempt (PlayerUse), repeated here so the
// immersive use path can try it AFTER the entity cone search instead of
// before.
static BOOL VR_TryMountTrain( CBasePlayer *pPlayer )
{
	entvars_t *pev = pPlayer->pev;
	CBaseEntity *pTrain = CBaseEntity::Instance( pev->groundentity );

	if( pTrain && !( pev->button & IN_JUMP ) && FBitSet( pev->flags, FL_ONGROUND ) && ( pTrain->ObjectCaps() & FCAP_DIRECTIONAL_USE ) && pTrain->OnControls( pev ) )
	{
		pPlayer->m_afPhysicsFlags |= PFLAG_ONTRAIN;
		pPlayer->m_iTrain = TrainSpeed( (int)pTrain->pev->speed, pTrain->pev->impulse );
		pPlayer->m_iTrain |= TRAIN_NEW;

		if( pTrain->Classify() == CLASS_VEHICLE )
		{
			EMIT_SOUND( ENT( pev ), CHAN_ITEM, "plats/vehicle_ignition.wav", 0.8, ATTN_NORM );
			( (CFuncVehicle *)pTrain )->m_pDriver = pPlayer;
		}
		else
			EMIT_SOUND( ENT( pev ), CHAN_ITEM, "plats/train_use1.wav", 0.8, ATTN_NORM );
		return TRUE;
	}
	return FALSE;
}

int VR_UseActive( void )
{
	return g_vr_use_active;
}

void VR_UseCone( CBasePlayer *pPlayer, float *flMaxDot )
{
	// VR: aim the selection cone along the platform's eye→fingertip ray
	// instead of the view center, and tighten it — a finger is more
	// precise than gaze, and adjacent buttons must not steal the pick.
	if( g_vr_use_active )
	{
		Vector vrUseAngle = pPlayer->pev->v_angle;
		vrUseAngle.x += g_vr_use_offset[0];
		vrUseAngle.y += g_vr_use_offset[1];
		UTIL_MakeVectors( vrUseAngle );
		*flMaxDot = 0.9f;
	}
}

int VR_UseMountTrain( CBasePlayer *pPlayer )
{
	// VR: nothing usable under the finger — now try the train mount that
	// the stock code would have tried first.
	if( ( pPlayer->m_afButtonPressed & IN_USE ) && g_vr_use_active
		&& !( pPlayer->m_afPhysicsFlags & PFLAG_ONTRAIN ) && pPlayer->m_pTank == 0 )
		return VR_TryMountTrain( pPlayer );
	return FALSE;
}

void VR_TrainReset( void )
{
	g_vr_train_state = 0;	// re-published by VR_TrainThink while actually controlling
}

void VR_TrainThink( CBasePlayer *pPlayer, CBaseEntity *pTrain )
{
	// VR throttle: step one notch at a time toward the staged target gear
	// through the same USE_SET path as the key edges, rate-limited so gears
	// click by like deliberate taps. Trains only; vehicles steer by keys.
	if( pTrain->Classify() != CLASS_VEHICLE && g_vr_train_target != VR_TRAIN_NO_TARGET )
	{
		static float s_flNextVRTrainStep = 0.0f;
		int iWant = g_vr_train_target;

		if( iWant > 3 ) iWant = 3;
		if( iWant < -1 ) iWant = -1;

		if( s_flNextVRTrainStep < gpGlobals->time && iWant != VR_TrainGear( pTrain ) )
		{
			pTrain->Use( pPlayer, pPlayer, USE_SET, ( iWant > VR_TrainGear( pTrain ) ) ? 1 : -1 );
			s_flNextVRTrainStep = gpGlobals->time + 0.25f;
		}
	}
	g_vr_train_state = 0x100 | ( VR_TrainGear( pTrain ) + 1 );
}

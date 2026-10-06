// LambdaVision VR layer, client side: the platform-facing globals, the
// hand-anchored weapon publish, the per-refdef publishes (body state, aim hit)
// and the analog-stick move. Copied into cl_dll/vr/ by VisionPort/hlsdk-vr/
// apply.sh; cl_dll's wscript globs **/*.cpp, so nothing registers it. The
// upstream files only carry the hook calls (VisionPort/hlsdk-vr/hooks.patch).

#include <memory.h>

#include "hud.h"
#include "cl_util.h"
#include "cvardef.h"
#include "usercmd.h"
#include "const.h"
#include "kbutton.h"
#include "entity_state.h"
#include "cl_entity.h"
#include "entity_types.h"
#include "ref_params.h"
#include "in_defs.h" // PITCH YAW ROLL
#include "pm_movevars.h"
#include "pm_shared.h"
#include "pm_defs.h"
#include "event_api.h"
#include "pmtrace.h"
#include "view.h"
#include "com_model.h"
#include "studio.h"
#include "triangleapi.h" // pTriAPI->LightAtPoint for the weapon light probe
#include "r_studioint.h" // IEngineStudio.Mod_Extradata for the p_ hull
extern engine_studio_api_t IEngineStudio;

// Platform-facing globals are weak: every compiled-in game defines the same
// set, and the single static link keeps one copy that the bridge and the
// running game share (only one game runs per process).
#define VR_SHARED extern "C" __attribute__((weak, visibility("default")))

extern vec3_t v_origin;
extern vec3_t v_angles;

#ifndef PITCH
#define PITCH 0
#define YAW   1
#define ROLL  2
#endif
#ifndef M_PI_F
#define M_PI_F 3.14159265358979323846f
#endif

// Cosmetic hand-anchored-weapon grip tuning (see VR_AddHandWeapon).
// ROLL: + rolls the gun left about its barrel. PUSH: cm back toward the wrist.
#define VR_GRIP_ROLL_DEG -90.0f
#define VR_GRIP_PUSH_CM  3.0f

// VR hand-anchored weapon: pose written by the platform bridge every tick
// (camera-local, xash axes: x fwd/y left/z up; pos in units, fwd/up unit
// vectors). While active the stock camera-locked viewmodel is hidden (see
// VR_HideViewModel) and VR_AddHandWeapon draws the current p_ model at this
// pose as a world entity. Defined hlsdk-side, extern'd by the bridge (the
// intermediate cl_dll link needs the definition).
VR_SHARED float g_vr_hand_pose[9] = { 0 };
VR_SHARED int g_vr_hand_pose_active = 0;
// Mirror of the engine's stereo view override (abs pitch, delta yaw, abs
// roll + head translation in the baseline-yaw frame), copied over by the
// bridge each tick. The engine globals can't be referenced from here
// directly — the intermediate cl_dll dylib link has no engine symbols.
// [0]=active, [1..3]=angles, [4..6]=origin offset.
VR_SHARED float g_vr_cam_override[7] = { 0 };
// Client-side mirror of the server's g_vr_aim_offset (dlls/vr/vr_player.cpp):
// the pitch/yaw the server adds to pev->v_angle so shots fire along the weapon
// barrel. The client bullet-trace events (vr_events.cpp) apply the SAME offset
// so the decal/tracer land where the damage does. Defined here (not extern'd
// from the server) because the intermediate cl_dll dylib link has no server
// symbols; the bridge writes both copies each tick from one source.
VR_SHARED float g_vr_aim_offset_cl[2] = { 0 };
// Client mirror of the server's g_vr_muzzle_offset: the muzzle of the gun in
// the hand relative to the eye, in the level frame of the view yaw (units);
// [3] > 0 while active. The bullet events start their traces there
// (vr_events.cpp) and the aim trace below does too.
VR_SHARED float g_vr_muzzle_offset_cl[4] = { 0.0f, 0.0f, 0.0f, -1.0f };
// The aim ray's hit, for the platform's reticle: [0] = distance from the
// muzzle along the aim to the first thing a shot would hit (units), [1] > 0
// when there is one to show. Published every normal refdef.
VR_SHARED float g_vr_aim_hit[2] = { 0.0f, -1.0f };
// Set by VR_AddHandWeapon each frame: 1 when the weapon's p_ model was drawn
// at the hand (so the viewmodel is hidden), 0 when it fell back to the stock
// viewmodel — e.g. the egon, whose backpack is rigged to the body and clips
// into the player when hand-anchored.
int g_vr_hand_weapon_drawn = 0;
// Published by VR_AddHandWeapon each frame when vr_weapon_external is on: the
// viewmodel's resident studio header, its engine model index, body value and
// animation state (sequence / frame / animtime / framerate + the client time
// they are relative to — the inputs of R_StudioEstimateFrame). The visionOS
// Metal weapon pass (Lambda_WeaponModel.c) reads these to bake the skinned
// mesh once and pose its bones every tick. NULL header = no external weapon
// this frame.
VR_SHARED void *g_vr_weapon_hdr = 0;
VR_SHARED int   g_vr_weapon_modelindex = 0;
VR_SHARED int   g_vr_weapon_body = 0;
VR_SHARED int   g_vr_weapon_sequence = 0;
VR_SHARED float g_vr_weapon_frame = 0.0f;
VR_SHARED float g_vr_weapon_animtime = 0.0f;
VR_SHARED float g_vr_weapon_framerate = 1.0f;
VR_SHARED float g_vr_weapon_time = 0.0f;
// The same weapon's third-person (p_) model header, published alongside:
// whole where the viewmodel is open, and what the platform draws in the hand
// when the player picks world models. NULL when there is none.
VR_SHARED void *g_vr_weapon_world_hdr = 0;
// World light sampled at the view origin (R_LightPoint via the triangle API),
// normalised 0..1, published each frame for the external weapon renderer to
// shade the gun to match the room.
VR_SHARED float g_vr_weapon_light[3] = { 0.5f, 0.5f, 0.5f };
// Where the player's feet are, for the visionOS first-person body's legs
// (AvatarRig): published every normal refdef, read by the app through
// lambda_body_state (Lambda_WeaponModel.c).
//   [0] eye height above the floor under the player, units, measured from
//       the refdef's vieworg — i.e. BEFORE the engine adds the headset's own
//       translation, so the app adds its head offset back on top.
//   [1] 1 when standing on something, 0 in the air
//   [2] waterlevel (0 dry .. 3 submerged)
//   [3] forward, [4] leftward velocity in the player-yaw frame, units/s —
//       the yaw WITHOUT the head delta, which is the frame the app's head
//       offset baseline lives in
//   [5] vertical velocity, units/s
//   [6] a counter bumped on every publish, so a reader can tell fresh data
//       from a paused game
VR_SHARED float g_vr_body_state[7] = { 64.0f, 1.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f };

extern "C" float g_vr_hud_state[14];  // vr_hud.cpp
int VR_WeaponEgonId( void );          // vr_weapons.cpp

/*
=========================
VR_HandBonePose

Sequence-0 frame-0 pose of the model's right-hand bone, entity space.
p_ models are rigged to the shared player skeleton; aligning this bone's
frame to the player's real hand places every weapon exactly as Valve
posed it in the grip (barrel along bone +X ≈ finger direction, crowbar
up out of the fist). Cached per model.
=========================
*/
static qboolean VR_HandBonePose( studiohdr_t *hdr, float R_out[3][3], float t_out[3] )
{
	mstudiobone_t *pbone = (mstudiobone_t *)((byte *)hdr + hdr->boneindex );
	mstudioseqdesc_t *pseq = (mstudioseqdesc_t *)((byte *)hdr + hdr->seqindex );
	mstudioanim_t *panim = (mstudioanim_t *)((byte *)hdr + pseq->animindex );
	int i, j, k, hand = -1;

	if( hdr->numseq < 1 || hdr->numbones < 1 || hdr->numbones > 128 )
		return false;

	for( i = 0; i < hdr->numbones; i++ )
	{
		if( !strcmp( pbone[i].name, "Bip01 R Hand" ))
		{
			hand = i;
			break;
		}
		if( !strcmp( pbone[i].name, "Bip01 R Forearm" ))
			hand = i; // fallback (p_egon has no hand bone)
	}
	if( hand < 0 )
		return false;

	// Bones are stored parent-first; compose local transforms down the
	// chain. Frame 0 of each DOF = bone default + first RLE anim value.
	static float R[128][3][3], t[128][3];
	for( i = 0; i <= hand; i++ )
	{
		float dof[6];
		for( j = 0; j < 6; j++ )
		{
			unsigned short off = panim[i].offset[j];
			dof[j] = pbone[i].value[j];
			if( off )
			{
				mstudioanimvalue_t *pv = (mstudioanimvalue_t *)((byte *)&panim[i] + off );
				if( pv->num.valid > 0 )
					dof[j] += pv[1].value * pbone[i].scale[j];
			}
		}
		float sx = sinf( dof[3] ), cx = cosf( dof[3] );
		float sy = sinf( dof[4] ), cy = cosf( dof[4] );
		float sz = sinf( dof[5] ), cz = cosf( dof[5] );
		float L[3][3] = {
			{ cz*cy, cz*sy*sx - sz*cx, cz*sy*cx + sz*sx },
			{ sz*cy, sz*sy*sx + cz*cx, sz*sy*cx - cz*sx },
			{ -sy,   cy*sx,            cy*cx            },
		};
		int parent = pbone[i].parent;
		if( parent < 0 )
		{
			memcpy( R[i], L, sizeof( L ));
			for( j = 0; j < 3; j++ ) t[i][j] = dof[j];
		}
		else
		{
			for( j = 0; j < 3; j++ )
			{
				for( k = 0; k < 3; k++ )
					R[i][j][k] = R[parent][j][0]*L[0][k] + R[parent][j][1]*L[1][k] + R[parent][j][2]*L[2][k];
				t[i][j] = t[parent][j] + R[parent][j][0]*dof[0] + R[parent][j][1]*dof[1] + R[parent][j][2]*dof[2];
			}
		}
	}
	memcpy( R_out, R[hand], 9 * sizeof( float ));
	memcpy( t_out, t[hand], 3 * sizeof( float ));
	return true;
}

/*
=========================
VR_AddHandWeapon

Hook: HUD_CreateEntities (entity.cpp), first thing.

Draw the current weapon's p_ model at the tracked hand pose, as a plain
world entity (normal depth — occluded by geometry, unlike the viewmodel's
depth hack). The pose arrives camera-local from the platform bridge; the
rendered camera is reconstructed here exactly the way V_RenderView builds
it (last refdef view + stereo head override), so the gun sticks to the
physical hand regardless of where the game camera or the head points.
=========================
*/
void VR_AddHandWeapon( void )
{
	static cl_entity_t gun;
	int i;

	g_vr_hand_weapon_drawn = 0; // default: viewmodel shows

	// External weapon renderer (visionOS Metal pass) owns the weapon model:
	// draw nothing engine-side, but keep the camera-locked viewmodel hidden
	// so the platform layer is the sole source of the weapon. Toggle from the
	// console or via a "vr_weapon_external 1" command pushed from Swift.
	g_vr_weapon_hdr = NULL; // reset each frame; republished below in external mode
	g_vr_weapon_world_hdr = NULL;

	static cvar_t *vr_weapon_external = NULL;
	if( !vr_weapon_external )
		vr_weapon_external = gEngfuncs.pfnRegisterVariable( "vr_weapon_external", "1", FCVAR_ARCHIVE );
	if( vr_weapon_external && vr_weapon_external->value )
	{
		g_vr_hand_weapon_drawn = 1;
		// Publish the VIEWMODEL (v_*.mdl) — not the third-person p_ model
		// the local player entity carries. Only the v_ model has Gordon's
		// HEV hands, the separable magazine/pump/cylinder bones and the
		// authored idle/shoot/reload sequences; a p_ model is a one-bone gun
		// mesh with a single 'idle'. The engine refills viewent.curstate every
		// frame regardless of view->model (V_SetupViewModel: modelindex /
		// sequence / animtime, CL_WeaponAnim: body / framerate) — and
		// VR_HideViewModel nulls view->model to hide the camera-locked
		// draw — so resolve the model from the index, not the pointer. The
		// animation state is what R_StudioEstimateFrame consumes; the
		// platform extractor replicates that math to pose the bones.
		cl_entity_t *view = gEngfuncs.GetViewModel();
		model_t *wm = ( view && view->curstate.modelindex )
			? gEngfuncs.pfnGetModelByIndex( view->curstate.modelindex ) : NULL;
		if( wm && wm->type == mod_studio && wm->cache.data )
		{
			g_vr_weapon_hdr        = wm->cache.data;
			g_vr_weapon_modelindex = view->curstate.modelindex;
			g_vr_weapon_body       = view->curstate.body;
			g_vr_weapon_sequence   = view->curstate.sequence;
			g_vr_weapon_frame      = view->curstate.frame;
			g_vr_weapon_animtime   = view->curstate.animtime;
			g_vr_weapon_framerate  = view->curstate.framerate;
			g_vr_weapon_time       = gEngfuncs.GetClientTime();
		}
		// And the same weapon's third-person p_ model: seen from every side,
		// so it is whole where the viewmodel was never modelled (the side
		// facing away from the old camera, the M4's stock), though one rigid
		// mesh with no animation. The platform draws it in the hand instead
		// of the viewmodel when the player picks world models. Nothing draws
		// a local player's p_ model in first
		// person, so ask for its data rather than trusting it is cached.
		cl_entity_t *player = gEngfuncs.GetLocalPlayer();
		model_t *pm = ( player && player->curstate.weaponmodel )
			? gEngfuncs.pfnGetModelByIndex( player->curstate.weaponmodel ) : NULL;
		if( pm && pm->type == mod_studio )
			g_vr_weapon_world_hdr = IEngineStudio.Mod_Extradata( pm );
		// Sample the world light at the eye (R_LightPoint via the tri API,
		// 0..255) and publish it normalised for the external weapon shader.
		{
			float lv[3] = { 0.0f, 0.0f, 0.0f };
			gEngfuncs.pTriAPI->LightAtPoint( v_origin, lv );
			for( i = 0; i < 3; i++ )
				g_vr_weapon_light[i] = lv[i] * ( 1.0f / 255.0f );
		}
		return;
	}

	if( !g_vr_hand_pose_active )
		return;

	cl_entity_t *player = gEngfuncs.GetLocalPlayer();
	if( !player || !player->curstate.weaponmodel )
		return;

	model_t *mdl = gEngfuncs.pfnGetModelByIndex( player->curstate.weaponmodel );
	if( !mdl )
		return;

	// Egon's backpack is rigged to the body (no hand bone in p_egon), so
	// hand-anchoring the whole model drives the pack into the player.
	// Fall back to the stock viewmodel — hand-directed aim still applies.
	if( strstr( mdl->name, "egon" ))
		return;

	// Rendered camera = last refdef view + head override (mirrors the
	// engine's V_RenderView composition; refdef values are one frame old
	// but only carry the slow game-side motion).
	float camorg[3], camang[3];
	for( i = 0; i < 3; i++ )
	{
		camorg[i] = v_origin[i];
		camang[i] = v_angles[i];
	}
	if( g_vr_cam_override[0] != 0.0f )
	{
		float yawrad = camang[1] * ( M_PI_F / 180.0f );
		float ys = sinf( yawrad ), yc = cosf( yawrad );
		camorg[0] += yc * g_vr_cam_override[4] - ys * g_vr_cam_override[5];
		camorg[1] += ys * g_vr_cam_override[4] + yc * g_vr_cam_override[5];
		camorg[2] += g_vr_cam_override[6];
		camang[0]  = g_vr_cam_override[1];
		camang[1] += g_vr_cam_override[2];
		camang[2]  = g_vr_cam_override[3];
	}

	vec3_t f, r, u;
	gEngfuncs.pfnAngleVectors( camang, f, r, u );

	// Camera-local (x fwd, y left, z up) -> world.
	const float *hp = g_vr_hand_pose;
	float org[3], wf[3], wu[3];
	for( i = 0; i < 3; i++ )
	{
		org[i] = camorg[i] + f[i] * hp[0] - r[i] * hp[1] + u[i] * hp[2];
		wf[i]  =             f[i] * hp[3] - r[i] * hp[4] + u[i] * hp[5];
		wu[i]  =             f[i] * hp[6] - r[i] * hp[7] + u[i] * hp[8];
	}

	// Hand-bone alignment: E rotates entity space so the model's hand
	// bone frame lands on the real hand's frame (bone X → hand forward,
	// Y → left, Z → up), and the origin puts the bone at the hand:
	// E = [wf wl wu]·R_hb^T, O = hand − E·t_hb. Cached per model.
	static int s_hbModel = -1;
	static qboolean s_hbValid = false;
	static float s_hbR[3][3], s_hbT[3];
	if( s_hbModel != player->curstate.weaponmodel )
	{
		s_hbModel = player->curstate.weaponmodel;
		s_hbValid = ( mdl->type == mod_studio && mdl->cache.data )
			? VR_HandBonePose((studiohdr_t *)mdl->cache.data, s_hbR, s_hbT )
			: false;
		if( !s_hbValid )
		{
			// identity fallback: entity axes = hand axes, bone at origin
			memset( s_hbR, 0, sizeof( s_hbR ));
			s_hbR[0][0] = s_hbR[1][1] = s_hbR[2][2] = 1.0f;
			s_hbT[0] = s_hbT[1] = s_hbT[2] = 0.0f;
			s_hbValid = true;
		}
	}

	float wl[3]; // world left = up × fwd (xash: fwd × left = up)
	wl[0] = wu[1]*wf[2] - wu[2]*wf[1];
	wl[1] = wu[2]*wf[0] - wu[0]*wf[2];
	wl[2] = wu[0]*wf[1] - wu[1]*wf[0];

	// Cosmetic grip correction: Valve's p_ hand-bone frame doesn't line up
	// perfectly with ARKit's hand frame. Roll the target frame about the
	// barrel (wf) so the gun sits upright, and nudge it back toward the
	// wrist. Tune here.
	{
		const float rollRad = VR_GRIP_ROLL_DEG * ( M_PI_F / 180.0f );
		float c = cosf( rollRad ), s = sinf( rollRad );
		for( i = 0; i < 3; i++ )
		{
			float nl =  c * wl[i] + s * wu[i];
			float nu = -s * wl[i] + c * wu[i];
			wl[i] = nl; wu[i] = nu;
		}
		const float push = VR_GRIP_PUSH_CM * 0.01f * 39.37f; // cm → units
		for( i = 0; i < 3; i++ )
			org[i] -= wf[i] * push;
	}

	float E[3][3], W[3][3];
	for( i = 0; i < 3; i++ )
	{
		W[i][0] = wf[i]; W[i][1] = wl[i]; W[i][2] = wu[i];
	}
	for( i = 0; i < 3; i++ )
		for( int j = 0; j < 3; j++ )
			E[i][j] = W[i][0]*s_hbR[j][0] + W[i][1]*s_hbR[j][1] + W[i][2]*s_hbR[j][2];
	for( i = 0; i < 3; i++ )
		org[i] -= E[i][0]*s_hbT[0] + E[i][1]*s_hbT[1] + E[i][2]*s_hbT[2];

	// Euler decomposition in Matrix3x4_CreateFromEntity's own convention
	// (col0 = (cp·cy, cp·sy, −sp), m21 = sr·cp, m22 = cr·cp).
	float ang[3];
	ang[PITCH] = atan2f( -E[2][0], sqrtf( E[0][0]*E[0][0] + E[1][0]*E[1][0] )) * ( 180.0f / M_PI_F );
	ang[YAW]   = atan2f( E[1][0], E[0][0] ) * ( 180.0f / M_PI_F );
	ang[ROLL]  = atan2f( E[2][1], E[2][2] ) * ( 180.0f / M_PI_F );

	memset( (void *)&gun.curstate, 0, sizeof( gun.curstate ));
	gun.index = 0;
	gun.model = mdl;
	gun.curstate.modelindex = player->curstate.weaponmodel;
	gun.curstate.entityType = ET_NORMAL;
	gun.curstate.rendermode = kRenderNormal;
	gun.curstate.renderamt = 255;
	gun.curstate.sequence = 0;
	gun.curstate.frame = 0.0f;
	for( i = 0; i < 3; i++ )
	{
		gun.origin[i] = org[i];
		// studio render negates entity pitch ("stupid quake bug") —
		// pre-negate so the rendered rotation matches `ang`.
		gun.angles[i] = ( i == PITCH ) ? -ang[i] : ang[i];
		gun.curstate.origin[i] = gun.origin[i];
		gun.curstate.angles[i] = gun.angles[i];
		gun.latched.prevorigin[i] = gun.origin[i];
		gun.latched.prevangles[i] = gun.angles[i];
	}

	gEngfuncs.CL_CreateVisibleEntity( ET_NORMAL, &gun );
	g_vr_hand_weapon_drawn = 1; // weapon is at the hand; hide the viewmodel
}

/*
=========================
VR_HideViewModel

Hook: end of V_CalcNormalRefdef (view.cpp).

When the weapon was drawn at the hand as a world entity (VR_AddHandWeapon
set g_vr_hand_weapon_drawn), hide the camera-locked viewmodel. The engine
re-sets viewent.model every frame (V_SetupViewModel), so this reverts
automatically when hand tracking drops or the weapon falls back to the
viewmodel (egon).
=========================
*/
void VR_HideViewModel( void )
{
	cl_entity_t *view = gEngfuncs.GetViewModel();
	if( g_vr_hand_weapon_drawn && view )
		view->model = NULL;
}

// Fills g_vr_body_state from a finished normal refdef. The floor is found by
// a point trace straight down from the player origin; standing on a ledge
// with the centre over a drop, the trace can miss what the hull stands on,
// so a miss while on ground falls back to the standing hull's bottom.
static void V_PublishBodyState( struct ref_params_s *pparams )
{
	float onground = pparams->onground != -1 ? 1.0f : 0.0f;
	vec3_t end;
	VectorCopy( pparams->simorg, end );
	end[2] -= 64.0f;
	pmtrace_t *tr = gEngfuncs.PM_TraceLine( pparams->simorg, end, PM_TRACELINE_PHYSENTSONLY, 2, -1 );
	float floorz = pparams->simorg[2] - 36.0f;
	if( tr && tr->fraction < 1.0f && ( !onground || pparams->simorg[2] - tr->endpos[2] <= 37.0f ))
		floorz = tr->endpos[2];
	else if( !onground )
		floorz = end[2];

	float yaw = pparams->cl_viewangles[YAW] * ( M_PI_F / 180.0f );
	float c = cosf( yaw ), s = sinf( yaw );
	g_vr_body_state[0] = pparams->vieworg[2] - floorz;
	g_vr_body_state[1] = onground;
	g_vr_body_state[2] = (float)pparams->waterlevel;
	g_vr_body_state[3] =  c * pparams->simvel[0] + s * pparams->simvel[1];
	g_vr_body_state[4] = -s * pparams->simvel[0] + c * pparams->simvel[1];
	g_vr_body_state[5] = pparams->simvel[2];
	g_vr_body_state[6] += 1.0f;
}

// Traces the aim ray the server will fire along — from the muzzle, along the
// composed view plus the aim offset — and publishes how far it runs, so the
// reticle sits exactly where a shot lands. Players, monsters and brush
// entities all stop it, as they stop a bullet.
static void V_PublishAimHit( struct ref_params_s *pparams )
{
	// The egon fires along the view, not the hand (dlls/vr/vr_player.cpp
	// VR_ItemPostFrame), so there is no barrel ray to mark. Weapon id from
	// the HUD publish (vr_hud.cpp), in this game's numbering.
	cl_entity_t *local = gEngfuncs.GetLocalPlayer();
	if( g_vr_muzzle_offset_cl[3] <= 0.0f || !local || (int)g_vr_hud_state[4] == VR_WeaponEgonId() )
	{
		g_vr_aim_hit[1] = -1.0f;
		return;
	}
	const bool vr = g_vr_cam_override[0] > 0.0f;
	const float viewYaw = pparams->cl_viewangles[YAW] + ( vr ? g_vr_cam_override[2] : 0.0f );
	vec3_t angles, forward, eye, muzzle, end;
	angles[PITCH] = ( vr ? g_vr_cam_override[1] : pparams->cl_viewangles[PITCH] ) + g_vr_aim_offset_cl[0];
	angles[YAW] = viewYaw + g_vr_aim_offset_cl[1];
	angles[ROLL] = 0.0f;
	AngleVectors( angles, forward, NULL, NULL );

	VectorAdd( pparams->simorg, pparams->viewheight, eye );
	const float *o = g_vr_muzzle_offset_cl;
	const float y = viewYaw * ( M_PI_F / 180.0f ), c = cosf( y ), s = sinf( y );
	muzzle[0] = eye[0] + c * o[0] - s * o[1];
	muzzle[1] = eye[1] + s * o[0] + c * o[1];
	muzzle[2] = eye[2] + o[2];

	// Same rule as the shot: a muzzle behind a wall fires from the eye, and
	// then there is no honest spot on the far side of the barrel to mark.
	pmtrace_t *wall = gEngfuncs.PM_TraceLine( eye, muzzle, PM_TRACELINE_PHYSENTSONLY, 2, -1 );
	if( !wall || wall->fraction < 1.0f || wall->startsolid )
	{
		g_vr_aim_hit[1] = -1.0f;
		return;
	}

	const float range = 8192.0f;
	VectorMA( muzzle, range, forward, end );
	pmtrace_t tr;
	gEngfuncs.pEventAPI->EV_SetUpPlayerPrediction( false, true );
	gEngfuncs.pEventAPI->EV_PushPMStates();
	gEngfuncs.pEventAPI->EV_SetSolidPlayers( local->index - 1 );
	gEngfuncs.pEventAPI->EV_SetTraceHull( 2 );
	gEngfuncs.pEventAPI->EV_PlayerTrace( muzzle, end, PM_NORMAL, -1, &tr );
	gEngfuncs.pEventAPI->EV_PopPMStates();

	g_vr_aim_hit[0] = tr.fraction * range;
	g_vr_aim_hit[1] = tr.fraction < 1.0f && !tr.startsolid ? 1.0f : -1.0f;
}

/*
=========================
VR_NormalRefdefDone

Hook: V_CalcRefdef (view.cpp), right after the non-paused V_CalcNormalRefdef.
=========================
*/
void VR_NormalRefdefDone( struct ref_params_s *pparams )
{
	V_PublishBodyState( pparams );
	V_PublishAimHit( pparams );
}

/*
=========================
Analog stick

Movement directions the analog stick is pushed past, as usercmd button
bits; CL_CreateMove ORs them in (hook in input.cpp).
=========================
*/
int g_vr_stick_buttons = 0;

extern kbutton_t in_speed;
extern cvar_t *cl_forwardspeed;
extern cvar_t *cl_sidespeed;
extern cvar_t *cl_movespeedkey;

/*
=========================
VR_StickMove

Hook: FWGSInput::IN_Move (input_xash3d.cpp), in place of the stock
`if( ac_movecount )` block, which it always handles (returns true).

The headset's analog movers (gamepad stick, pinch joystick, arm swinging)
arrive here while the keyboard may be held too. Stock replaced the keys'
move with the stick's whenever the stick was off centre, and
IN_ToggleButtons released held movement keys when the stick came back — so
a stick barely off centre (a swinging arm settling) dropped WASD to a
crawl. Add the two instead, capped at maxspeed, and report the stick's
directions as button bits (ladders read IN_FORWARD) without touching the
keys' own state. Neither alone moves differently from stock.
=========================
*/
bool VR_StickMove( usercmd_t *cmd, float ac_forwardmove, float ac_sidemove, int ac_movecount )
{
	g_vr_stick_buttons = 0;
	if( !ac_movecount )
		return true;

	float fwd = ac_forwardmove / ac_movecount, side = ac_sidemove / ac_movecount;
	float stickfwd = fwd * cl_forwardspeed->value, stickside = side * cl_sidespeed->value;
	if( in_speed.state & 1 )
	{
		stickfwd *= cl_movespeedkey->value;
		stickside *= cl_movespeedkey->value;
	}
	cmd->forwardmove += stickfwd;
	cmd->sidemove += stickside;

	float spd = gEngfuncs.GetClientMaxspeed();
	float fmov = sqrt( cmd->forwardmove * cmd->forwardmove + cmd->sidemove * cmd->sidemove + cmd->upmove * cmd->upmove );
	if( ( stickfwd || stickside ) && spd != 0.0f && fmov > spd )
	{
		cmd->forwardmove *= spd / fmov;
		cmd->sidemove *= spd / fmov;
		cmd->upmove *= spd / fmov;
	}

	if( fwd > 0.7f ) g_vr_stick_buttons |= IN_FORWARD;
	if( fwd < -0.7f ) g_vr_stick_buttons |= IN_BACK;
	if( side > 0.9f ) g_vr_stick_buttons |= IN_MOVERIGHT;
	if( side < -0.9f ) g_vr_stick_buttons |= IN_MOVELEFT;
	return true;
}

// LambdaVision VR layer, server side: the hooks dlls/player.cpp calls.
// Implementations in vr_player.cpp. Copied into dlls/vr/ by
// VisionPort/hlsdk-vr/apply.sh.
#pragma once
#ifndef VR_SERVER_H
#define VR_SERVER_H

class CBasePlayer;
class CBaseEntity;

// CBasePlayer::GetGunPosition, before returning: moves origin to the muzzle
// of the gun in the hand while inside the weapon frame.
void VR_GunPosition( CBasePlayer *pPlayer, Vector &origin );

// CBasePlayer::ItemPostFrame, in place of m_pActiveItem->ItemPostFrame():
// runs the weapon frame along the platform's aim ray.
void VR_ItemPostFrame( CBasePlayer *pPlayer );

// CBasePlayer::PlayerUse: true while the immersive use ray is active, which
// defers the train-mount attempt until after the entity cone search.
int VR_UseActive( void );
// PlayerUse, after UTIL_MakeVectors( pev->v_angle ): aims and tightens the
// selection cone along the fingertip ray when active.
void VR_UseCone( CBasePlayer *pPlayer, float *flMaxDot );
// PlayerUse, nothing usable found: the deferred train mount. True when the
// player now drives a train (PlayerUse returns).
int VR_UseMountTrain( CBasePlayer *pPlayer );

// CBasePlayer::PreThink, before the train speed control block.
void VR_TrainReset( void );
// PreThink train block, right before iGearId = TrainSpeed(...): steps the
// train toward the platform's throttle and publishes its gear.
void VR_TrainThink( CBasePlayer *pPlayer, CBaseEntity *pTrain );

#endif // VR_SERVER_H

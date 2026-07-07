//
//  Lambda_SpatialAudio.c
//  LambdaVision
//
//  Installs xash3d-fwgs's client sound interface (common/sound_api.h) and
//  forwards 3D sound channels to the Swift spatial audio engine
//  (SpatialAudioEngine.swift) for per-source HRTF rendering, while the
//  engine's own mixer keeps producing the head-locked stereo "bed"
//  (music, UI sounds, the player's own sounds).
//
//  Ownership rules per channel, chosen around the engine mixer's behavior:
//   - client-entity / 2D / no-attenuation channels: NOT taken — the bed
//     mixes them exactly as stock xash (we replicate stock panning in the
//     spatialize hook since installing the hook disables the built-in).
//   - regular world channels: taken — muted in the bed (leftvol=rightvol=0)
//     but kept alive so the engine still tracks the emitting entity; we
//     refresh the origin every frame in the spatialize hook. The mixer
//     frees muted NON-looping channels after 0.1 s (inaudible timeout) —
//     Swift treats channel_free as "detach": one-shots play to completion,
//     loops stop.
//   - sentences (VOX speech): the word chain is snapshotted and forwarded
//     whole, then the engine channel is freed at the next safe point.
//     Muting a sentence channel would freeze its word-advance machinery
//     (it only progresses while being mixed) and leak the channel slot
//     forever. Talker position is tracked separately per sentence slot.
//
//  Threading: every callback here runs on the GL worker (the engine
//  thread). Swift copies what it needs synchronously and hops to its own
//  audio control queue.
//

#include <string.h>
#include <stdio.h>

// wavdata_t replica of engine/common/common.h:529 (the engine header is
// too heavy to include here; the tree is pinned by xash3d-visionos.patch,
// re-check on engine upgrades). sound_api.h uses the type by name.
typedef unsigned int   uint;
typedef unsigned short word;
typedef unsigned char  byte;

typedef struct wavdata_s
{
	size_t size;
	uint   loop_start;
	uint   samples;
	uint   type;
	uint   flags;
	word   rate;
	byte   width;
	byte   channels;
	byte   buffer[];
} wavdata_t;

#define LAMBDA_SOUND_LOOPED ( 1U << 0 ) // sndFlags_t SOUND_LOOPED

// From const.h — sound_api.h expects the includer to have it.
#define NUM_AMBIENTS 4

#include "sound_api.h"

#include <math.h>
// Minimal replicas of the xash3d_mathlib.h vector helpers we use.
#define VectorCopy( a, b )     do { (b)[0] = (a)[0]; (b)[1] = (a)[1]; (b)[2] = (a)[2]; } while( 0 )
#define VectorSubtract( a, b, c ) do { (c)[0] = (a)[0] - (b)[0]; (c)[1] = (a)[1] - (b)[1]; (c)[2] = (a)[2] - (b)[2]; } while( 0 )
#define DotProduct( a, b )     ((a)[0] * (b)[0] + (a)[1] * (b)[1] + (a)[2] * (b)[2])

static float VectorNormalizeLength( vec3_t v )
{
	float len = sqrtf( DotProduct( v, v ));
	if( len > 0.0f )
	{
		float ilen = 1.0f / len;
		v[0] *= ilen; v[1] *= ilen; v[2] *= ilen;
	}
	return len;
}

#include "Lambda_SpatialAudio.h"

// Engine internals reachable at the single-binary static link.
extern void S_FreeChannel( channel_t *ch );
extern wavdata_t *S_LoadSound( sfx_t *sfx ); // s_load.c
extern snd_globals_t snd; // engine sound globals (s_main.c)

static lambda_spatial_callbacks_t g_cb;
static int                        g_cb_set;
static const sound_api_t         *g_api;
static snd_globals_t             *g_snd;

#define LAMBDA_SND_MAX_CHANNELS 256
static unsigned      g_gen[LAMBDA_SND_MAX_CHANNELS];
static unsigned char g_taken[LAMBDA_SND_MAX_CHANNELS];

// Engine channels to free at the next pfnS_UpdateSound (a safe point in
// the tick; freeing inside pfnS_UpdateChannel would rip the channel out
// from under S_StartSound's caller). Each entry captures the channel's
// identity at queue time — the engine can free+reuse the index before we
// run, and blindly freeing would kill an innocent successor (observed:
// truncated footsteps/speech, silenced loops).
static struct {
	int   idx;
	short entnum;
} g_kill[LAMBDA_SND_MAX_CHANNELS];
static int g_kill_count;

// Active spatialized sentences: engine channel is gone, so the talker
// entity is tracked here for per-frame position updates. Slots are
// round-robin; Swift ignores updates for slots it has finished.
static struct {
	int   active;
	short entnum;
	vec3_t origin;
} g_sentence[LAMBDA_SPATIAL_MAX_SENTENCES];
static int g_sentence_rr;

void lambda_spatial_set_callbacks(const lambda_spatial_callbacks_t *cb) {
	g_cb = *cb;
	g_cb_set = 1;
}

// ---------------------------------------------------------------------------

static qboolean iface_init( snd_globals_t *globals )
{
	g_snd = globals;
	memset( g_gen, 0, sizeof( g_gen ));
	memset( g_taken, 0, sizeof( g_taken ));
	memset( g_sentence, 0, sizeof( g_sentence ));
	g_kill_count = 0;
	printf( "[LambdaVision] spatial audio: SoundAPI installed (%d channels)\n",
	        g_snd->max_channels );
	return true;
}

static void iface_shutdown( void )
{
	g_snd = NULL;
}

static int lambda_channel_index( const channel_t *ch )
{
	if( !g_snd || !g_snd->channels ) return -1;
	int idx = (int)( ch - g_snd->channels );
	return ( idx >= 0 && idx < LAMBDA_SND_MAX_CHANNELS ) ? idx : -1;
}

// Snapshot a sentence's word chain into a flat descriptor array.
static void lambda_forward_sentence( int idx, const channel_t *ch )
{
	lambda_spatial_word_t words[LAMBDA_SPATIAL_MAX_WORDS];
	int count = 0;

	// Inaudible sentence (fully attenuated at this distance): don't spend
	// a slot on it — leave it untaken so the bed mutes it and the engine's
	// inaudible timeout reclaims the channel. Maps fire scripted chatter
	// all over; only nearby speech should occupy sentence slots.
	if( g_snd )
	{
		vec3_t d;
		VectorSubtract( ch->origin, g_snd->origin, d );
		if( sqrtf( DotProduct( d, d )) * ch->dist_mult >= 1.0f )
			return;
	}

	for( const voxword_t *w = ch->words; w && w->sfx && count < LAMBDA_SPATIAL_MAX_WORDS; w++ )
	{
		// VOX words load LAZILY — the stock mixer pulls each word's wav
		// only when playback reaches it. We consume the whole sentence up
		// front, so force-load any word not yet cached (tiny files, engine
		// thread, sentence start — acceptable).
		const wavdata_t *wav = w->sfx->cache;
		if( !wav ) wav = S_LoadSound( w->sfx );
		if( !wav || !wav->samples ) continue;

		lambda_spatial_word_t *out = &words[count++];
		out->pcm        = wav->buffer;
		out->size_bytes = (unsigned)wav->size;
		out->samples    = wav->samples;
		out->rate       = wav->rate;
		out->width      = wav->width;
		out->channels   = wav->channels;
		out->volume     = w->volume ? w->volume : 100;
		out->pitch      = w->pitch ? w->pitch : 100;
		out->start      = w->start;
		out->end        = ( w->end && w->end < 100 ) ? w->end : 100;
	}
	if( !count ) return;

	int slot = g_sentence_rr;
	g_sentence_rr = ( g_sentence_rr + 1 ) % LAMBDA_SPATIAL_MAX_SENTENCES;
	g_sentence[slot].active = 1;
	g_sentence[slot].entnum = ch->entnum;
	VectorCopy( ch->origin, g_sentence[slot].origin );

	g_cb.sentence_start( slot, words, count, ch->origin,
	                     ch->dist_mult, ch->entnum,
	                     ch->master_vol / 255.0f );

	// Free the engine channel at the next safe point (see file header).
	if( g_kill_count < LAMBDA_SND_MAX_CHANNELS )
	{
		g_kill[g_kill_count].idx    = idx;
		g_kill[g_kill_count].entnum = ch->entnum;
		g_kill_count++;
	}
}

static void iface_update_channel( int ch_idx, const channel_t *ch, sound_t handle )
{
	if( ch_idx < 0 || ch_idx >= LAMBDA_SND_MAX_CHANNELS ) return;

	if( !ch )
	{
		if( g_taken[ch_idx] )
		{
			g_taken[ch_idx] = 0;
			g_cb.channel_free( ch_idx, g_gen[ch_idx] );
		}
		return;
	}

	// Bed keeps: the player's own sounds, menu/local sounds, and anything
	// without distance attenuation (announcements, some scripted speech).
	int is_client = g_snd && ch->entnum == g_snd->entnum;
	int is_2d     = ch->dist_mult <= 0.0f || ( ch->flags & FL_CHAN_LOCAL_SOUND );

	if( is_client || is_2d )
	{
		if( g_taken[ch_idx] )
		{
			// channel slot was reused for a bed sound
			g_taken[ch_idx] = 0;
			g_cb.channel_free( ch_idx, g_gen[ch_idx] );
		}
		return;
	}

	if( ch->words )
	{
		lambda_forward_sentence( ch_idx, ch );
		return;
	}

	const wavdata_t *wav = ch->sfx ? ch->sfx->cache : NULL;
	if( !wav || !wav->samples ) return;

	if( g_taken[ch_idx] )
		g_cb.channel_free( ch_idx, g_gen[ch_idx] ); // slot reuse: detach old

	g_gen[ch_idx]++;
	g_taken[ch_idx] = 1;

	int looped = ( wav->flags & LAMBDA_SOUND_LOOPED ) && ( ch->flags & FL_CHAN_USE_LOOP );

	g_cb.channel_start( ch_idx, g_gen[ch_idx], handle,
	                    wav->buffer, (unsigned)wav->size, wav->samples,
	                    wav->loop_start, wav->rate, wav->width, wav->channels,
	                    ch->origin, ch->dist_mult, ch->entnum,
	                    ch->master_vol / 255.0f,
	                    ch->basePitch > 0 ? ch->basePitch : 100,
	                    looped );
}

// Stock xash panning (s_main.c S_SpatializeChannel) for bed channels —
// installing the spatialize hook disables the engine's own implementation.
static void lambda_bed_pan( channel_t *ch, float dot, float dist )
{
	float scale, lvol, rvol;

	scale = ( 1.0f - dist ) * ( 1.0f + dot );
	rvol  = ch->master_vol * scale;
	scale = ( 1.0f - dist ) * ( 1.0f - dot );
	lvol  = ch->master_vol * scale;

	ch->rightvol = (short)( rvol < 0 ? 0 : ( rvol > 255 ? 255 : rvol ));
	ch->leftvol  = (short)( lvol < 0 ? 0 : ( lvol > 255 ? 255 : lvol ));
}

static void iface_spatialize( channel_t *ch )
{
	int idx = lambda_channel_index( ch );

	// Player's own sounds: always full volume (stock behavior).
	if( g_snd && ch->entnum == g_snd->entnum )
	{
		ch->leftvol = ch->rightvol = ch->master_vol;
		return;
	}

	// Refresh the origin from the emitting entity (stock behavior; with
	// our hook installed the engine no longer does this itself).
	if( !( ch->flags & FL_CHAN_STATIC_SOUND ))
	{
		if( !g_api->CL_GetEntitySpatialization( ch ))
		{
			ch->leftvol = ch->rightvol = 0;
			return;
		}
	}

	if( idx >= 0 && g_taken[idx] )
	{
		// Ours: keep the bed silent, stream the position to Swift.
		g_cb.channel_update( idx, g_gen[idx], ch->origin,
		                     ch->master_vol / 255.0f );
		ch->leftvol = ch->rightvol = 0;
		return;
	}

	// Bed channel: replicate stock distance/pan math.
	vec3_t source_vec;
	VectorSubtract( ch->origin, g_snd->origin, source_vec );

	float dist = VectorNormalizeLength( source_vec );
	float dot  = DotProduct( g_snd->right, source_vec );

	if( ch->dist_mult <= 0.0f ) dot = 0.0f; // don't pan unattenuated sounds

	lambda_bed_pan( ch, dot, dist * ch->dist_mult );
}

static void iface_update_sound( void )
{
	if( !g_snd ) return;

	// Safe point inside the tick: free sentence channels queued above —
	// but only if the slot still holds the SAME sentence (words present,
	// same emitting entity). The engine may have reused the index.
	for( int i = 0; i < g_kill_count; i++ )
	{
		channel_t *ch = &g_snd->channels[g_kill[i].idx];
		if( ch->sfx && ch->words && ch->entnum == g_kill[i].entnum )
			S_FreeChannel( ch );
	}
	g_kill_count = 0;

	// Listener pose (head-tracked: snd.origin/vectors come from the
	// rvp the bridge already overrides with headset orientation).
	g_cb.listener_update( g_snd->origin, g_snd->forward, g_snd->right, g_snd->up );

	// Track talkers of active spatialized sentences. A scratch channel
	// is enough for CL_GetEntitySpatialization (reads entnum, writes
	// origin/dist_mult-independent fields).
	for( int i = 0; i < LAMBDA_SPATIAL_MAX_SENTENCES; i++ )
	{
		if( !g_sentence[i].active ) continue;

		channel_t tmp;
		memset( &tmp, 0, sizeof( tmp ));
		tmp.entnum = g_sentence[i].entnum;
		VectorCopy( g_sentence[i].origin, tmp.origin );

		if( g_api->CL_GetEntitySpatialization( &tmp ))
			VectorCopy( tmp.origin, g_sentence[i].origin );

		g_cb.sentence_move( i, g_sentence[i].origin );
	}
}

static void iface_free_sound( sfx_t *sfx, sound_t handle )
{
	g_cb.sfx_free( handle );
}

// ---------------------------------------------------------------------------

// dlsym'd by the engine's CL_LoadProgs alongside the other HUD_* client
// exports (visionOS COM_LoadLibrary resolves from RTLD_DEFAULT, i.e. the
// app binary). Swift must register callbacks BEFORE engine init or the
// engine falls back to the stock (bed-only) sound path.
__attribute__((used, visibility("default")))
int HUD_GetSoundInterface( int version, const sound_api_t *api, sound_interface_t *iface )
{
	if( version != CL_SOUND_INTERFACE_VERSION ) return 0;
	if( !g_cb_set )
	{
		printf( "[LambdaVision] spatial audio: no callbacks registered, using stock sound\n" );
		return 0;
	}

	g_api = api;
	// The engine's success path in S_InitSoundAPI returns without invoking
	// pfnS_Init, so bind the globals directly — same binary, same symbol.
	iface_init( &snd );

	iface->version             = CL_SOUND_INTERFACE_VERSION;
	iface->pfnS_Init           = iface_init;
	iface->pfnS_Shutdown       = iface_shutdown;
	iface->pfnS_UpdateSound    = iface_update_sound;
	iface->pfnS_PaintChannels  = NULL; // bed mixes as stock
	iface->pfnS_UpdateChannel  = iface_update_channel;
	iface->pfnS_UpdateRawChannel = NULL; // music/voice stay in the bed
	iface->pfnS_Spatialize     = iface_spatialize;
	iface->pfnS_FreeSound      = iface_free_sound;
	return 1;
}

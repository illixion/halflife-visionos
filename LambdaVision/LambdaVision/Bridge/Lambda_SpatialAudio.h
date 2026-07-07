//
//  Lambda_SpatialAudio.h
//  LambdaVision
//
//  C↔Swift interface for per-source spatial audio. The C side
//  (Lambda_SpatialAudio.c) hooks xash's client SoundAPI on the engine
//  thread; Swift (SpatialAudioEngine.swift) registers this callback table
//  BEFORE engine init and renders sources with AVAudioEnvironmentNode.
//
//  All positions/vectors are xash world coordinates (units: inches,
//  +X forward / +Y left / +Z up at yaw 0). Swift converts to Apple basis.
//  All callbacks fire on the GL worker thread; PCM pointers are only
//  guaranteed valid for the duration of the call — copy synchronously.
//

#ifndef Lambda_SpatialAudio_h
#define Lambda_SpatialAudio_h

#define LAMBDA_SPATIAL_MAX_WORDS     32
#define LAMBDA_SPATIAL_MAX_SENTENCES 32

typedef struct lambda_spatial_word_s {
	const void    *pcm;        // interleaved PCM, width×channels per frame
	unsigned       size_bytes;
	unsigned       samples;    // frames
	unsigned       rate;       // Hz
	unsigned char  width;      // bytes per sample (1 = u8, 2 = s16)
	unsigned char  channels;   // 1 mono / 2 stereo
	unsigned short volume;     // percent, 1-100
	unsigned short pitch;      // percent, 100 = normal
	unsigned char  start;      // trim: playback starts at this percent
	unsigned char  end;        // trim: playback ends at this percent
} lambda_spatial_word_t;

typedef struct lambda_spatial_callbacks_s {
	// A world channel started (idx+gen identify it; gen disambiguates
	// slot reuse). looped=1: loop from loop_start (frames) until freed.
	void (*channel_start)(int idx, unsigned gen, int sfx_handle,
	                      const void *pcm, unsigned size_bytes,
	                      unsigned samples, unsigned loop_start,
	                      unsigned rate, int width, int channels,
	                      const float *origin3, float dist_mult,
	                      int entnum, float volume, int pitch, int looped);

	// A VOX sentence started: play the word chain in order (per-word
	// trim/volume/pitch pre-resolved). The engine channel is discarded;
	// positions arrive via sentence_move for this slot.
	void (*sentence_start)(int slot, const lambda_spatial_word_t *words,
	                       int count, const float *origin3, float dist_mult,
	                       int entnum, float volume);

	// Per-frame origin/volume refresh for an active channel.
	void (*channel_update)(int idx, unsigned gen, const float *origin3,
	                       float volume);

	// Engine channel gone. One-shots: let them play out (the mixer
	// times out muted channels after 0.1 s — this is NOT a stop request).
	// Loops: stop now.
	void (*channel_free)(int idx, unsigned gen);

	// Per-frame talker position for an active sentence slot.
	void (*sentence_move)(int slot, const float *origin3);

	// Per-frame listener pose (game camera, already head-tracked).
	void (*listener_update)(const float *origin3, const float *forward3,
	                        const float *right3, const float *up3);

	// The engine evicted this sfx from its cache — drop cached buffers.
	void (*sfx_free)(int sfx_handle);
} lambda_spatial_callbacks_t;

// Register callbacks. MUST be called before lambda_gl_worker_engine_init,
// otherwise the engine initializes with the stock (head-locked) mixer.
void lambda_spatial_set_callbacks(const lambda_spatial_callbacks_t *cb);

#endif /* Lambda_SpatialAudio_h */

// The extractor's weapon path reads these client-published globals. The body
// slot does not, but the translation unit still needs them defined.
void *g_vr_weapon_hdr = 0;
int   g_vr_weapon_modelindex = 0, g_vr_weapon_body = 0, g_vr_weapon_sequence = 0;
float g_vr_weapon_frame = 0, g_vr_weapon_animtime = 0, g_vr_weapon_framerate = 1, g_vr_weapon_time = 0;
float g_vr_weapon_light[3] = { 1, 1, 1 };
float g_vr_body_state[7] = { 64, 1, 0, 0, 0, 0, 0 };
int   g_vr_hud_native = 1;
float g_vr_hud_state[14] = { 0 };

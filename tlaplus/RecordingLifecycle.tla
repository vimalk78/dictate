--------------------------- MODULE RecordingLifecycle ---------------------------
(*
 * TLA+ specification of the dictate daemon's recording lifecycle.
 *
 * Actors:
 *   M  — Main loop (accepts, polls STOP_FLAG, hard timeout)
 *   C  — prebuf_callback (speech/silence detection, callback timeouts)
 *   H  — mic_monitor (detects device loss, aborts recording)
 *   P  — PTT client (creates STOP_FLAG on key release)
 *
 * Verified properties:
 *   1. Termination: every recording reaches "done"
 *   2. No lost STOP_FLAG: legitimate flags are never discarded as stale
 *   3. No stuck state
 *
 * Timeouts are modeled abstractly as nondeterministic events gated by
 * a "time_advanced" boolean, avoiding large integer state spaces.
 *)

EXTENDS Integers

VARIABLES
    rec_active,             \* Boolean
    rec_speech_detected,    \* Boolean

    stop_flag_exists,       \* Boolean
    stop_flag_is_fresh,     \* Boolean: TRUE if created after rec_start_wall

    mic_alive,              \* Boolean
    mic_silent_enough,      \* Boolean: enough silent checks to declare lost

    callback_running,       \* Boolean: audio device working
    has_speech,             \* Boolean: speech in audio

    time_advanced,          \* Boolean: enough time passed for hard timeout
    callback_time_advanced, \* Boolean: enough callback ticks for wait/silence timeout

    m_state,                \* "idle"|"accepting"|"init_rec"|"polling"|"processing"|"done"
    p_state                 \* "idle"|"key_down"|"key_up"|"waiting"

vars == <<rec_active, rec_speech_detected,
          stop_flag_exists, stop_flag_is_fresh,
          mic_alive, mic_silent_enough,
          callback_running, has_speech,
          time_advanced, callback_time_advanced,
          m_state, p_state>>

-----------------------------------------------------------------------------
Init ==
    /\ rec_active = FALSE
    /\ rec_speech_detected = FALSE
    /\ stop_flag_exists = FALSE
    /\ stop_flag_is_fresh = FALSE
    /\ mic_alive = TRUE
    /\ mic_silent_enough = FALSE
    /\ callback_running = TRUE
    /\ has_speech = FALSE
    /\ time_advanced = FALSE
    /\ callback_time_advanced = FALSE
    /\ m_state = "idle"
    /\ p_state = "idle"

-----------------------------------------------------------------------------
(* Time advancement — abstract: "enough time has passed" *)

TimeAdvance ==
    /\ time_advanced = FALSE
    /\ time_advanced' = TRUE
    /\ UNCHANGED <<rec_active, rec_speech_detected,
                   stop_flag_exists, stop_flag_is_fresh,
                   mic_alive, mic_silent_enough,
                   callback_running, has_speech,
                   callback_time_advanced,
                   m_state, p_state>>

CallbackTimeAdvance ==
    /\ callback_time_advanced = FALSE
    /\ callback_running = TRUE
    /\ rec_active = TRUE
    /\ callback_time_advanced' = TRUE
    /\ UNCHANGED <<rec_active, rec_speech_detected,
                   stop_flag_exists, stop_flag_is_fresh,
                   mic_alive, mic_silent_enough,
                   callback_running, has_speech,
                   time_advanced,
                   m_state, p_state>>

-----------------------------------------------------------------------------
(* PTT Client *)

PTT_KeyDown ==
    /\ p_state = "idle"
    /\ m_state = "idle"
    /\ p_state' = "key_down"
    /\ m_state' = "accepting"
    \* Any existing STOP_FLAG becomes stale (rec_start_wall = now)
    /\ stop_flag_is_fresh' = FALSE
    /\ UNCHANGED <<rec_active, rec_speech_detected,
                   stop_flag_exists,
                   mic_alive, mic_silent_enough,
                   callback_running, has_speech,
                   time_advanced, callback_time_advanced>>

PTT_KeyUp ==
    /\ p_state = "key_down"
    /\ stop_flag_exists' = TRUE
    /\ stop_flag_is_fresh' = TRUE    \* created AFTER rec_start_wall
    /\ p_state' = "key_up"
    /\ UNCHANGED <<rec_active, rec_speech_detected,
                   mic_alive, mic_silent_enough,
                   callback_running, has_speech,
                   time_advanced, callback_time_advanced,
                   m_state>>

PTT_WaitDone ==
    /\ p_state = "key_up"
    /\ m_state = "done"
    /\ p_state' = "waiting"
    /\ UNCHANGED <<rec_active, rec_speech_detected,
                   stop_flag_exists, stop_flag_is_fresh,
                   mic_alive, mic_silent_enough,
                   callback_running, has_speech,
                   time_advanced, callback_time_advanced,
                   m_state>>

PTT_Reset ==
    /\ p_state = "waiting"
    /\ p_state' = "idle"
    /\ m_state' = "idle"
    /\ UNCHANGED <<rec_active, rec_speech_detected,
                   stop_flag_exists, stop_flag_is_fresh,
                   mic_alive, mic_silent_enough,
                   callback_running, has_speech,
                   time_advanced, callback_time_advanced>>

-----------------------------------------------------------------------------
(* Main loop *)

M_Accept ==
    /\ m_state = "accepting"
    /\ m_state' = "init_rec"
    /\ UNCHANGED <<rec_active, rec_speech_detected,
                   stop_flag_exists, stop_flag_is_fresh,
                   mic_alive, mic_silent_enough,
                   callback_running, has_speech,
                   time_advanced, callback_time_advanced,
                   p_state>>

M_StartRecording ==
    /\ m_state = "init_rec"
    /\ rec_active' = TRUE
    /\ rec_speech_detected' = FALSE
    /\ time_advanced' = FALSE           \* reset hard timeout clock
    /\ callback_time_advanced' = FALSE   \* reset callback timeout clock
    /\ m_state' = "polling"
    /\ UNCHANGED <<stop_flag_exists, stop_flag_is_fresh,
                   mic_alive, mic_silent_enough,
                   callback_running, has_speech,
                   p_state>>

\* M polls: fresh STOP_FLAG
M_PollStopFlag_Fresh ==
    /\ m_state = "polling"
    /\ rec_active = TRUE
    /\ stop_flag_exists = TRUE
    /\ stop_flag_is_fresh = TRUE
    /\ rec_active' = FALSE
    /\ rec_speech_detected' = TRUE
    /\ stop_flag_exists' = FALSE
    /\ m_state' = "processing"
    /\ UNCHANGED <<stop_flag_is_fresh,
                   mic_alive, mic_silent_enough,
                   callback_running, has_speech,
                   time_advanced, callback_time_advanced,
                   p_state>>

\* M polls: stale STOP_FLAG — clean up
M_PollStopFlag_Stale ==
    /\ m_state = "polling"
    /\ rec_active = TRUE
    /\ stop_flag_exists = TRUE
    /\ stop_flag_is_fresh = FALSE
    /\ stop_flag_exists' = FALSE
    /\ UNCHANGED <<rec_active, rec_speech_detected,
                   stop_flag_is_fresh,
                   mic_alive, mic_silent_enough,
                   callback_running, has_speech,
                   time_advanced, callback_time_advanced,
                   m_state, p_state>>

\* M polls: hard timeout fired
M_PollHardTimeout ==
    /\ m_state = "polling"
    /\ rec_active = TRUE
    /\ time_advanced = TRUE
    /\ rec_active' = FALSE
    /\ m_state' = "processing"
    /\ UNCHANGED <<rec_speech_detected,
                   stop_flag_exists, stop_flag_is_fresh,
                   mic_alive, mic_silent_enough,
                   callback_running, has_speech,
                   time_advanced, callback_time_advanced,
                   p_state>>

\* M observes rec_active=FALSE (set by C or H)
M_PollRecInactive ==
    /\ m_state = "polling"
    /\ rec_active = FALSE
    /\ m_state' = "processing"
    /\ UNCHANGED <<rec_active, rec_speech_detected,
                   stop_flag_exists, stop_flag_is_fresh,
                   mic_alive, mic_silent_enough,
                   callback_running, has_speech,
                   time_advanced, callback_time_advanced,
                   p_state>>

M_Done ==
    /\ m_state = "processing"
    /\ m_state' = "done"
    /\ UNCHANGED <<rec_active, rec_speech_detected,
                   stop_flag_exists, stop_flag_is_fresh,
                   mic_alive, mic_silent_enough,
                   callback_running, has_speech,
                   time_advanced, callback_time_advanced,
                   p_state>>

-----------------------------------------------------------------------------
(* Callback (C) *)

C_DetectSpeech ==
    /\ rec_active = TRUE
    /\ callback_running = TRUE
    /\ has_speech = TRUE
    /\ mic_alive = TRUE
    /\ rec_speech_detected' = TRUE
    /\ UNCHANGED <<rec_active,
                   stop_flag_exists, stop_flag_is_fresh,
                   mic_alive, mic_silent_enough,
                   callback_running, has_speech,
                   time_advanced, callback_time_advanced,
                   m_state, p_state>>

\* Wait timeout: no speech detected, enough callback time passed
C_WaitTimeout ==
    /\ rec_active = TRUE
    /\ callback_running = TRUE
    /\ rec_speech_detected = FALSE
    /\ callback_time_advanced = TRUE
    /\ rec_active' = FALSE
    /\ UNCHANGED <<rec_speech_detected,
                   stop_flag_exists, stop_flag_is_fresh,
                   mic_alive, mic_silent_enough,
                   callback_running, has_speech,
                   time_advanced, callback_time_advanced,
                   m_state, p_state>>

\* Silence timeout: speech detected then quiet
C_SilenceTimeout ==
    /\ rec_active = TRUE
    /\ callback_running = TRUE
    /\ rec_speech_detected = TRUE
    /\ has_speech = FALSE
    /\ callback_time_advanced = TRUE
    /\ rec_active' = FALSE
    /\ UNCHANGED <<rec_speech_detected,
                   stop_flag_exists, stop_flag_is_fresh,
                   mic_alive, mic_silent_enough,
                   callback_running, has_speech,
                   time_advanced, callback_time_advanced,
                   m_state, p_state>>

-----------------------------------------------------------------------------
(* Mic Monitor (H) *)

H_BecameSilentEnough ==
    /\ mic_alive = TRUE
    /\ mic_silent_enough = FALSE
    /\ (~callback_running \/ has_speech = FALSE)
    /\ mic_silent_enough' = TRUE
    /\ UNCHANGED <<rec_active, rec_speech_detected,
                   stop_flag_exists, stop_flag_is_fresh,
                   mic_alive,
                   callback_running, has_speech,
                   time_advanced, callback_time_advanced,
                   m_state, p_state>>

H_MicLost ==
    /\ mic_alive = TRUE
    /\ mic_silent_enough = TRUE
    /\ mic_alive' = FALSE
    /\ mic_silent_enough' = FALSE
    /\ rec_active' = IF rec_active THEN FALSE ELSE rec_active
    /\ UNCHANGED <<rec_speech_detected,
                   stop_flag_exists, stop_flag_is_fresh,
                   callback_running, has_speech,
                   time_advanced, callback_time_advanced,
                   m_state, p_state>>

H_MicReconnect ==
    /\ mic_alive = FALSE
    /\ callback_running = TRUE
    /\ mic_alive' = TRUE
    /\ mic_silent_enough' = FALSE
    /\ UNCHANGED <<rec_active, rec_speech_detected,
                   stop_flag_exists, stop_flag_is_fresh,
                   callback_running, has_speech,
                   time_advanced, callback_time_advanced,
                   m_state, p_state>>

-----------------------------------------------------------------------------
(* Environment — nondeterministic, NO fairness *)

Env_DeviceDrop ==
    /\ callback_running = TRUE
    /\ callback_running' = FALSE
    /\ UNCHANGED <<rec_active, rec_speech_detected,
                   stop_flag_exists, stop_flag_is_fresh,
                   mic_alive, mic_silent_enough,
                   has_speech,
                   time_advanced, callback_time_advanced,
                   m_state, p_state>>

Env_DeviceReconnect ==
    /\ callback_running = FALSE
    /\ callback_running' = TRUE
    /\ UNCHANGED <<rec_active, rec_speech_detected,
                   stop_flag_exists, stop_flag_is_fresh,
                   mic_alive, mic_silent_enough,
                   has_speech,
                   time_advanced, callback_time_advanced,
                   m_state, p_state>>

Env_SpeechStart ==
    /\ mic_alive = TRUE
    /\ callback_running = TRUE
    /\ has_speech' = TRUE
    /\ UNCHANGED <<rec_active, rec_speech_detected,
                   stop_flag_exists, stop_flag_is_fresh,
                   mic_alive, mic_silent_enough,
                   callback_running,
                   time_advanced, callback_time_advanced,
                   m_state, p_state>>

Env_SpeechStop ==
    /\ has_speech' = FALSE
    /\ UNCHANGED <<rec_active, rec_speech_detected,
                   stop_flag_exists, stop_flag_is_fresh,
                   mic_alive, mic_silent_enough,
                   callback_running,
                   time_advanced, callback_time_advanced,
                   m_state, p_state>>

-----------------------------------------------------------------------------
Next ==
    \/ TimeAdvance  \/ CallbackTimeAdvance
    \/ PTT_KeyDown  \/ PTT_KeyUp  \/ PTT_WaitDone  \/ PTT_Reset
    \/ M_Accept  \/ M_StartRecording
    \/ M_PollStopFlag_Fresh  \/ M_PollStopFlag_Stale
    \/ M_PollHardTimeout  \/ M_PollRecInactive  \/ M_Done
    \/ C_DetectSpeech  \/ C_WaitTimeout  \/ C_SilenceTimeout
    \/ H_BecameSilentEnough  \/ H_MicLost  \/ H_MicReconnect
    \/ Env_DeviceDrop  \/ Env_DeviceReconnect
    \/ Env_SpeechStart  \/ Env_SpeechStop

\* System actions get weak fairness; environment actions do not.
\* PTT_KeyUp = user always eventually releases key.
\* TimeAdvance = time always eventually passes.
Fairness ==
    /\ WF_vars(TimeAdvance)
    /\ WF_vars(CallbackTimeAdvance)
    /\ WF_vars(PTT_KeyUp)
    /\ WF_vars(PTT_WaitDone)
    /\ WF_vars(PTT_Reset)
    /\ WF_vars(M_Accept)
    /\ WF_vars(M_StartRecording)
    /\ WF_vars(M_PollStopFlag_Fresh)
    /\ WF_vars(M_PollStopFlag_Stale)
    /\ WF_vars(M_PollHardTimeout)
    /\ WF_vars(M_PollRecInactive)
    /\ WF_vars(M_Done)
    /\ WF_vars(C_DetectSpeech)
    /\ WF_vars(C_WaitTimeout)
    /\ WF_vars(C_SilenceTimeout)
    /\ WF_vars(H_BecameSilentEnough)
    /\ WF_vars(H_MicLost)
    /\ WF_vars(H_MicReconnect)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* INVARIANTS *)

RecActiveConsistency ==
    m_state = "idle" => rec_active = FALSE

\* A fresh STOP_FLAG is never incorrectly deleted
StopFlagNotLost ==
    (p_state = "key_up" /\ stop_flag_is_fresh)
    => (stop_flag_exists = TRUE \/ m_state \in {"processing", "done"})

-----------------------------------------------------------------------------
(* LIVENESS *)

RecordingTerminates ==
    [](m_state = "polling" ~> m_state \in {"processing", "done"})

PTTSessionCompletes ==
    [](p_state = "key_down" ~> p_state = "idle")

=============================================================================
